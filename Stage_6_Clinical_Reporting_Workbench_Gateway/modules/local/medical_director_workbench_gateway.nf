process MEDICAL_DIRECTOR_WORKBENCH_GATEWAY {

    label 'process_low'
    container 'genvar-reporting:2.1.0'
    stageInMode 'copy'

    tag "${meta.sample_id}"

    publishDir "${params.stage6_outdir}/audit_and_qc", mode: 'copy', overwrite: true, pattern: '*.medical_director_workbench_signoff.json'
    publishDir "${params.stage6_outdir}/audit_and_qc", mode: 'copy', overwrite: true, pattern: '*.stage6_workbench.fragment.json'

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
        val(reference_meta)

    output:
    path "${meta.sample_id}.medical_director_workbench_signoff.json", emit: signoff
    tuple val(meta), path("${meta.sample_id}.stage6_workbench.fragment.json"), emit: fragment

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import hashlib
import json
from pathlib import Path


def sha256_file(path_text):
    path = Path(path_text)
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()

sid = '${sid}'
queue = json.loads(Path('${vus_queue_json}').read_text(encoding='utf-8'))
acmg = json.loads(Path('${acmg_tiered_variants_json}').read_text(encoding='utf-8'))
candidate_payload = json.loads(Path('${candidate_vus_json}').read_text(encoding='utf-8'))

candidate_count = len(candidate_payload.get('candidate_vus', [])) if isinstance(candidate_payload, dict) else 0
reported_count = sum(len(v) for v in (acmg.get('tiers', {}) if isinstance(acmg, dict) else {}).values() if isinstance(v, list))
remaining_count = len(queue.get('remaining_vus', [])) if isinstance(queue, dict) else 0
upgraded_count = len(queue.get('upgraded_variants', [])) if isinstance(queue, dict) else 0

manual_overrides = []
sanger_inputs = []
stage5_provenance = json.loads(Path('${stage5_provenance_json}').read_text(encoding='utf-8'))
stage5_signature = stage5_provenance.get('digital_signature', {}) if isinstance(stage5_provenance, dict) else {}
digital_signatures = []
if stage5_signature.get('signature_value'):
    digital_signatures.append({
        'signature_algorithm': stage5_signature.get('signature_algorithm', 'RS256'),
        'signature_value': stage5_signature.get('signature_value', ''),
        'signer_id': stage5_signature.get('signer_id', ''),
        'public_key_fingerprint': stage5_signature.get('public_key_fingerprint', ''),
    })

summary_seed = json.dumps({
    'sample_id': sid,
    'candidate_vus_count': candidate_count,
    'upgraded_vus_count': upgraded_count,
    'remaining_vus_count': remaining_count,
    'reported_variant_count': reported_count,
    'bundle_digest': stage5_signature.get('signed_digest_sha256') or sha256_file('${clinical_bundle_tar_gz}'),
}, sort_keys=True)

digest = stage5_signature.get('signed_digest_sha256') or hashlib.sha256(summary_seed.encode('utf-8')).hexdigest()

payload = {
    'node': 'MEDICAL_DIRECTOR_WORKBENCH_GATEWAY',
    'sample_id': sid,
    'signoff_status': 'PENDING_DIRECTOR_REVIEW',
    'manual_variant_overrides': manual_overrides,
    'sanger_confirmation_inputs': sanger_inputs,
    'digital_signatures': digital_signatures,
    'approval_digest': digest,
    'signed_bundle': '${clinical_bundle_tar_gz}',
    'workflow_gate': 'STAGE6_CLINICAL_WORKBENCH',
}
signoff_name = f'{sid}.medical_director_workbench_signoff.json'
Path(signoff_name).write_text(json.dumps(payload, indent=2) + "\\n", encoding='utf-8')
signoff_path = str(Path(signoff_name).resolve())
fragment = {
    'sample_id': sid,
    'component': 'workbench_gateway',
    'signoff': signoff_path,
    'signoff_status': 'PENDING_DIRECTOR_REVIEW',
    'candidate_vus_count': candidate_count,
    'reported_variant_count': reported_count,
    'status': 'PASS',
}
Path(f'{sid}.stage6_workbench.fragment.json').write_text(json.dumps(fragment, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    python3 - <<'PYEOF'
import hashlib, json
from pathlib import Path
sid = '${meta.sample_id}'
payload = {
    'node': 'MEDICAL_DIRECTOR_WORKBENCH_GATEWAY',
    'sample_id': sid,
    'signoff_status': 'PENDING_DIRECTOR_REVIEW',
    'manual_variant_overrides': [],
    'sanger_confirmation_inputs': [],
    'digital_signatures': [{
        'signature_algorithm': 'RS256',
        'signature_value': 'STUB',
        'signer_id': 'clinical_signer',
        'public_key_fingerprint': 'STUB',
    }],
    'approval_digest': 'stub',
    'workflow_gate': 'STAGE6_CLINICAL_WORKBENCH',
}
signoff_name = f'{sid}.medical_director_workbench_signoff.json'
Path(signoff_name).write_text(json.dumps(payload, indent=2) + '\\n', encoding='utf-8')
Path(f'{sid}.stage6_workbench.fragment.json').write_text(json.dumps({'sample_id': sid, 'component': 'workbench_gateway', 'signoff': str(Path(signoff_name).resolve()), 'signoff_status': 'PENDING_DIRECTOR_REVIEW', 'status': 'PASS'}, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """
}
