process ASSEMBLE_STAGE2_BANKED_MANIFEST {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    publishDir "${params.outdir}", mode: 'copy', overwrite: true

    input:
    path fragments

    output:
    path 'samples_hg002_banked_stage2.yaml', emit: banked_manifest

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path


def q(value):
    if value is None:
        return 'null'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, (int, float)):
        return json.dumps(value)
    return json.dumps(str(value))


def append_kv(lines, indent, key, value, comment):
    pad = ' ' * indent
    lines.append(f"{pad}{key}: {q(value)}  # {comment}")


def append_map(lines, indent, name, mapping, comments):
    pad = ' ' * indent
    lines.append(f"{pad}{name}:")
    if mapping:
        for key, value in mapping.items():
            append_kv(lines, indent + 2, key, value, comments.get(key, 'Additional upstream metadata preserved for audit traceability.'))
    else:
        lines.append(f"{pad}  {{}}  # Optional section omitted upstream.")


records = []
for frag in sorted(Path('.').glob('*.json')):
    records.append(json.loads(frag.read_text(encoding='utf-8')))
records.sort(key=lambda x: x['sample_id'])

lines = [
    '# ==============================================================================',
    '# STAGE 2 BANKED MANIFEST',
    '# Purpose: Post-alignment validation gate contract emitted before heavy variant',
    '#          discovery callers, carrying fail-closed sex/purity/assay routing audits.',
    '# ==============================================================================',
    'samples:'
]

reference_comments = {
    'reference_genome': 'Reference FASTA for downstream normalization and caller consistency checks.',
    'reference_fai': 'FASTA index paired with reference_genome.',
    'reference_dict': 'Sequence dictionary for BAM/CRAM header compatibility checks.',
    'capture_wes_bed': 'WES capture BED used when sequencing_type is WES.',
    'onco_target_bed': 'Oncology target BED alias preserved for downstream compatibility.',
    'sf_bed': 'Secondary findings BED for optional ACMG workflows.',
    'clinvar_db': 'ClinVar or equivalent clinical interpretation resource pin.'
}

for rec in records:
    lines.append('  # ---------------------------------------------------------------------------')
    lines.append('  # Stage 2 validated record. This contract gates Stage 3 variant-caller routing.')
    append_kv(lines, 2, 'sample_id', rec.get('sample_id'), 'Stable sample identifier propagated through Stage 0-2.')
    append_kv(lines, 4, 'patient_id', rec.get('patient_id'), 'Patient identifier from clinical/LIMS intake.')
    append_kv(lines, 4, 'case_id', rec.get('case_id'), 'Case-level identifier retained for multi-sample context.')
    append_kv(lines, 4, 'sample_type', rec.get('sample_type'), 'Biological paradigm (for example: germline, somatic, liquid_biopsy).')
    append_kv(lines, 4, 'sequencing_type', rec.get('sequencing_type'), 'Assay modality used for Stage 3 routing (WES/WGS/PANEL).')
    append_kv(lines, 4, 'reported_sex', rec.get('reported_sex'), 'Declared sex used for chrX/chrY concordance validation.')
    append_kv(lines, 4, 'pathologist_tumor_burden', rec.get('pathologist_tumor_burden'), 'Pathologist estimated tumor burden carried into purity validation.')
    append_kv(lines, 4, 'physician_tumor_purity', rec.get('physician_tumor_purity'), 'Physician-provided purity estimate compared against in-silico estimate.')
    append_map(lines, 4, 'consent', rec.get('consent', {}), {})
    append_map(lines, 4, 'consent_tokens', rec.get('consent_tokens', {}), {})
    append_map(lines, 4, 'variant_branches', rec.get('variant_branches', {}), {
        'snv_indel': 'Enable short-variant discovery branch for SNVs and indels.',
        'structural_variants': 'Enable structural-variant discovery branch.',
        'copy_number_cnv': 'Enable copy-number and CNV discovery branch.',
        'str_expansions': 'Enable short tandem repeat expansion discovery branch.',
        'trisomy_aneuploidy': 'Enable aneuploidy/trisomy discovery branch.'
    })
    append_map(lines, 4, 'biological_context', rec.get('biological_context', {}), {})
    append_map(lines, 4, 'diagnosis', rec.get('diagnosis', {}), {})
    append_map(lines, 4, 'specimen', rec.get('specimen', {}), {})
    append_map(lines, 4, 'clinical_context', rec.get('clinical_context', {}), {})
    append_map(lines, 4, 'sequencer', rec.get('sequencer', {}), {})
    append_kv(lines, 4, 'intake_validation_token', rec.get('intake_validation_token'), 'Original Stage 0/1 intake token provenance pointer.')
    append_kv(lines, 4, 'validation_token', rec.get('validation_token'), 'Canonical Stage 2 validation token required by Stage 3 preconditions.')
    append_kv(lines, 4, 'intake_validation_report', rec.get('intake_validation_report'), 'Stage 0 intake validation report path for audit replay.')
    append_kv(lines, 4, 'intake_route_decision', rec.get('intake_route_decision'), 'Stage 0 route decision JSON path for lineage.')
    append_kv(lines, 4, 'stage0_audit_bundle', rec.get('stage0_audit_bundle'), 'Stage 0 full audit bundle archive path.')
    append_kv(lines, 4, 'identity_audit', rec.get('identity_audit'), 'Stage 1 identity/contamination audit path.')
    append_kv(lines, 4, 'sorted_bam', rec.get('sorted_bam'), 'Stage 1 validated sorted BAM consumed by Stage 3 callers.')
    append_kv(lines, 4, 'sorted_bai', rec.get('sorted_bai'), 'Index paired with sorted_bam.')
    append_kv(lines, 4, 'snv_mask_bed', rec.get('snv_mask_bed'), 'BED mask/target routed for SNV calling branches.')
    append_kv(lines, 4, 'cnv_target_bed', rec.get('cnv_target_bed'), 'BED target routed for CNV/copy-ratio analysis branches.')
    append_kv(lines, 4, 'sv_calling_enabled', rec.get('sv_calling_enabled'), 'Boolean routing flag enabling structural-variant calling branch.')
    append_kv(lines, 4, 'stage2_router_token', rec.get('stage2_router_token'), 'Deterministic assay routing token consumed by Stage 3 subworkflow branching.')
    append_kv(lines, 4, 'stage2_precondition_audit', rec.get('stage2_precondition_audit'), 'Stage 2 precondition audit JSON path.')
    append_kv(lines, 4, 'purity_and_sex_validation_audit', rec.get('purity_and_sex_validation_audit'), 'Combined purity + sex validation audit JSON path.')
    append_kv(lines, 4, 'assay_target_router_audit', rec.get('assay_target_router_audit'), 'Assay target router audit JSON path.')
    append_map(lines, 4, 'reference_build', rec.get('reference_build', {}), reference_comments)
    append_kv(lines, 4, 'save_dir', rec.get('save_dir'), 'Stage 2 banking root directory.')

Path('samples_hg002_banked_stage2.yaml').write_text('\\n'.join(lines) + '\\n', encoding='utf-8')
PYEOF
    """
}
