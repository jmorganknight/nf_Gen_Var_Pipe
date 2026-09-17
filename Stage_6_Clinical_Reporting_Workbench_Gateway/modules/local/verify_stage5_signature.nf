process VERIFY_STAGE5_SIGNATURE {

    label 'process_low'
    container 'genvar-reporting:2.1.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage6", mode: 'copy', overwrite: true, pattern: '*.stage6_signature_verification.json'

    input:
    tuple val(meta), path(stage5_manifest), path(clinical_bundle_tar_gz), path(stage5_provenance_json), path(acmg_tiered_variants_json), path(candidate_vus_json), path(vus_queue_json), path(sf_artifact), path(prs_artifact), path(pgx_artifact), val(reference_meta), path(stage5_production_release_json)

    output:
    tuple val(meta), path(stage5_manifest), path(clinical_bundle_tar_gz), path(stage5_provenance_json), path(acmg_tiered_variants_json), path(candidate_vus_json), path(vus_queue_json), path(sf_artifact), path(prs_artifact), path(pgx_artifact), val(reference_meta), emit: verified_bundle
    path "${meta.sample_id}.stage6_signature_verification.json", emit: signature_audit

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import hashlib
import json
from pathlib import Path

sid = '${sid}'
release_path = Path('${stage5_production_release_json}')
if not release_path.exists():
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: Stage 5 production release not found for sample {sid}: {release_path}")

try:
    envelope = json.loads(release_path.read_text(encoding='utf-8'))
except Exception as exc:
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: invalid Stage 5 production release JSON for sample {sid}: {exc}")

if not isinstance(envelope, dict):
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: Stage 5 release envelope malformed for sample {sid}")

audit_trail = envelope.get('audit_trail', {})
clinical_payload = envelope.get('clinical_payload')

if not isinstance(audit_trail, dict):
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: missing audit_trail map for sample {sid}")
if not isinstance(clinical_payload, dict):
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: missing clinical_payload map for sample {sid}")

bundle_sha256_claimed = str(audit_trail.get('bundle_sha256', '')).strip().lower()
if len(bundle_sha256_claimed) != 64 or any(ch not in '0123456789abcdef' for ch in bundle_sha256_claimed):
    raise SystemExit(f"STAGE6_SIGNATURE_VERIFICATION_FATAL: invalid bundle_sha256 in Stage 5 release for sample {sid}")

canonical_payload = json.dumps(clinical_payload, sort_keys=True, separators=(',', ':'))
bundle_sha256_computed = hashlib.sha256(canonical_payload.encode('utf-8')).hexdigest()

if bundle_sha256_computed != bundle_sha256_claimed:
    raise SystemExit(
        f"STAGE6_SIGNATURE_VERIFICATION_FATAL: clinical_payload digest mismatch for sample {sid}; expected={bundle_sha256_claimed} observed={bundle_sha256_computed}"
    )

audit = {
    'node': 'VERIFY_STAGE5_SIGNATURE',
    'sample_id': sid,
    'status': 'PASS',
    'stage5_production_release_json': str(release_path.resolve()),
    'bundle_sha256_claimed': bundle_sha256_claimed,
    'bundle_sha256_computed': bundle_sha256_computed,
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
