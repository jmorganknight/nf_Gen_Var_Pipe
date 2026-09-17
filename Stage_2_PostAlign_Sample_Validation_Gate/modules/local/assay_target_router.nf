process ASSAY_TARGET_ROUTER {

    label 'process_low'
    container 'genvar-core:2.1.0'

    publishDir "${params.stage2_outdir}/audit_and_qc/stage2", mode: 'copy', overwrite: true,
        pattern: "*.assay_target_router_audit.json"

    input:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path(precondition_audit), path(contamination_audit), path(purity_sex_audit)

    output:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path(precondition_audit), path(contamination_audit), path(purity_sex_audit), path("${meta.sample_id}.stage2_routing.json"), path("${meta.sample_id}.assay_target_router_audit.json"), emit: validated

    script:
    def metaJson = groovy.json.JsonOutput.toJson(meta).replace('\\', '\\\\').replace("'", "\\'")
    def refsJson = groovy.json.JsonOutput.toJson(refs).replace('\\', '\\\\').replace("'", "\\'")
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def validate_bed(path_text: str):
    bed = Path(path_text)
    if not bed.exists():
        return False, 'BED file does not exist'
    if bed.stat().st_size == 0:
        return False, 'BED file is empty'

    seen = 0
    for line in bed.read_text(encoding='utf-8', errors='replace').splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        cols = line.split('\t')
        if len(cols) < 3:
            return False, 'BED line has fewer than 3 columns'
        try:
            start = int(cols[1])
            end = int(cols[2])
        except ValueError:
            return False, 'BED start/end is not integer'
        if end <= start:
            return False, 'BED interval has end <= start'
        seen += 1
        if seen >= 10:
            break

    if seen == 0:
        return False, 'BED has no valid intervals'
    return True, 'ok'


meta = json.loads('${metaJson}')
refs = json.loads('${refsJson}')
sid = meta['sample_id']
seq_type = str(meta.get('sequencing_type') or 'WES').upper()

required_bed = None
if seq_type == 'WES':
    required_bed = refs.get('capture_wes_bed') or refs.get('onco_target_bed')
elif seq_type == 'PANEL':
    required_bed = meta.get('virtual_panel_bed')
elif seq_type == 'WGS':
    required_bed = None
else:
    required_bed = refs.get('capture_wes_bed') or refs.get('onco_target_bed')
    seq_type = 'WES'

failure = None
bed_valid = True
bed_validation_note = 'not_required_for_wgs'
branch_catalog_required = bool(meta.get('variant_branches', {}).get('snv_indel')) or bool(meta.get('variant_branches', {}).get('str_expansions'))
if required_bed:
    bed_valid, bed_validation_note = validate_bed(required_bed)
    if not bed_valid:
        failure = f"invalid target BED for {seq_type}: {required_bed} ({bed_validation_note})"
        if branch_catalog_required:
            failure = f"missing or invalid branch catalog for enabled branches: {required_bed} ({bed_validation_note})"
            router_failure_code = 'REJECT_MISSING_BRANCH_CATALOG'
        else:
            router_failure_code = 'STAGE2_ROUTING_FAILURE'
else:
    if branch_catalog_required:
        failure = f"missing branch catalog for enabled branches in {seq_type}"
        router_failure_code = 'REJECT_MISSING_BRANCH_CATALOG'
    else:
        router_failure_code = 'STAGE2_ROUTING_FAILURE'
routing = {
    'sample_id': sid,
    'sequencing_type': seq_type,
    'snv_mask_bed': required_bed,
    'cnv_target_bed': required_bed,
    'sv_calling_enabled': True,
    'variant_branches': meta.get('variant_branches', {}),
    'virtual_panel_bed': meta.get('virtual_panel_bed'),
    'stage2_router_token': f"{seq_type}|TARGET_VALIDATED",
}

router_audit = {
    'node': 'ASSAY_TARGET_ROUTER',
    'sample_id': sid,
    'timestamp_utc': datetime.now(timezone.utc).isoformat(),
    'status': 'PASS',
    'sequencing_type': seq_type,
    'target_bed_required': bool(required_bed),
    'target_bed_path': required_bed,
    'target_bed_valid': bed_valid,
    'target_bed_validation_note': bed_validation_note,
    'routing': routing,
    'precondition_audit': '${precondition_audit}',
    'contamination_audit': '${contamination_audit}',
    'purity_and_sex_validation_audit': '${purity_sex_audit}'
}

if failure:
    router_audit['status'] = 'FAIL'
    router_audit['failure_code'] = router_failure_code
    router_audit['failure_detail'] = failure

Path(f"{sid}.stage2_routing.json").write_text(json.dumps(routing, indent=2) + '\\n', encoding='utf-8')
Path(f"{sid}.assay_target_router_audit.json").write_text(json.dumps(router_audit, indent=2) + '\\n', encoding='utf-8')

if failure:
    print('STAGE2_ROUTING_FAILURE: ' + failure, file=sys.stderr)
    sys.exit(1)
PYEOF
    """
}
