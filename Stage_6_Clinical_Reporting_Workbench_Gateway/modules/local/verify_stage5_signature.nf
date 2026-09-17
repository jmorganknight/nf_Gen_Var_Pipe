process VERIFY_STAGE5_SIGNATURE {

    label 'process_low'
    container 'genvar-reporting:2.1.0'
    stageInMode 'copy'

    tag "${meta.sample_id}"

    publishDir "${params.stage6_outdir}/audit_and_qc", mode: 'copy', overwrite: true, pattern: '*.stage6_signature_verification.json'

    input:
    tuple val(meta),
        path(stage5_manifest, stageAs: 'stage5_manifest/*'),
        path(clinical_bundle_tar_gz, stageAs: 'clinical_bundle/*'),
        path(stage5_provenance_json, stageAs: 'stage5_provenance/*'),
        path(acmg_tiered_variants_json, stageAs: 'acmg_tiered/*'),
        path(candidate_vus_json, stageAs: 'candidate_vus/*'),
        path(vus_queue_json, stageAs: 'vus_queue/*'),
        path(sf_artifact, stageAs: 'secondary_findings/*'),
        path(prs_artifact, stageAs: 'prs/*'),
        path(pgx_artifact, stageAs: 'pgx/*'),
        val(reference_meta),
        path(stage5_production_release_json, stageAs: 'stage5_release/*'),
        path(stage5_signer_public_key, stageAs: 'stage5_signer_public_key/*')

    output:
    tuple val(meta), path(stage5_manifest), path(clinical_bundle_tar_gz), path(stage5_provenance_json), path(acmg_tiered_variants_json), path(candidate_vus_json), path(vus_queue_json), path(sf_artifact), path(prs_artifact), path(pgx_artifact), val(reference_meta), emit: verified_bundle
    path "${meta.sample_id}.stage6_signature_verification.json", emit: signature_audit

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import base64
import hashlib
import json
import subprocess
from pathlib import Path

sid = '${sid}'
release_path = Path('${stage5_production_release_json}')
public_key_path = Path('${stage5_signer_public_key}')
if not release_path.exists():
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: Stage 5 production release not found for sample {sid}: {release_path}")
if not public_key_path.exists():
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: Stage 5 signer public key not found for sample {sid}: {public_key_path}")

try:
    envelope = json.loads(release_path.read_text(encoding='utf-8'))
except Exception as exc:
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: invalid Stage 5 production release JSON for sample {sid}: {exc}")

if not isinstance(envelope, dict):
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: Stage 5 release envelope malformed for sample {sid}")

audit_trail = envelope.get('audit_trail', {})
clinical_payload = envelope.get('clinical_payload')
signature = envelope.get('signature', {})

if not isinstance(audit_trail, dict):
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: missing audit_trail map for sample {sid}")
if not isinstance(clinical_payload, dict):
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: missing clinical_payload map for sample {sid}")
if not isinstance(signature, dict):
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: missing signature map for sample {sid}")

bundle_sha256_claimed = str(audit_trail.get('bundle_sha256', '')).strip().lower()
if len(bundle_sha256_claimed) != 64 or any(ch not in '0123456789abcdef' for ch in bundle_sha256_claimed):
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: invalid bundle_sha256 in Stage 5 release for sample {sid}")

canonical_payload = json.dumps(clinical_payload, sort_keys=True, separators=(',', ':'))
bundle_sha256_computed = hashlib.sha256(canonical_payload.encode('utf-8')).hexdigest()

if bundle_sha256_computed != bundle_sha256_claimed:
    raise SystemExit(
        f"STAGE6_SIGNATURE_VERIFICATION_FATAL: clinical_payload digest mismatch for sample {sid}; expected={bundle_sha256_claimed} observed={bundle_sha256_computed}"
    )

signature_alg = str(signature.get('alg', '')).strip()
signature_version = str(signature.get('version', '')).strip()
signer_scope = str(signature.get('signer_scope', '')).strip()
signer_id = str(signature.get('signer_id', '')).strip()
signature_b64 = str(signature.get('signature_b64', '')).strip()
claimed_public_key_fingerprint = str(signature.get('public_key_fingerprint_sha256', '')).strip().lower()
signed_payload_sha256 = str(signature.get('signed_payload_sha256', '')).strip().lower()
expected_signer_scope = str('${meta.expected_stage5_signer_scope ?: ''}').strip()
expected_signer_id = str('${meta.expected_stage5_signer_id ?: ''}').strip()
allow_bootstrap_for_production_run = '${meta.allow_bootstrap_for_production_run ? 'true' : 'false'}' == 'true'
run_mode = str('${meta.run_mode ?: 'production'}').strip().lower()

if signature_alg != 'RS256':
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: unsupported signature algorithm for sample {sid}: {signature_alg}")
if not signature_version:
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: missing signature version for sample {sid}")
if not signer_scope:
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: missing signer_scope for sample {sid}")
if not signer_id:
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: missing signer_id for sample {sid}")
if not signature_b64:
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: missing signature_b64 for sample {sid}")
if len(claimed_public_key_fingerprint) != 64 or any(ch not in '0123456789abcdef' for ch in claimed_public_key_fingerprint):
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: invalid public key fingerprint for sample {sid}")
if signed_payload_sha256 != bundle_sha256_computed:
    raise SystemExit(
        f"STAGE6_SIGNATURE_VERIFICATION_FATAL: signed payload sha256 mismatch for sample {sid}; expected={bundle_sha256_computed} observed={signed_payload_sha256}"
    )
if expected_signer_scope and signer_scope != expected_signer_scope:
    raise SystemExit(
        f"STAGE6_SIGNATURE_VERIFICATION_FATAL: signer_scope mismatch for sample {sid}; expected={expected_signer_scope} observed={signer_scope}"
    )
if expected_signer_id and signer_id != expected_signer_id:
    raise SystemExit(
        f"STAGE6_SIGNATURE_VERIFICATION_FATAL: signer_id mismatch for sample {sid}; expected={expected_signer_id} observed={signer_id}"
    )
if run_mode == 'production' and signer_scope == 'bootstrap' and not allow_bootstrap_for_production_run:
    raise SystemExit(
        f"STAGE6_SIGNATURE_VERIFICATION_FATAL: bootstrap signer is not permitted for production-mode sample {sid}"
    )

public_key_der = subprocess.run(
    ['openssl', 'pkey', '-pubin', '-in', str(public_key_path), '-outform', 'DER'],
    check=True,
    capture_output=True,
).stdout
public_key_fingerprint = hashlib.sha256(public_key_der).hexdigest()
if public_key_fingerprint != claimed_public_key_fingerprint:
    raise SystemExit(
        f"STAGE6_SIGNATURE_VERIFICATION_FATAL: public key fingerprint mismatch for sample {sid}; expected={claimed_public_key_fingerprint} observed={public_key_fingerprint}"
    )

canonical_payload_path = Path(f'{sid}.stage5.canonical_payload.json')
canonical_payload_path.write_text(canonical_payload, encoding='utf-8')
signature_path = Path(f'{sid}.stage5.signature.bin')
try:
    signature_path.write_bytes(base64.b64decode(signature_b64, validate=True))
except Exception as exc:
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: invalid base64 signature for sample {sid}: {exc}")

subprocess.run(
    ['openssl', 'dgst', '-sha256', '-verify', str(public_key_path), '-signature', str(signature_path), str(canonical_payload_path)],
    check=True,
    capture_output=True,
    text=True,
)

audit = {
    'node': 'VERIFY_STAGE5_SIGNATURE',
    'sample_id': sid,
    'status': 'PASS',
    'stage5_production_release_json': str(release_path.resolve()),
    'stage5_signer_public_key': str(public_key_path.resolve()),
    'bundle_sha256_claimed': bundle_sha256_claimed,
    'bundle_sha256_computed': bundle_sha256_computed,
    'signature_algorithm': signature_alg,
    'signature_version': signature_version,
    'signer_scope': signer_scope,
    'signer_id': signer_id,
    'public_key_fingerprint_sha256': public_key_fingerprint,
}
Path(f'{sid}.stage6_signature_verification.json').write_text(json.dumps(audit, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """

    stub:
    """
    python3 - <<'PYEOF'
import json
from pathlib import Path
sid = '${meta.sample_id}'
Path(f'{sid}.stage6_signature_verification.json').write_text(json.dumps({'node': 'VERIFY_STAGE5_SIGNATURE', 'sample_id': sid, 'status': 'PASS', 'stub': True}, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """
}
