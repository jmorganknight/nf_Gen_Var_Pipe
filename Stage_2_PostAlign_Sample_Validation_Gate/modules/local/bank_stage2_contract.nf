process STAGE2_CONTRACT {

    label 'process_low'
    container 'genvar-core:2.1.0'

    publishDir "${params.stage2_outdir}/contracts/stage2", mode: 'copy', overwrite: true, pattern: '*.stage2.contract.fragment.json'

    input:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path(precondition_audit), path(contamination_audit), path(purity_sex_audit), path(router_audit)

    output:
    path "${meta.sample_id}.stage2.contract.fragment.json", emit: manifest_fragment

    script:
    def metaJson = groovy.json.JsonOutput.toJson(meta).replace('\\', '\\\\').replace("'", "\\'")
    def refsJson = groovy.json.JsonOutput.toJson(refs).replace('\\', '\\\\').replace("'", "\\'")
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from datetime import datetime, timezone
from pathlib import Path

meta = json.loads('${metaJson}')
refs = json.loads('${refsJson}')
sid = meta['sample_id']
contamination_payload = json.loads(Path('${contamination_audit}').read_text(encoding='utf-8'))
purity_sex_payload = json.loads(Path('${purity_sex_audit}').read_text(encoding='utf-8'))

contam_status = str(contamination_payload.get('status') or '').upper()
run_mode = str(meta.get('run_mode') or 'production').strip().lower()
if run_mode == 'audit_only':
    run_mode = 'dev'
audit_mode = run_mode in ('dev', 'audit_only')
if contam_status != 'PASS' and not audit_mode:
    detail = contamination_payload.get('failure_detail') or contamination_payload.get('skip_reason') or 'contamination gate did not PASS'
    raise SystemExit(
        f"STAGE2_BANKING_PRECONDITION_FAILURE: contamination audit status={contam_status} for sample '{sid}' -> {detail}"
    )

policy_action = 'CONTINUE_FOR_AUDIT' if contam_status != 'PASS' and audit_mode else 'PASS_THROUGH'

purity_block = purity_sex_payload.get('purity_validation', {})
sex_block = purity_sex_payload.get('sex_concordance', {})

sample_qc_meta = {
    'estimated_in_silico_purity': purity_block.get('estimated_in_silico_purity'),
    'contamination_rate': contamination_payload.get('contamination_rate'),
    'computed_sex': sex_block.get('computed_sex', 'UNKNOWN'),
    'sex_concordance_pass': bool(sex_block.get('sex_concordance_pass', False)),
    'purity_concordance_pass': bool(purity_block.get('purity_concordance_pass', False)),
}

payload = dict(meta)
payload.update({
    'sample_id': sid,
    'run_mode': run_mode,
    'sorted_bam': str(Path('${bam}').resolve()),
    'sorted_bai': str(Path('${bai}').resolve()),
    'sorted_bam_basename': meta.get('sorted_bam_basename') or Path('${bam}').name,
    'sorted_bai_basename': meta.get('sorted_bai_basename') or Path('${bai}').name,
    'stage2_precondition_audit': str(Path('${precondition_audit}').resolve()),
    'contamination_audit': str(Path('${contamination_audit}').resolve()),
    'purity_and_sex_validation_audit': str(Path('${purity_sex_audit}').resolve()),
    'assay_target_router_audit': str(Path('${router_audit}').resolve()),
    'stage2_contamination_status': contam_status,
    'stage2_contamination_policy_action': policy_action,
    'estimated_in_silico_purity': sample_qc_meta['estimated_in_silico_purity'],
    'contamination_rate': sample_qc_meta['contamination_rate'],
    'computed_sex': sample_qc_meta['computed_sex'],
    'sex_concordance_pass': sample_qc_meta['sex_concordance_pass'],
    'purity_concordance_pass': sample_qc_meta['purity_concordance_pass'],
    'sample_qc_meta': sample_qc_meta,
    'reference_build': {
        **(meta.get('reference_build') or {}),
        'reference_genome': refs.get('reference_genome'),
        'reference_fai': refs.get('reference_fai'),
        'reference_dict': refs.get('reference_dict'),
        'capture_wes_bed': refs.get('capture_wes_bed') or refs.get('onco_target_bed'),
        'onco_target_bed': refs.get('onco_target_bed') or refs.get('capture_wes_bed'),
        'sf_bed': refs.get('sf_bed'),
        'clinvar_db': refs.get('clinvar_db')
    },
    'save_dir': meta.get('save_dir'),
    'stage2_timestamp_utc': datetime.now(timezone.utc).isoformat(),
})

if contam_status != 'PASS' and audit_mode:
    payload['stage2_governance_note'] = 'CONTAMINATION_FAILURE_CONTINUED_FOR_DEV_MODE'
    payload['validation_token'] = meta.get('validation_token')

Path(f"{sid}.stage2.contract.fragment.json").write_text(json.dumps(payload, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """
}
