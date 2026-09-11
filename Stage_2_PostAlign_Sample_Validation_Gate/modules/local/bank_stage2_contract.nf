process BANK_STAGE2_CONTRACT {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    publishDir "${params.outdir}/contracts/stage2", mode: 'copy', overwrite: true, pattern: '*.stage2.contract.fragment.json'

    input:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path(precondition_audit), path(purity_sex_audit), path(router_audit)

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

payload = {
    'sample_id': sid,
    'patient_id': meta.get('patient_id'),
    'case_id': meta.get('case_id'),
    'sample_type': meta.get('sample_type'),
    'sequencing_type': meta.get('sequencing_type'),
    'reported_sex': meta.get('reported_sex'),
    'consent': meta.get('consent', {}),
    'consent_tokens': meta.get('consent_tokens', {}),
    'variant_branches': meta.get('variant_branches', {}),
    'biological_context': meta.get('biological_context', {}),
    'diagnosis': meta.get('diagnosis', {}),
    'specimen': meta.get('specimen', {}),
    'clinical_context': meta.get('clinical_context', {}),
    'sequencer': meta.get('sequencer', {}),
    'pathologist_tumor_burden': meta.get('pathologist_tumor_burden', 0.0),
    'physician_tumor_purity': meta.get('physician_tumor_purity', 0.0),
    'intake_validation_token': meta.get('intake_validation_token'),
    'validation_token': meta.get('validation_token'),
    'intake_validation_report': meta.get('intake_validation_report'),
    'intake_route_decision': meta.get('intake_route_decision'),
    'stage0_audit_bundle': meta.get('stage0_audit_bundle'),
    'identity_audit': meta.get('identity_audit'),
    'sorted_bam': str(Path('${bam}').resolve()),
    'sorted_bai': str(Path('${bai}').resolve()),
    'snv_mask_bed': meta.get('snv_mask_bed'),
    'cnv_target_bed': meta.get('cnv_target_bed'),
    'sv_calling_enabled': meta.get('sv_calling_enabled'),
    'stage2_router_token': meta.get('stage2_router_token'),
    'stage2_precondition_audit': str(Path('${precondition_audit}').resolve()),
    'purity_and_sex_validation_audit': str(Path('${purity_sex_audit}').resolve()),
    'assay_target_router_audit': str(Path('${router_audit}').resolve()),
    'reference_build': {
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
}

Path(f"{sid}.stage2.contract.fragment.json").write_text(json.dumps(payload, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """
}
