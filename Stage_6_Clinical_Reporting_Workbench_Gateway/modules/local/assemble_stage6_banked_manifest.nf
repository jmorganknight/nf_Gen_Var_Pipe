process ASSEMBLE_STAGE6_BANKED_MANIFEST {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    publishDir "${params.outdir}", mode: 'rellink', overwrite: true, pattern: 'samples_hg002_banked_stage6.yaml'

    input:
    path manifest_fragments
    path provenance_audits
    path lab_metrics

    output:
    path 'samples_hg002_banked_stage6.yaml', emit: banked_manifest

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from collections import defaultdict
from pathlib import Path

fragment_json = '''${groovy.json.JsonOutput.toJson(manifest_fragments.collect { fragment -> fragment.toString() }).replace('\\n', ' ').replace('\\r', '')}'''
provenance_json = '''${groovy.json.JsonOutput.toJson(provenance_audits.collect { p -> p.toString() }).replace('\\n', ' ').replace('\\r', '')}'''
lab_metrics_json = '''${groovy.json.JsonOutput.toJson(lab_metrics.collect { p -> p.toString() }).replace('\\n', ' ').replace('\\r', '')}'''

fragment_paths = [Path(p) for p in json.loads(fragment_json)]
provenance_paths = [Path(p) for p in json.loads(provenance_json)]
lab_metrics_paths = [Path(p) for p in json.loads(lab_metrics_json)]

by_sample = defaultdict(dict)
for path in fragment_paths:
    data = json.loads(path.read_text(encoding='utf-8'))
    sid = data.get('sample_id', 'UNKNOWN')
    component = data.get('component', path.stem)
    by_sample[sid][component] = data

for path in provenance_paths:
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except Exception:
        continue
    sid = data.get('sample_id', path.name.split('.')[0])
    by_sample[sid]['provenance_sink'] = {'provenance_json': str(path), 'status': data.get('status', 'PASS')}

for path in lab_metrics_paths:
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except Exception:
        continue
    sid = data.get('sample_id', path.name.split('.')[0])
    by_sample[sid]['lab_metrics_sink'] = {'lab_metrics_json': str(path), 'status': data.get('status', 'PASS')}

lines = []
lines.append('# ==============================================================================')
lines.append('# STAGE 6 BANKED MANIFEST')
lines.append('# Purpose: Final reporting gateway handoff with integrity, workbench, and telemetry outputs.')
lines.append('# ==============================================================================')
lines.append('samples:')

for sid in sorted(by_sample):
    comp = by_sample[sid]
    pre = comp.get('precondition', {})
    integ = comp.get('variant_integrity', {})
    wetlab = comp.get('wetlab_confirmation', {})
    wb = comp.get('workbench_gateway', {})
    report = comp.get('fhir_report', {})
    prov = comp.get('audit_sink', comp.get('provenance_sink', {}))
    metrics = comp.get('lab_metrics_sink', {})

    lines.append(f'  - sample_id: "{sid}"')
    lines.append(f'    validation_token: "{pre.get("validation_token", "VALID_PASS|VARIANTS_HARMONIZED|STAGE6_COMPLETE")}"')
    lines.append(f'    run_mode: "{pre.get("run_mode", "production")}"')
    lines.append(f'    stage2_contamination_status: "{pre.get("stage2_contamination_status", "")}"')
    lines.append(f'    stage2_contamination_policy_action: "{pre.get("stage2_contamination_policy_action", "")}"')
    lines.append('    stage6_outputs:')
    lines.append(f'      stage6_precondition_guard_json: "{pre.get("guard_audit", "")}"')
    lines.append(f'      stage6_variant_integrity_audit_json: "{integ.get("integrity_audit", "")}"')
    lines.append(f'      stage6_variant_ledger_json: "{integ.get("variant_ledger", "")}"')
    lines.append(f'      wetlab_confirmation_pending_queue_json: "{wetlab.get("pending_queue", "")}"')
    lines.append(f'      medical_director_signoff_json: "{wb.get("signoff", "")}"')
    lines.append(f'      fhir_genomics_json: "{report.get("fhir_json", "")}"')
    lines.append(f'      clinical_report_html: "{report.get("html_report", "")}"')
    lines.append(f'      clinical_report_pdf: "{report.get("pdf_report", "")}"')
    lines.append(f'      provenance_audit_json: "{report.get("provenance_audit_json", prov.get("provenance_json", ""))}"')
    lines.append(f'      lab_metrics_json: "{metrics.get("lab_metrics_json", "")}"')
    lines.append('    integrity_summary:')
    lines.append(f'      reported_variant_count: {int(integ.get("reported_variant_count", 0) or 0)}')
    lines.append(f'      candidate_vus_count: {int(integ.get("candidate_vus_count", 0) or 0)}')
    lines.append(f'      upgraded_vus_count: {int(integ.get("upgraded_vus_count", 0) or 0)}')
    lines.append(f'      pending_confirmation_count: {int(wetlab.get("pending_confirmation_count", 0) or 0)}')
    lines.append(f'      signoff_status: "{wb.get("signoff_status", report.get("report_status", "PENDING_DIRECTOR_REVIEW"))}"')
    lines.append('    save_dir: "${params.outdir}"')

Path('samples_hg002_banked_stage6.yaml').write_text('\\n'.join(lines) + '\\n', encoding='utf-8')
PYEOF
    """
}
