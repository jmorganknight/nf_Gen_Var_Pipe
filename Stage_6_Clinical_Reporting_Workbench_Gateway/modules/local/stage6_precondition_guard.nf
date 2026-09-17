process STAGE6_PRECONDITION_GUARD {

    label 'process_low'
    container 'genvar-reporting:2.1.0'
    stageInMode 'copy'

    tag "${meta.sample_id}"

    publishDir "${params.stage6_outdir}/audit_and_qc", mode: 'copy', overwrite: true, pattern: '*.stage6_precondition*.json'

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


def normalize_optional_branch_artifact(path_text: str, provenance_text: str, is_ruo_dev: bool):
    text = normalize_optional(path_text)
    if text is None:
        return None
    if is_ruo_dev and provenance_text:
        if os.path.basename(text) == os.path.basename(provenance_text):
            return None
    return text


run_mode = '${meta.run_mode}'.strip().lower()
is_ruo_dev = run_mode in {'dev', 'audit_only'}
provenance_path_text = normalize_optional('${stage5_provenance_json}')

audit = {
    'node': 'STAGE6_PRECONDITION_GUARD',
    'sample_id': sid,
    'component': 'precondition',
    'validation_token': '${token}',
    'run_mode': '${meta.run_mode}',
    'stage2_contamination_status': '${meta.stage2_contamination_status}',
    'stage2_contamination_policy_action': '${meta.stage2_contamination_policy_action}',
    'save_dir': '${meta.save_dir}',
    'preflight_lock': reference_meta.get('preflight_lock', '') if isinstance(reference_meta, dict) else '',
    'preflight_lock_status': reference_meta.get('preflight_lock_status', '') if isinstance(reference_meta, dict) else '',
    'stage5_manifest': '${stage5_manifest}',
    'clinical_bundle_tar_gz': normalize_optional('${clinical_bundle_tar_gz}'),
    'stage5_provenance_json': provenance_path_text,
    'stage5_bundle_present': ('${meta.stage5_bundle_present ? 'true' : 'false'}' == 'true'),
    'stage5_provenance_present': ('${meta.stage5_provenance_present ? 'true' : 'false'}' == 'true'),
    'acmg_tiered_variants_json': normalize_optional_branch_artifact('${acmg_tiered_variants_json}', provenance_path_text or '', is_ruo_dev),
    'candidate_vus_json': normalize_optional_branch_artifact('${candidate_vus_json}', provenance_path_text or '', is_ruo_dev),
    'vus_queue_json': normalize_optional_branch_artifact('${vus_queue_json}', provenance_path_text or '', is_ruo_dev),
    'sf_artifact': normalize_optional_branch_artifact('${sf_artifact}', provenance_path_text or '', is_ruo_dev),
    'prs_artifact': normalize_optional_branch_artifact('${prs_artifact}', provenance_path_text or '', is_ruo_dev),
    'pgx_artifact': normalize_optional_branch_artifact('${pgx_artifact}', provenance_path_text or '', is_ruo_dev),
    'reference_assets_checked': sorted(reference_meta.keys()) if isinstance(reference_meta, dict) else [],
    'status': 'PASS',
}
run_mode = str(audit.get('run_mode', '') or '').strip().lower()
is_ruo_dev = run_mode in {'dev', 'audit_only'}

if not audit['preflight_lock']:
    if is_ruo_dev:
        audit['preflight_lock'] = ''
        audit['preflight_lock_status'] = audit['preflight_lock_status'] or 'NOT_DECLARED_IN_RUO_DEV_INPUT'
    else:
        raise SystemExit(f"STAGE6_PRECONDITION_FAILURE: missing preflight_lock reference for {sid}")
if audit['preflight_lock_status'] not in ('STAGE0_PREFLIGHT_LOCK_PASS', 'NOT_DECLARED_IN_RUO_DEV_INPUT'):
    raise SystemExit(f"STAGE6_PRECONDITION_FAILURE: invalid preflight_lock_status for {sid}: {audit['preflight_lock_status']}")
Path(f'{sid}.stage6_precondition_guard.json').write_text(json.dumps(audit, indent=2) + "\\n", encoding='utf-8')
guard_path = str(Path(f'{sid}.stage6_precondition_guard.json').resolve())
fragment = {
    'sample_id': sid,
    'component': 'precondition',
    'validation_token': '${token}',
    'run_mode': '${meta.run_mode}',
    'stage2_contamination_status': '${meta.stage2_contamination_status}',
    'stage2_contamination_policy_action': '${meta.stage2_contamination_policy_action}',
    'save_dir': '${meta.save_dir}',
    'guard_audit': guard_path,
    'status': 'PASS',
}
Path(f'{sid}.stage6_precondition.fragment.json').write_text(json.dumps(fragment, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    printf '{"node":"STAGE6_PRECONDITION_GUARD","sample_id":"%s","preflight_lock":"%s","preflight_lock_status":"%s","status":"PASS","stub":true}' "${meta.sample_id}" "${reference_meta.preflight_lock ?: ''}" "${reference_meta.preflight_lock_status ?: ''}" > "${meta.sample_id}.stage6_precondition_guard.json"
    printf '{"sample_id":"%s","component":"precondition","validation_token":"%s","run_mode":"%s","stage2_contamination_status":"%s","stage2_contamination_policy_action":"%s","save_dir":"%s","guard_audit":"%s/%s.stage6_precondition_guard.json","status":"PASS"}' "${meta.sample_id}" "${meta.validation_token}" "${meta.run_mode ?: ''}" "${meta.stage2_contamination_status ?: ''}" "${meta.stage2_contamination_policy_action ?: ''}" "${meta.save_dir ?: ''}" "\$PWD" "${meta.sample_id}" > "${meta.sample_id}.stage6_precondition.fragment.json"
    """
}
