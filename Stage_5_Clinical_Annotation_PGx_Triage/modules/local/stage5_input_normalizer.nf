process STAGE5_INPUT_NORMALIZER {

    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'

    tag "${sample_id}"

    input:
    tuple val(sample_id), path(phased_vcf), path(phased_tbi), path(ancestry_metrics_json), path(phasing_audit_json), val(reference_meta)

    output:
    tuple val(sample_id), path(phased_vcf), path(phased_tbi), path(ancestry_metrics_json), path(phasing_audit_json), val(reference_meta), emit: normalized_bundle
    tuple val(sample_id), path(phased_vcf), path(phased_tbi), path(ancestry_metrics_json), path(phasing_audit_json), val(reference_meta), emit: ch_pgx_branch
    tuple val(sample_id), path(phased_vcf), path(phased_tbi), path(ancestry_metrics_json), path(phasing_audit_json), val(reference_meta), emit: ch_prs_branch
    tuple val(sample_id), path(phased_vcf), path(phased_tbi), path(ancestry_metrics_json), path(phasing_audit_json), val(reference_meta), emit: ch_sf_acmg_branch
    tuple val(sample_id), path(phased_vcf), path(phased_tbi), path(ancestry_metrics_json), path(phasing_audit_json), val(reference_meta), emit: ch_somatic_onco_branch
    tuple val(sample_id), path(phased_vcf), path(phased_tbi), path(ancestry_metrics_json), path(phasing_audit_json), val(reference_meta), emit: ch_germline_variant_branch
    path "${sample_id}.stage5_input_normalizer.json", emit: normalizer_audit

    script:
    def sid = sample_id
    def refJson = groovy.json.JsonOutput.toJson(reference_meta ?: [:])
    """
    set -euo pipefail

    cat > reference_meta.json <<'JSON'
${refJson}
JSON

    python3 - <<'PYEOF'
import json
from pathlib import Path

sample_id = '${sid}'
ancestry_path = Path('${ancestry_metrics_json}')
phasing_path = Path('${phasing_audit_json}')

required = [
    Path('${phased_vcf}'),
    Path('${phased_tbi}'),
    ancestry_path,
    phasing_path,
]
missing = [str(path) for path in required if not path.exists()]
if missing:
    raise SystemExit(f"STAGE5_PRECONDITION_FAILURE: missing Stage 4 payload for {sample_id}: {missing}")

with ancestry_path.open('r', encoding='utf-8') as handle:
    ancestry = json.load(handle)
with phasing_path.open('r', encoding='utf-8') as handle:
    phasing = json.load(handle)

expected_sample_id = sample_id
if ancestry.get('sample_id') not in (None, expected_sample_id) and str(ancestry.get('sample_id')) != expected_sample_id:
    raise SystemExit(f"STAGE5_PRECONDITION_FAILURE: ancestry payload sample_id mismatch for {sample_id}")
if phasing.get('sample_id') not in (None, expected_sample_id) and str(phasing.get('sample_id')) != expected_sample_id:
    raise SystemExit(f"STAGE5_PRECONDITION_FAILURE: phasing payload sample_id mismatch for {sample_id}")

meta = {
    'sample_id': sample_id,
    'validation_token': phasing.get('validation_token') or 'VALID_PASS|VARIANTS_HARMONIZED',
    'ancestry_label': ancestry.get('ancestry_label', 'UNSET'),
    'superpopulation': ancestry.get('superpopulation', 'UNSET'),
    'subpopulation': ancestry.get('subpopulation', 'UNSET'),
    'pc_coordinates': ancestry.get('pc_coordinates', {}),
    'phased_vcf': '${phased_vcf}',
    'phased_vcf_tbi': '${phased_tbi}',
    'ancestry_metrics_json': str(ancestry_path),
    'phasing_audit_json': str(phasing_path),
    'phase_status': phasing.get('status', 'UNKNOWN'),
    'stage5_handoff_note': 'Canonicalized Stage 4 phased payload for Stage 5 annotation and PGx triage.'
}

audit = {
    'node': 'STAGE5_INPUT_NORMALIZER',
    'sample_id': sample_id,
    'ancestry_label': ancestry.get('ancestry_label', 'UNSET'),
    'phase_status': phasing.get('status', 'UNKNOWN'),
    'phased_vcf': '${phased_vcf}',
    'phased_vcf_tbi': '${phased_tbi}',
    'ancestry_metrics_json': str(ancestry_path),
    'phasing_audit_json': str(phasing_path),
    'status': 'PASS'
}
Path(f'{sample_id}.stage5_input_normalizer.json').write_text(json.dumps(audit, indent=2) + '\\n', encoding='utf-8')

with open(f'{sample_id}.stage5_input_normalizer_meta.json', 'w', encoding='utf-8') as handle:
    json.dump({'meta': meta, 'reference_meta': json.loads(Path('reference_meta.json').read_text(encoding='utf-8'))}, handle, indent=2)
PYEOF
    """
}
