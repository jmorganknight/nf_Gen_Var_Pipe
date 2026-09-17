nextflow.enable.dsl = 2

process SIGN_OFF_CLINICAL_BUNDLE {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'
    publishDir "${params.stage5_outdir}/clinical_release", mode: 'copy', overwrite: true, pattern: '*_production_release.*'
    publishDir "${params.stage5_outdir}/pgx", mode: 'copy', overwrite: true, pattern: '*.clinical_bundle.tar.gz'
    publishDir "${params.stage5_outdir}/pgx", mode: 'copy', overwrite: true, pattern: '*.provenance.json'
    tag "${sample_id ?: 'UNKNOWN'}"

    input:
    val meta
    val sample_id
    path clinical_bundle_json
    path signer_private_key
    path signer_public_key
    val signer_policy

    output:
    tuple val(meta), path("${sample_id}_production_release.json"), path("${sample_id}_production_release.sha256"), path("${sample_id}.clinical_bundle.tar.gz"), path("${sample_id}.provenance.json"), emit: production_release

    script:
    def safeMeta = (meta instanceof Map) ? (meta as Map) : [:]
    def safeSampleId = sample_id?.toString()?.trim() ?: safeMeta.sample_id?.toString()?.trim()
    if (!safeSampleId) {
        throw new IllegalStateException('STAGE5_SIGN_OFF_FATAL: sample_id is required for release sign-off')
    }
    def safeGitCommitSha = safeMeta.git_commit_sha?.toString()?.trim()
    if (!safeGitCommitSha) {
        throw new IllegalStateException('STAGE5_SIGN_OFF_FATAL: git_commit_sha is required for release sign-off')
    }
    def safeContainerDigest = safeMeta.container_digest?.toString()?.trim()
    if (!safeContainerDigest) {
        throw new IllegalStateException('STAGE5_SIGN_OFF_FATAL: container_digest is required for release sign-off')
    }
    def metaJson = groovy.json.JsonOutput.toJson(safeMeta)
    def signerPolicyJson = groovy.json.JsonOutput.toJson((signer_policy instanceof Map) ? (signer_policy as Map) : [:])

    """
    set -euo pipefail

    cat > sample_meta.json <<'JSON'
${metaJson}
JSON
    cat > signer_policy.json <<'JSON'
${signerPolicyJson}
JSON

    python3 - <<'PY'
import base64
import hashlib
import json
import subprocess
import tarfile
from datetime import datetime, timezone
from pathlib import Path

sample_meta = json.loads(Path('sample_meta.json').read_text(encoding='utf-8'))
signer_policy = json.loads(Path('signer_policy.json').read_text(encoding='utf-8'))
sample_id = ${groovy.json.JsonOutput.toJson(safeSampleId)}
git_commit_sha = ${groovy.json.JsonOutput.toJson(safeGitCommitSha)}
container_digest = ${groovy.json.JsonOutput.toJson(safeContainerDigest)}
run_mode = str(sample_meta.get('run_mode') or 'production').strip() or 'production'
policy_version = str(sample_meta.get('policy_version') or '').strip()
sample_timestamp_utc = str(sample_meta.get('timestamp_utc') or '').strip()
signer_scope = str(signer_policy.get('signer_scope') or '').strip() or 'bootstrap'
signer_id = str(signer_policy.get('signer_id') or '').strip() or f'{signer_scope}-signer'
allow_bootstrap_for_production_run = bool(signer_policy.get('allow_bootstrap_for_production_run'))
private_key_path = Path(${groovy.json.JsonOutput.toJson(signer_private_key.toString())})
public_key_path = Path(${groovy.json.JsonOutput.toJson(signer_public_key.toString())})

bundle_path = Path(${groovy.json.JsonOutput.toJson(clinical_bundle_json.toString())})
if not bundle_path.exists() or not bundle_path.is_file():
    raise SystemExit(f"STAGE5_SIGN_OFF_FATAL: clinical bundle not found: {bundle_path}")
if not private_key_path.exists() or not private_key_path.is_file():
    raise SystemExit(f"STAGE5_SIGN_OFF_FATAL: signer private key not found: {private_key_path}")
if not public_key_path.exists() or not public_key_path.is_file():
    raise SystemExit(f"STAGE5_SIGN_OFF_FATAL: signer public key not found: {public_key_path}")
if run_mode == 'production' and signer_scope == 'bootstrap' and not allow_bootstrap_for_production_run:
    raise SystemExit('STAGE5_SIGN_OFF_FATAL: bootstrap signer is not permitted for production-mode release sign-off')

try:
    original_payload = json.loads(bundle_path.read_text(encoding='utf-8'))
except json.JSONDecodeError as exc:
    raise SystemExit(f"STAGE5_SIGN_OFF_FATAL: invalid clinical bundle JSON: {exc}") from exc

canonical_bundle = json.dumps(original_payload, sort_keys=True, separators=(',', ':'))
bundle_sha256 = hashlib.sha256(canonical_bundle.encode('utf-8')).hexdigest()
newline = chr(10)

canonical_bundle_path = Path(f"{sample_id}.stage5_clinical_bundle.json")
canonical_bundle_path.write_text(canonical_bundle, encoding='utf-8')

bundle_tar_path = Path(f"{sample_id}.clinical_bundle.tar.gz")
with tarfile.open(bundle_tar_path, 'w:gz') as tar:
    tar.add(canonical_bundle_path, arcname=canonical_bundle_path.name)

signature_bin_path = Path(f"{sample_id}.clinical_payload.sig.bin")
subprocess.run(
    ['openssl', 'dgst', '-sha256', '-sign', str(private_key_path), '-out', str(signature_bin_path), str(canonical_bundle_path)],
    check=True,
    capture_output=True,
    text=True,
)

signature_b64 = base64.b64encode(signature_bin_path.read_bytes()).decode('ascii')
public_key_der = subprocess.run(
    ['openssl', 'pkey', '-pubin', '-in', str(public_key_path), '-outform', 'DER'],
    check=True,
    capture_output=True,
).stdout
public_key_fingerprint = hashlib.sha256(public_key_der).hexdigest()

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()

provenance = {
    'sample_id': sample_id,
    'workflow_name': 'SIGN_OFF_CLINICAL_BUNDLE',
    'generated_utc': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
    'run_mode': run_mode,
    'git_commit_sha': git_commit_sha,
    'container_digest': container_digest,
    'policy_version': policy_version,
    'source_timestamp_utc': sample_timestamp_utc,
    'input_sha256': {
        'clinical_bundle_json': bundle_sha256,
    },
    'output_sha256': {
        'clinical_bundle_tar_gz': sha256_file(bundle_tar_path),
    },
    'signature': {
        'alg': 'RS256',
        'version': 'stage5-release-signature-v1',
        'signer_scope': signer_scope,
        'signer_id': signer_id,
        'public_key_fingerprint_sha256': public_key_fingerprint,
        'signed_payload_sha256': bundle_sha256,
        'signature_sha256': hashlib.sha256(signature_bin_path.read_bytes()).hexdigest(),
    },
    'bundle_contents': [canonical_bundle_path.name],
}

provenance_path = Path(f"{sample_id}.provenance.json")
provenance_path.write_text(json.dumps(provenance, indent=2) + newline, encoding='utf-8')

envelope = {
    'sample_id': sample_id,
    'run_mode': run_mode,
    'version': git_commit_sha,
    'audit_trail': {
        'timestamp_utc': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
        'git_commit_sha': git_commit_sha,
        'container_digest': container_digest,
        'bundle_sha256': bundle_sha256,
        'clinical_bundle_tar_gz': bundle_tar_path.name,
        'provenance_json': provenance_path.name,
    },
    'signature': {
        'alg': 'RS256',
        'version': 'stage5-release-signature-v1',
        'signer_scope': signer_scope,
        'signer_id': signer_id,
        'public_key_fingerprint_sha256': public_key_fingerprint,
        'public_key_basename': public_key_path.name,
        'signed_fields': ['clinical_payload'],
        'signed_payload_sha256': bundle_sha256,
        'signature_b64': signature_b64,
    },
    'clinical_payload': json.loads(canonical_bundle),
}

release_json_path = Path(f"{sample_id}_production_release.json")
release_sha_path = Path(f"{sample_id}_production_release.sha256")

release_json_path.write_text(json.dumps(envelope, sort_keys=True, separators=(',', ':')), encoding='utf-8')
release_sha_path.write_text(bundle_sha256 + newline, encoding='utf-8')
PY
    """
}
