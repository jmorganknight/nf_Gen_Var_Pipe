/*
 * ─────────────────────────────────────────────────────────────────────────────
 * Process : REF_MANIFEST_SNAPSHOT_LOCK
 * Stage   : 0 — Environment Initialization & Lockout
 *
 * Blueprint node : REF_SNAPSHOT (draft_03.html)
 * Purpose:
 *   Generate and bind immutable SHA256 cryptographic checksum manifests
 *   across all local reference genome resource volumes, VEP caches, and
 *   variant databases at pipeline initialization. Guarantees total clinical
 *   analytical reproducibility before any execution begins.
 *
 * CLIA/CAP mandate (Rule 7.2.1):
 *   - Runtime intake control signatures (YAML snapshots) banked per run.
 *   - SHA256 hashes of every reference path archived in the audit vault.
 *
 * Inputs  : path(references_yaml), path(samples_yaml), path(thresholds_yaml), path(infrastructure_yaml)
 * Outputs : path('reference_snapshot.tokens')  → emit: snapshot_tokens
 *           path('yaml_snapshot_bundle.tar.gz') → emit: yaml_bundle
 * ─────────────────────────────────────────────────────────────────────────────
 */

process REF_MANIFEST_SNAPSHOT_LOCK {

    label 'process_low'
    container 'genvar-core:2.1.0'

    publishDir "${params.outdir}/Stage_0/audit_and_qc/ref_snapshot", mode: 'copy', overwrite: true

    input:
    path references_yaml
    path samples_yaml
    path thresholds_yaml
    path infrastructure_yaml

    output:
    path 'reference_snapshot.tokens', emit: snapshot_tokens
    path 'yaml_snapshot_bundle.tar.gz', emit: yaml_bundle

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

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

def sha256_of_file(p):
    if not os.path.exists(p):
        raise FileNotFoundError(f"[REF_LOCK] Missing reference asset: {p}")
    if not os.path.isfile(p):
        raise RuntimeError(f"[REF_LOCK] Expected file but found non-file asset: {p}")
    if not os.access(p, os.R_OK):
        raise PermissionError(f"[REF_LOCK] Unreadable reference asset (permission denied): {p}")

    h = hashlib.sha256()
    with open(p, 'rb') as fh:
        for chunk in iter(lambda: fh.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def sha256_of_directory(root_dir):
    if not os.path.exists(root_dir):
        raise FileNotFoundError(f"[REF_LOCK] Missing reference directory: {root_dir}")
    if not os.path.isdir(root_dir):
        raise RuntimeError(f"[REF_LOCK] Expected directory but found non-directory asset: {root_dir}")
    if not os.access(root_dir, os.R_OK | os.X_OK):
        raise PermissionError(f"[REF_LOCK] Unreadable reference directory (permission denied): {root_dir}")

    digest = hashlib.sha256()
    file_count = 0

    for cur_root, dirnames, filenames in os.walk(root_dir):
        dirnames.sort()
        filenames.sort()
        for fname in filenames:
            fpath = os.path.join(cur_root, fname)
            rel = os.path.relpath(fpath, root_dir)
            digest.update(rel.encode('utf-8'))
            digest.update(b'\0')
            digest.update(sha256_of_file(fpath).encode('ascii'))
            file_count += 1

    if file_count == 0:
        raise RuntimeError(f"[REF_LOCK] Reference directory is empty: {root_dir}")

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


def sha256_of_path(p, ref_data_root):
    p = resolve_reference_path(p, ref_data_root)
    if os.path.isdir(p):
        return sha256_of_directory(p)
    return sha256_of_file(p)


def infer_dict_path_from_fasta(fasta_path):
    for ext in ('.fasta', '.fa', '.fna'):
        if fasta_path.endswith(ext):
            return fasta_path[:-len(ext)] + '.dict'
    return fasta_path + '.dict'


def assert_reference_consistency(refs):
    required = ['reference_genome', 'reference_fai', 'reference_dict', 'bwa_index_base']
    missing = [k for k in required if not refs.get(k)]
    if missing:
        raise RuntimeError(f"[REF_LOCK] Missing required reference keys: {', '.join(missing)}")

    ref_fa = refs['reference_genome']
    ref_fai = refs['reference_fai']
    ref_dict = refs['reference_dict']
    bwa_base = refs['bwa_index_base']

    expected_fai = f"{ref_fa}.fai"
    if os.path.normpath(ref_fai) != os.path.normpath(expected_fai):
        raise RuntimeError(
            f"[REF_LOCK] reference_fai mismatch: expected '{expected_fai}' for reference_genome '{ref_fa}', got '{ref_fai}'"
        )

    expected_dict = infer_dict_path_from_fasta(ref_fa)
    if os.path.normpath(ref_dict) != os.path.normpath(expected_dict):
        raise RuntimeError(
            f"[REF_LOCK] reference_dict mismatch: expected '{expected_dict}' for reference_genome '{ref_fa}', got '{ref_dict}'"
        )

    if os.path.normpath(bwa_base) != os.path.normpath(ref_fa):
        raise RuntimeError(
            f"[REF_LOCK] bwa_index_base mismatch: expected '{ref_fa}', got '{bwa_base}'"
        )

refs_doc = load_yaml_simple('${references_yaml}')
refs = refs_doc.get('references', {})
if not refs:
    raise RuntimeError('[REF_LOCK] No references block parsed from references manifest')
yaml_ref_data_root = refs_doc.get('ref_data_root')
if yaml_ref_data_root is None:
    yaml_ref_data_root = FALLBACK_REF_ROOT
yaml_ref_data_root = str(yaml_ref_data_root).strip() or FALLBACK_REF_ROOT
assert_reference_consistency(refs)
infra_doc = load_yaml_simple('${infrastructure_yaml}')

def get_container_digest(containers_block, key):
    if not isinstance(containers_block, dict):
        return 'BUILD_PENDING'
    entry = containers_block.get(key)
    if not isinstance(entry, dict):
        return 'BUILD_PENDING'
    digest = entry.get('digest')
    if digest is None:
        return 'BUILD_PENDING'
    digest_text = str(digest).strip()
    return digest_text if digest_text else 'BUILD_PENDING'

manifest = {
    'pipeline'         : 'GEN_VAR_PIPELINE_v1',
    'timestamp_utc'    : datetime.now(timezone.utc).isoformat(),
    'hash_engine'      : 'SHA256',
    'verification_depth': 'HIGH_INTEGRITY',
    'reference_hashes' : {},
    'container_digests': {}
}

containers_cfg = infra_doc.get('containers', {}) if isinstance(infra_doc, dict) else {}
manifest['container_digests'] = {
    'core': get_container_digest(containers_cfg, 'core'),
    'annotation': get_container_digest(containers_cfg, 'annotation'),
    'reporting': get_container_digest(containers_cfg, 'reporting'),
}

def walk_refs(obj, prefix=''):
    if isinstance(obj, dict):
        for k, v in obj.items():
            walk_refs(v, f'{prefix}.{k}' if prefix else k)
    elif isinstance(obj, str):
        if '/' in obj:
            manifest['reference_hashes'][prefix] = sha256_of_path(obj, yaml_ref_data_root)

walk_refs(refs)

if not manifest['reference_hashes']:
    raise RuntimeError('[REF_LOCK] No reference assets were discovered for integrity hashing')

expected_sha256 = refs.get('expected_sha256', {}) if isinstance(refs.get('expected_sha256', {}), dict) else {}
for key, expected in expected_sha256.items():
    actual = manifest['reference_hashes'].get(key)
    if actual is None:
        raise RuntimeError(f"[REF_LOCK] expected_sha256 key '{key}' has no matching hashed asset")
    if str(actual).lower() != str(expected).lower():
        raise RuntimeError(
            f"[REF_LOCK] Checksum mismatch for '{key}': expected {expected}, observed {actual}"
        )

for label, path in [
    ('samples_yaml', '${samples_yaml}'),
    ('references_yaml', '${references_yaml}'),
    ('thresholds_yaml', '${thresholds_yaml}'),
    ('infrastructure_yaml', '${infrastructure_yaml}'),
]:
    manifest['reference_hashes'][label] = sha256_of_file(path)

tokens_str = json.dumps(manifest, indent=2)
with open('reference_snapshot.tokens', 'w') as out:
    out.write(tokens_str + '\\n')
print(tokens_str, file=sys.stderr)
PYEOF

    tar -czf yaml_snapshot_bundle.tar.gz \
        "${references_yaml}" \
        "${samples_yaml}" \
        "${thresholds_yaml}" \
        "${infrastructure_yaml}"
    """

    stub:
    """
    echo '{"pipeline":"GEN_VAR_PIPELINE_v1","stub":true,"reference_hashes":{},"container_digests":{"core":"BUILD_PENDING","annotation":"BUILD_PENDING","reporting":"BUILD_PENDING"}}' \
        > reference_snapshot.tokens
    touch yaml_snapshot_bundle.tar.gz
    """
}