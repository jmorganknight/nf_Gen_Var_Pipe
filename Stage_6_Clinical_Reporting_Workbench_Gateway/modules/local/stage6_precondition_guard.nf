process STAGE6_PRECONDITION_GUARD {

    label 'process_low'
    container 'genvar-reporting:2.1.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage6", mode: 'rellink', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(stage5_manifest), path(clinical_bundle_tar_gz), path(stage5_provenance_json), path(acmg_tiered_variants_json), path(candidate_vus_json), path(vus_queue_json), path(sf_artifact), path(prs_artifact), path(pgx_artifact), val(reference_meta)

    output:
    tuple val(meta), path(stage5_manifest), path(clinical_bundle_tar_gz), path(stage5_provenance_json), path(acmg_tiered_variants_json), path(candidate_vus_json), path(vus_queue_json), path(sf_artifact), path(prs_artifact), path(pgx_artifact), val(reference_meta), emit: validated_bundle
    path "${meta.sample_id}.stage6_precondition_guard.json", emit: guard_audit
    tuple val(meta), path("${meta.sample_id}.stage6_precondition.fragment.json"), emit: fragment

    script:
    def sid = meta.sample_id
    def token = meta.validation_token?.toString() ?: ''
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path
import os

sid = '${sid}'
reference_meta = json.loads('''${groovy.json.JsonOutput.toJson(reference_meta)}''')

def normalize_optional(path_text: str):
    text = (path_text or '').strip()
    if not text:
        return None
    base = os.path.basename(text)
    if base == 'NO_FILE' or base.startswith('NO_FILE.'):
        return None
    return text

audit = {
    'node': 'STAGE6_PRECONDITION_GUARD',
    'sample_id': sid,
    'component': 'precondition',
    'validation_token': '${token}',
    'preflight_lock': reference_meta.get('preflight_lock', '') if isinstance(reference_meta, dict) else '',
    'preflight_lock_status': reference_meta.get('preflight_lock_status', '') if isinstance(reference_meta, dict) else '',
    'stage5_manifest': '${stage5_manifest}',
    'clinical_bundle_tar_gz': normalize_optional('${clinical_bundle_tar_gz}'),
    'stage5_provenance_json': normalize_optional('${stage5_provenance_json}'),
    'stage5_bundle_present': ('${meta.stage5_bundle_present ? 'true' : 'false'}' == 'true'),
    'stage5_provenance_present': ('${meta.stage5_provenance_present ? 'true' : 'false'}' == 'true'),
    'acmg_tiered_variants_json': '${acmg_tiered_variants_json}',
    'candidate_vus_json': '${candidate_vus_json}',
    'vus_queue_json': '${vus_queue_json}',
    'sf_artifact': '${sf_artifact}',
    'prs_artifact': '${prs_artifact}',
    'pgx_artifact': '${pgx_artifact}',
    'reference_assets_checked': sorted(reference_meta.keys()) if isinstance(reference_meta, dict) else [],
    'status': 'PASS',
}
if not audit['preflight_lock']:
    raise SystemExit(f"STAGE6_PRECONDITION_FAILURE: missing preflight_lock reference for {sid}")
if audit['preflight_lock_status'] != 'STAGE0_PREFLIGHT_LOCK_PASS':
    raise SystemExit(f"STAGE6_PRECONDITION_FAILURE: invalid preflight_lock_status for {sid}: {audit['preflight_lock_status']}")
Path(f'{sid}.stage6_precondition_guard.json').write_text(json.dumps(audit, indent=2) + "\\n", encoding='utf-8')
fragment = {
    'sample_id': sid,
    'component': 'precondition',
    'guard_audit': f'{sid}.stage6_precondition_guard.json',
    'status': 'PASS',
}
Path(f'{sid}.stage6_precondition.fragment.json').write_text(json.dumps(fragment, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    printf '{"node":"STAGE6_PRECONDITION_GUARD","sample_id":"%s","preflight_lock":"%s","preflight_lock_status":"%s","status":"PASS","stub":true}' "${meta.sample_id}" "${reference_meta.preflight_lock ?: ''}" "${reference_meta.preflight_lock_status ?: ''}" > "${meta.sample_id}.stage6_precondition_guard.json"
    printf '{"sample_id":"%s","component":"precondition","guard_audit":"%s.stage6_precondition_guard.json","status":"PASS"}' "${meta.sample_id}" "${meta.sample_id}" > "${meta.sample_id}.stage6_precondition.fragment.json"
    """
}
