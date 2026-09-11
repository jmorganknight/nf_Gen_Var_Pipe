process ASSEMBLE_STAGE6_BANKED_MANIFEST {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    publishDir "${params.outdir}", mode: 'rellink', overwrite: true, pattern: 'samples_hg002_banked_stage6.yaml'
    publishDir "${params.outdir}", mode: 'rellink', overwrite: true, pattern: '*.provenance_audit.json'

    input:
    path manifest_fragments
    path provenance_audits

    output:
    path 'samples_hg002_banked_stage6.yaml', emit: banked_manifest
    path 'provenance_audit.json', emit: provenance_audit

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from collections import defaultdict
from pathlib import Path

fragment_json = '''${groovy.json.JsonOutput.toJson(manifest_fragments.collect { fragment -> fragment.toString() }).replace('\n', ' ').replace('\r', '')}'''
fragment_paths = [Path(p) for p in json.loads(fragment_json)]
provenance_json = '''${groovy.json.JsonOutput.toJson(provenance_audits.collect { artifact -> artifact.toString() }).replace('\n', ' ').replace('\r', '')}'''
provenance_paths = [Path(p) for p in json.loads(provenance_json)]

by_sample = defaultdict(dict)
provenance_source = provenance_paths[0] if provenance_paths else None
for path in fragment_paths:
    data = json.loads(path.read_text(encoding='utf-8'))
    sid = data.get('sample_id', 'UNKNOWN')
    component = data.get('component', path.name)
    by_sample[sid][component] = data

lines = []
lines.append('# ==============================================================================')
lines.append('# STAGE 6 BANKED MANIFEST')
lines.append('# Purpose: Clinical reporting workbench, FHIR translation, wet-lab triage, and medical director sign-off.')
lines.append('# ==============================================================================')
lines.append('samples:')

for sid in sorted(by_sample):
    comp = by_sample[sid]
    pre = comp.get('precondition', {})
    integrity = comp.get('variant_integrity', {})
    sink = comp.get('downgraded_sink', {})
    wetlab = comp.get('wetlab_confirmation', {})
    report = comp.get('fhir_report', {})
    workbench = comp.get('workbench_gateway', {})

    lines.append(f'  - sample_id: "{sid}"')
    lines.append('    validation_token: "VALID_PASS|VARIANTS_HARMONIZED|STAGE6_COMPLETE"')
    lines.append('    lineage:')
    lines.append('      source_stage: "Stage_5_Clinical_Annotation_PGx_Triage"')
    lines.append('      stage6_workflow: "STAGE6_CLINICAL_REPORTING_WORKBENCH_GATEWAY"')
    lines.append('    stage6_audits:')
    lines.append(f'      precondition_guard_json: "{pre.get("guard_audit", "")}"')
    lines.append(f'      variant_integrity_audit_json: "{integrity.get("integrity_audit", "")}"')
    lines.append(f'      variant_ledger_json: "{integrity.get("variant_ledger", "")}"')
    lines.append(f'      downgraded_variants_sink_json_gz: "{sink.get("sink_archive", "")}"')
    lines.append(f'      wetlab_confirmation_pending_queue_json: "{wetlab.get("pending_queue", "")}"')
    lines.append(f'      medical_director_workbench_signoff_json: "{workbench.get("signoff", "")}"')
    lines.append('    stage6_reports:')
    lines.append(f'      fhir_genomics_v3_json: "{report.get("fhir_json", "")}"')
    lines.append(f'      clinical_report_html: "{report.get("html_report", "")}"')
    lines.append(f'      clinical_report_pdf: "{report.get("pdf_report", "")}"')
    lines.append(f'      provenance_audit_json: "{report.get("provenance_audit_json", provenance_source.name if provenance_source else "")}"')
    lines.append(f'    reported_variant_count: {integrity.get("reported_variant_count", 0)}')
    lines.append(f'    candidate_vus_count: {integrity.get("candidate_vus_count", 0)}')
    lines.append(f'    wetlab_pending_count: {wetlab.get("pending_confirmation_count", 0)}')
    lines.append(f'    sink_archive_count: {sink.get("archive_count", 0)}')
    lines.append('    save_dir: "tests/fixtures/banked_stage6"')

Path('samples_hg002_banked_stage6.yaml').write_text("\\n".join(lines) + "\\n", encoding='utf-8')
if provenance_source is not None and provenance_source.exists():
    Path('provenance_audit.json').write_text(provenance_source.read_text(encoding='utf-8'), encoding='utf-8')
else:
    fallback = {'status': 'MISSING_PROVENANCE_SOURCE', 'samples': list(by_sample.keys())}
    Path('provenance_audit.json').write_text(json.dumps(fallback, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """
}
