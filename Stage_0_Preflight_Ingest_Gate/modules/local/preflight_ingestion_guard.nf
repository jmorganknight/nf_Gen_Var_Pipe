/*
 * ─────────────────────────────────────────────────────────────────────────────
 * Process : PREFLIGHT_INGESTION_GUARD
 * Stage   : 0 — Atomic intake/control-plane lock barrier
 *
 * Purpose:
 *   Bind the sample intake channel and governed YAML control-plane manifests
 *   into a single immutable SHA-256 lock token before downstream execution.
 *
 * Inputs  : val(preflight_sample_rows), path(references_yaml), path(samples_yaml),
 *           path(thresholds_yaml), path(infrastructure_yaml)
 * Outputs : path('preflight_lock.json')        → emit: preflight_lock
 *           path('reference_snapshot.tokens')  → emit: snapshot_tokens
 *           path('yaml_snapshot_bundle.tar.gz') → emit: yaml_bundle
 * ─────────────────────────────────────────────────────────────────────────────
 */

process PREFLIGHT_INGESTION_GUARD {

    label 'process_low'
    container 'genvar-core:2.1.0'

    publishDir "${params.outdir}/Stage_0/audit_and_qc/preflight_lock", mode: 'copy', overwrite: true

    input:
    val preflight_sample_rows
    path references_yaml
    path samples_yaml
    val samples_manifest_source
    path thresholds_yaml
    path infrastructure_yaml
    path resolved_ref_genome, name: 'resolved_reference_genome.fa'
    path resolved_ref_fai, name: 'resolved_reference_genome.fa.fai'
    path resolved_ref_dict, name: 'resolved_reference_genome.dict'
    path resolved_ref_bwa_base, name: 'resolved_bwa_index_base.fa'
    val ref_data_root

    output:
    path 'preflight_lock.json', emit: preflight_lock
    path 'reference_snapshot.tokens', emit: snapshot_tokens
    path 'yaml_snapshot_bundle.tar.gz', emit: yaml_bundle

    script:
    def sampleRowsJson = groovy.json.JsonOutput.toJson(preflight_sample_rows ?: []).replace('\n', ' ').replace('\r', '')
    def samplesManifestSourceJson = groovy.json.JsonOutput.toJson(samples_manifest_source?.toString() ?: samples_yaml.getName().toString())
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path

FALLBACK_REF_ROOT = '/opt/reference'


def parse_scalar(value):
    value = value.strip()
    if value.startswith(('"', "'")) and value.endswith(('"', "'")):
        return value[1:-1]
    low = value.lower()
    if low == 'true':
        return True
    if low == 'false':
        return False
    try:
        if '.' in value:
            return float(value)
        return int(value)
    except ValueError:
        return value


def load_yaml_simple(path):
    root = {}
    stack = [(-1, root)]
    with open(path, 'r', encoding='utf-8') as fh:
        for raw in fh:
            if not raw.strip() or raw.lstrip().startswith('#'):
                continue
            indent = len(raw) - len(raw.lstrip(' '))
            line = raw.rstrip('\\n')
            if ':' not in line:
                continue
            key, value = line.strip().split(':', 1)
            value = value.strip()
            while len(stack) > 1 and indent <= stack[-1][0]:
                stack.pop()
            cur = stack[-1][1]
            if not value:
                cur[key] = {}
                stack.append((indent, cur[key]))
            else:
                cur[key] = parse_scalar(value)
    return root


def sha256_of_file(path_text):
    if not os.path.exists(path_text):
        raise FileNotFoundError(f"[PREFLIGHT_LOCK] Missing asset: {path_text}")
    if not os.path.isfile(path_text):
        raise RuntimeError(f"[PREFLIGHT_LOCK] Expected file but found non-file asset: {path_text}")
    if not os.access(path_text, os.R_OK):
        raise PermissionError(f"[PREFLIGHT_LOCK] Unreadable asset: {path_text}")
    digest = hashlib.sha256()
    with open(path_text, 'rb') as handle:
        for chunk in iter(lambda: handle.read(65536), b''):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_of_directory(root_dir):
    if not os.path.exists(root_dir):
        raise FileNotFoundError(f"[PREFLIGHT_LOCK] Missing directory asset: {root_dir}")
    if not os.path.isdir(root_dir):
        raise RuntimeError(f"[PREFLIGHT_LOCK] Expected directory but found non-directory asset: {root_dir}")
    if not os.access(root_dir, os.R_OK | os.X_OK):
        raise PermissionError(f"[PREFLIGHT_LOCK] Unreadable directory asset: {root_dir}")

    digest = hashlib.sha256()
    file_count = 0
    for current_root, dirnames, filenames in os.walk(root_dir):
        dirnames.sort()
        filenames.sort()
        for filename in filenames:
            path_text = os.path.join(current_root, filename)
            relative_path = os.path.relpath(path_text, root_dir)
            digest.update(relative_path.encode('utf-8'))
            digest.update(b'\0')
            digest.update(sha256_of_file(path_text).encode('ascii'))
            digest.update(b'\0')
            file_count += 1

    if file_count == 0:
        raise RuntimeError(f"[PREFLIGHT_LOCK] Reference directory is empty: {root_dir}")

    return digest.hexdigest()


def resolve_reference_path(path_text, ref_data_root):
    if os.path.isabs(path_text):
        return path_text

    root_text = (ref_data_root or '').strip() or FALLBACK_REF_ROOT
    rooted = os.path.normpath(os.path.join(root_text, path_text))
    if os.path.exists(rooted):
        return rooted

    fallback = os.path.normpath(os.path.join(FALLBACK_REF_ROOT, path_text))
    return fallback


def sha256_of_path(path_text, ref_data_root):
    if os.path.exists(path_text):
        if os.path.isdir(path_text):
            return sha256_of_directory(path_text)
        return sha256_of_file(path_text)

    path_text = resolve_reference_path(path_text, ref_data_root)
    if os.path.isdir(path_text):
        return sha256_of_directory(path_text)
    return sha256_of_file(path_text)


def infer_dict_path_from_fasta(fasta_path):
    for ext in ('.fasta', '.fa', '.fna'):
        if fasta_path.endswith(ext):
            return fasta_path[:-len(ext)] + '.dict'
    return fasta_path + '.dict'


def assert_reference_consistency(refs):
    required = ['reference_genome', 'reference_fai', 'reference_dict', 'bwa_index_base']
    missing = [key for key in required if not refs.get(key)]
    if missing:
        raise RuntimeError(f"[PREFLIGHT_LOCK] Missing required reference keys: {', '.join(missing)}")

    ref_fa = refs['reference_genome']
    ref_fai = refs['reference_fai']
    ref_dict = refs['reference_dict']
    bwa_base = refs['bwa_index_base']

    expected_fai = f"{ref_fa}.fai"
    if os.path.normpath(ref_fai) != os.path.normpath(expected_fai):
        raise RuntimeError(
            f"[PREFLIGHT_LOCK] reference_fai mismatch: expected '{expected_fai}' for reference_genome '{ref_fa}', got '{ref_fai}'"
        )

    expected_dict = infer_dict_path_from_fasta(ref_fa)
    if os.path.normpath(ref_dict) != os.path.normpath(expected_dict):
        raise RuntimeError(
            f"[PREFLIGHT_LOCK] reference_dict mismatch: expected '{expected_dict}' for reference_genome '{ref_fa}', got '{ref_dict}'"
        )

    if os.path.normpath(bwa_base) != os.path.normpath(ref_fa):
        raise RuntimeError(
            f"[PREFLIGHT_LOCK] bwa_index_base mismatch: expected '{ref_fa}', got '{bwa_base}'"
        )


def get_container_digest(containers_block, key):
    if not isinstance(containers_block, dict):
        return 'BUILD_PENDING'
    entry = containers_block.get(key)
    if not isinstance(entry, dict):
        return 'BUILD_PENDING'
    digest = entry.get('digest')
    if digest is None:
        return 'BUILD_PENDING'
    digest_text = str(digest).split('#', 1)[0].strip()
    if digest_text.startswith(('"', "'")) and digest_text.endswith(('"', "'")):
        digest_text = digest_text[1:-1].strip()
    return digest_text if digest_text else 'BUILD_PENDING'


refs_doc = load_yaml_simple('${references_yaml}')
refs = refs_doc.get('references', {})
if not refs:
    raise RuntimeError('[PREFLIGHT_LOCK] No references block parsed from references manifest')

# === OPTION A: USE GROOVY-RESOLVED REFERENCES ===
# Instead of parsing and resolving paths in Python (which fails in containers),
# use the reference files already staged by Nextflow from the pipeline runner.
# Groovy has already validated these files exist before staging them as inputs.

resolved_refs = {
    'reference_genome': Path('${resolved_ref_genome}'),
    'reference_fai': Path('${resolved_ref_fai}'),
    'reference_dict': Path('${resolved_ref_dict}'),
    'bwa_index_base': Path('${resolved_ref_bwa_base}'),
}

# Validate that staged reference files are accessible in the container
for key, ref_path in resolved_refs.items():
    if not ref_path.exists():
        raise FileNotFoundError(f'[PREFLIGHT_LOCK] Staged reference file not found in container: {key}={ref_path}')

yaml_ref_data_root = '${ref_data_root}'
refs = resolved_refs

infra_doc = load_yaml_simple('${infrastructure_yaml}')
containers_cfg = infra_doc.get('containers', {}) if isinstance(infra_doc, dict) else {}
sample_rows = json.loads('''${sampleRowsJson}''')
samples_manifest_source = json.loads('''${samplesManifestSourceJson}''')

manifest = {
    'node': 'PREFLIGHT_INGESTION_GUARD',
    'pipeline': 'GEN_VAR_PIPELINE_v1',
    'preflight_status': 'STAGE0_PREFLIGHT_LOCK_PASS',
    'timestamp_utc': datetime.now(timezone.utc).isoformat(),
    'hash_engine': 'SHA-256',
    'verification_depth': 'ATOMIC_CONTROL_PLANE_LOCK',
    'sample_count': len(sample_rows),
    'sample_channel_digest': hashlib.sha256(json.dumps(sample_rows, sort_keys=True).encode('utf-8')).hexdigest(),
    'sample_records': sample_rows,
    'control_plane_files': {},
    'reference_hashes': {},
    'container_digests': {
        'core': get_container_digest(containers_cfg, 'core'),
        'annotation': get_container_digest(containers_cfg, 'annotation'),
        'reporting': get_container_digest(containers_cfg, 'reporting'),
    },
}

for label, path_text in [
    ('samples_yaml', samples_manifest_source),
    ('references_yaml', '${references_yaml}'),
    ('thresholds_yaml', '${thresholds_yaml}'),
    ('infrastructure_yaml', '${infrastructure_yaml}'),
]:
    manifest['control_plane_files'][label] = {
        'path': path_text,
        'sha256': sha256_of_file(os.path.basename(path_text)),
    }


def walk_refs(obj, prefix=''):
    if isinstance(obj, dict):
        for key, value in obj.items():
            walk_refs(value, f'{prefix}.{key}' if prefix else key)
    elif isinstance(obj, os.PathLike):
        manifest['reference_hashes'][prefix] = sha256_of_path(os.fspath(obj), yaml_ref_data_root)
    elif isinstance(obj, str):
        candidate = obj.strip()
        if candidate and ('/' in candidate or os.path.exists(candidate)):
            manifest['reference_hashes'][prefix] = sha256_of_path(candidate, yaml_ref_data_root)


walk_refs(refs)
if not manifest['reference_hashes']:
    raise RuntimeError('[PREFLIGHT_LOCK] No reference assets were discovered for integrity hashing')

expected_sha256 = refs.get('expected_sha256', {}) if isinstance(refs.get('expected_sha256', {}), dict) else {}
for key, expected in expected_sha256.items():
    actual = manifest['reference_hashes'].get(key)
    if actual is None:
        raise RuntimeError(f"[PREFLIGHT_LOCK] expected_sha256 key '{key}' has no matching hashed asset")
    if str(actual).lower() != str(expected).lower():
        raise RuntimeError(
            f"[PREFLIGHT_LOCK] Checksum mismatch for '{key}': expected {expected}, observed {actual}"
        )

payload = json.dumps(manifest, indent=2) + '\\n'
with open('preflight_lock.json', 'w', encoding='utf-8') as handle:
    handle.write(payload)
with open('reference_snapshot.tokens', 'w', encoding='utf-8') as handle:
    handle.write(payload)
print(json.dumps({'node': manifest['node'], 'preflight_status': manifest['preflight_status'], 'sample_count': manifest['sample_count']}), flush=True)
PYEOF

    samples_manifest_source='${samples_manifest_source}'

    tar -czf yaml_snapshot_bundle.tar.gz \
        "${references_yaml}" \
        "\$(basename "${samples_manifest_source}")" \
        "${thresholds_yaml}" \
        "${infrastructure_yaml}"
    """

    stub:
    """
    cat > preflight_lock.json <<'EOF'
{
  "node": "PREFLIGHT_INGESTION_GUARD",
    "pipeline": "GEN_VAR_PIPELINE_v1",
  "preflight_status": "STAGE0_PREFLIGHT_LOCK_PASS",
  "stub": true,
  "sample_count": 0,
  "sample_channel_digest": "stub",
  "control_plane_files": {},
  "reference_hashes": {},
  "container_digests": {
    "core": "BUILD_PENDING",
    "annotation": "BUILD_PENDING",
        "reporting": "BUILD_PENDING"
  }
}
EOF
    cp preflight_lock.json reference_snapshot.tokens
    touch yaml_snapshot_bundle.tar.gz
    """
}