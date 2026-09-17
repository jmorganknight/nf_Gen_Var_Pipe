process ASSEMBLE_STAGE6_MANIFEST {

    label 'process_low'
    container 'genvar-reporting:2.1.0'
    stageInMode 'copy'

    publishDir "${params.stage6_outdir}", mode: 'copy', overwrite: true, pattern: 'samples_*_stage6.yaml'

    input:
    path manifest_fragments
    path provenance_audits
    path lab_metrics

    output:
    path 'samples_*_stage6.yaml', emit: stage6_manifest

    script:
    def publishedStage6Dir = new File(params.stage6_outdir.toString()).isAbsolute()
        ? new File(params.stage6_outdir.toString()).canonicalPath
        : new File(workflow.launchDir.toString(), params.stage6_outdir.toString()).canonicalPath
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
published_stage6_dir = Path('${publishedStage6Dir}')
published_audit_dir = published_stage6_dir / 'audit_and_qc'
published_reporting_dir = published_stage6_dir / 'reporting'


def fail(message: str):
    raise SystemExit(f'STAGE6_MANIFEST_ERROR: {message}')


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except Exception as exc:
        fail(f'failed to parse JSON at {path}: {exc}')


def require_nonempty_text(container: dict, key: str, sid: str, component: str):
    value = container.get(key, '')
    text = str(value).strip() if value is not None else ''
    if not text:
        fail(f'missing required field {component}.{key} for sample {sid}')
    template_token = chr(36) + '{'
    if template_token in text:
        fail(f'unresolved template literal in {component}.{key} for sample {sid}: {text}')
    return text


def resolve_existing_path(path_text: str, sid: str, field_name: str, allow_missing: bool = False):
    raw = (path_text or '').strip()
    if not raw:
        fail(f'missing required path {field_name} for sample {sid}')
    template_token = chr(36) + '{'
    if template_token in raw:
        fail(f'unresolved template literal in {field_name} for sample {sid}: {raw}')
    candidate = Path(raw)
    resolved = (candidate if candidate.is_absolute() else (Path.cwd() / candidate)).resolve()
    if not resolved.exists():
        basename = candidate.name
        for fallback_dir in (published_audit_dir, published_reporting_dir, published_stage6_dir):
            fallback = (fallback_dir / basename).resolve()
            if fallback.exists():
                return str(fallback)
        if allow_missing:
            return str(candidate)
        fail(f'path does not exist for {field_name} sample {sid}: {resolved}')
    return str(resolved)


def resolve_existing_dir(path_text: str, sid: str, field_name: str):
    resolved = Path(resolve_existing_path(path_text, sid, field_name))
    if not resolved.is_dir():
        fail(f'expected directory for {field_name} sample {sid}: {resolved}')
    return str(resolved)


def parse_required_int(container: dict, key: str, sid: str, component: str):
    if key not in container:
        fail(f'missing required numeric field {component}.{key} for sample {sid}')
    try:
        return int(container.get(key))
    except Exception:
        fail(f'invalid integer for {component}.{key} sample {sid}: {container.get(key)}')


by_sample = defaultdict(dict)
for path in fragment_paths:
    data = read_json(path)
    sid = str(data.get('sample_id', '')).strip()
    if not sid:
        fail(f'fragment missing sample_id: {path}')
    component = data.get('component', path.stem)
    by_sample[sid][component] = data

for path in provenance_paths:
    data = read_json(path)
    sid = str(data.get('sample_id', '')).strip()
    if not sid:
        fail(f'provenance payload missing sample_id: {path}')
    by_sample[sid]['provenance_sink'] = {
        'provenance_json': str(path.resolve()),
        'status': data.get('status', 'PASS'),
    }

for path in lab_metrics_paths:
    data = read_json(path)
    sid = str(data.get('sample_id', '')).strip()
    if not sid:
        fail(f'lab metrics payload missing sample_id: {path}')
    by_sample[sid]['lab_metrics_sink'] = {
        'lab_metrics_json': str(path.resolve()),
        'status': data.get('status', 'PASS'),
    }

if not by_sample:
    fail('no sample fragments were provided to Stage 6 manifest assembly')

lines = []
lines.append('# ==============================================================================')
lines.append('# STAGE 6 MANIFEST')
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

    if not isinstance(pre, dict):
        fail(f'precondition component missing or malformed for sample {sid}')
    if not isinstance(integ, dict):
        fail(f'variant_integrity component missing or malformed for sample {sid}')
    if not isinstance(wetlab, dict):
        fail(f'wetlab_confirmation component missing or malformed for sample {sid}')
    if not isinstance(wb, dict):
        fail(f'workbench_gateway component missing or malformed for sample {sid}')
    if not isinstance(report, dict):
        fail(f'fhir_report component missing or malformed for sample {sid}')
    if not isinstance(metrics, dict):
        fail(f'lab_metrics_sink component missing or malformed for sample {sid}')

    validation_token = require_nonempty_text(pre, 'validation_token', sid, 'precondition')
    run_mode = require_nonempty_text(pre, 'run_mode', sid, 'precondition')
    contamination_status = str(pre.get('stage2_contamination_status', '') or '').strip()
    contamination_action = str(pre.get('stage2_contamination_policy_action', '') or '').strip()
    if not contamination_status:
        if run_mode.lower() in ('dev', 'audit_only'):
            contamination_status = 'NOT_APPLICABLE_RUO_DEV'
        else:
            fail(f'missing required field precondition.stage2_contamination_status for sample {sid}')
    if not contamination_action:
        if run_mode.lower() in ('dev', 'audit_only'):
            contamination_action = 'NOT_APPLICABLE_RUO_DEV'
        else:
            fail(f'missing required field precondition.stage2_contamination_policy_action for sample {sid}')
    save_dir = require_nonempty_text(pre, 'save_dir', sid, 'precondition')

    allow_missing_paths = run_mode.lower() in ('dev', 'audit_only')
    stage6_precondition_guard_json = resolve_existing_path(require_nonempty_text(pre, 'guard_audit', sid, 'precondition'), sid, 'stage6_precondition_guard_json', allow_missing_paths)
    stage6_variant_integrity_audit_json = resolve_existing_path(require_nonempty_text(integ, 'integrity_audit', sid, 'variant_integrity'), sid, 'stage6_variant_integrity_audit_json', allow_missing_paths)
    stage6_variant_ledger_json = resolve_existing_path(require_nonempty_text(integ, 'variant_ledger', sid, 'variant_integrity'), sid, 'stage6_variant_ledger_json', allow_missing_paths)
    wetlab_confirmation_pending_queue_json = resolve_existing_path(require_nonempty_text(wetlab, 'pending_queue', sid, 'wetlab_confirmation'), sid, 'wetlab_confirmation_pending_queue_json', allow_missing_paths)
    medical_director_signoff_json = resolve_existing_path(require_nonempty_text(wb, 'signoff', sid, 'workbench_gateway'), sid, 'medical_director_signoff_json', allow_missing_paths)
    fhir_genomics_json = resolve_existing_path(require_nonempty_text(report, 'fhir_json', sid, 'fhir_report'), sid, 'fhir_genomics_json', allow_missing_paths)
    clinical_report_html = resolve_existing_path(require_nonempty_text(report, 'html_report', sid, 'fhir_report'), sid, 'clinical_report_html', allow_missing_paths)
    clinical_report_pdf = resolve_existing_path(require_nonempty_text(report, 'pdf_report', sid, 'fhir_report'), sid, 'clinical_report_pdf', allow_missing_paths)

    provenance_value = report.get('provenance_audit_json', '')
    if not str(provenance_value).strip() and isinstance(prov, dict):
        provenance_value = prov.get('provenance_json', '')
    provenance_audit_json = resolve_existing_path(str(provenance_value), sid, 'provenance_audit_json', allow_missing_paths)
    lab_metrics_json = resolve_existing_path(require_nonempty_text(metrics, 'lab_metrics_json', sid, 'lab_metrics_sink'), sid, 'lab_metrics_json', allow_missing_paths)

    reported_variant_count = parse_required_int(integ, 'reported_variant_count', sid, 'variant_integrity')
    candidate_vus_count = parse_required_int(integ, 'candidate_vus_count', sid, 'variant_integrity')
    upgraded_vus_count = parse_required_int(integ, 'upgraded_vus_count', sid, 'variant_integrity')
    pending_confirmation_count = parse_required_int(wetlab, 'pending_confirmation_count', sid, 'wetlab_confirmation')
    signoff_status_value = wb.get('signoff_status', report.get('report_status', ''))
    signoff_status = str(signoff_status_value).strip()
    if not signoff_status:
        fail(f'missing required signoff status for sample {sid}')
    template_token = chr(36) + '{'
    if template_token in signoff_status:
        fail(f'unresolved template literal in signoff status for sample {sid}: {signoff_status}')

    lines.append(f'  - sample_id: "{sid}"')
    lines.append(f'    validation_token: "{validation_token}"')
    lines.append(f'    run_mode: "{run_mode}"')
    lines.append(f'    stage2_contamination_status: "{contamination_status}"')
    lines.append(f'    stage2_contamination_policy_action: "{contamination_action}"')
    lines.append('    stage6_outputs:')
    lines.append(f'      stage6_precondition_guard_json: "{stage6_precondition_guard_json}"')
    lines.append(f'      stage6_variant_integrity_audit_json: "{stage6_variant_integrity_audit_json}"')
    lines.append(f'      stage6_variant_ledger_json: "{stage6_variant_ledger_json}"')
    lines.append(f'      wetlab_confirmation_pending_queue_json: "{wetlab_confirmation_pending_queue_json}"')
    lines.append(f'      medical_director_signoff_json: "{medical_director_signoff_json}"')
    lines.append(f'      fhir_genomics_json: "{fhir_genomics_json}"')
    lines.append(f'      clinical_report_html: "{clinical_report_html}"')
    lines.append(f'      clinical_report_pdf: "{clinical_report_pdf}"')
    lines.append(f'      provenance_audit_json: "{provenance_audit_json}"')
    lines.append(f'      lab_metrics_json: "{lab_metrics_json}"')
    lines.append('    integrity_summary:')
    lines.append(f'      reported_variant_count: {reported_variant_count}')
    lines.append(f'      candidate_vus_count: {candidate_vus_count}')
    lines.append(f'      upgraded_vus_count: {upgraded_vus_count}')
    lines.append(f'      pending_confirmation_count: {pending_confirmation_count}')
    lines.append(f'      signoff_status: "{signoff_status}"')
    lines.append(f'    save_dir: "{save_dir}"')

content = '\\n'.join(lines) + '\\n'
sample_ids = sorted(str(sid) for sid in by_sample.keys())
canonical_id = sample_ids[0] if len(sample_ids) == 1 else 'multi_sample'
safe_id = ''.join(ch if (ch.isalnum() or ch in ('_', '-')) else '_' for ch in canonical_id) or 'UNKNOWN'
Path(f'samples_{safe_id}_stage6.yaml').write_text(content, encoding='utf-8')
PYEOF
    """
}
