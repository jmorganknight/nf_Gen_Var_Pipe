process ASSEMBLE_STAGE1_BANKED_MANIFEST {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    publishDir "${params.outdir}", mode: 'copy', overwrite: true

    input:
    path fragments

    output:
    path 'samples_hg002_banked_stage1.yaml', emit: banked_manifest

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
            append_kv(lines, indent + 2, key, value, comments.get(key, 'Additional metadata preserved from upstream stages.'))
    else:
        lines.append(f"{pad}  {{}}  # Upstream stages did not provide this optional metadata section.")

records = []
for frag in sorted(Path('.').glob('*.json')):
    records.append(json.loads(frag.read_text(encoding='utf-8')))
records.sort(key=lambda x: x['sample_id'])

lines = [
    '# ==============================================================================',
    '# STAGE 1 BANKED MANIFEST',
    '# Purpose: Immutable aligned-read handoff for downstream variant discovery and',
    '#          reporting stages after platform routing, alignment, identity checks,',
    '#          and Stage 0 token validation.',
    '# Regulatory note: Consent routing, clinical context, and reference provenance',
    '#                  remain attached to each record for auditor review.',
    '# ==============================================================================',
    'samples:'
]

consent_comments = {
    'prs_opt_in': 'True permits downstream polygenic risk scoring branches.',
    'sf_opt_in': 'True permits ACMG secondary findings analysis and reporting.',
    'research_opt_in': 'Optional research-only use permission captured at intake.',
    'data_sharing_opt_in': 'Optional permission for approved controlled data sharing.',
    'recontact_opt_in': 'Optional permission allowing future clinically relevant recontact.',
    'consent_version': 'Human-readable consent form or policy revision identifier.',
    'consent_signed_utc': 'Timestamp when consent was signed, in ISO 8601 UTC form.',
    'consent_source': 'System or workflow source from which consent values were ingested.'
}

consent_token_comments = {
    'prs_reporting': 'Deterministic route token used to gate PRS-producing downstream tasks.',
    'secondary_findings': 'Deterministic route token used to gate secondary-findings tasks.',
    'research_use': 'Deterministic route token for research-only derivative workflows.',
    'data_sharing': 'Deterministic route token for controlled federation or export paths.',
    'recontact': 'Deterministic route token indicating whether future recontact is permitted.'
}

biological_comments = {
    'declared_sex': 'Declared biological sex or karyotypic label used for concordance checks.',
    'reported_ancestry': 'Self-reported ancestry or population descriptor supplied by the ordering context.',
    'phenotype_terms': 'Phenotype labels or ontology terms relevant to interpretation.',
    'affected_status': 'Affected or unaffected disease status for germline interpretation context.'
}

diagnosis_comments = {
    'disease': 'Primary disease label or syndrome name relevant to the order.',
    'primary_site': 'Tumor or disease site used for interpretation context.',
    'indication': 'Clinical reason for ordering the assay.',
    'icd10': 'ICD-10 code captured from the ordering system.',
    'stage': 'Disease stage or progression label, if clinically applicable.'
}

specimen_comments = {
    'specimen_type': 'Material class such as blood, saliva, FFPE, fresh tissue, or plasma.',
    'tissue_site': 'Anatomic origin of the specimen, if relevant.',
    'collection_timestamp_utc': 'Specimen collection timestamp in ISO 8601 UTC form.',
    'accessioning_lab': 'Laboratory or accessioning service responsible for intake custody.',
    'tumor_purity_estimate': 'Optional upstream purity estimate; fraction is expressed on a 0-1 scale.'
}

clinical_comments = {
    'mrn': 'Medical record number or equivalent hospital identifier.',
    'ordering_clinician': 'Ordering clinician name or responsible provider identifier.',
    'report_priority': 'Operational priority such as routine, expedited, or STAT.',
    'family_history': 'Free-text or coded family history summary relevant to interpretation.'
}

sequencer_comments = {
    'platform': 'Permitted short-read platform enum: illumina, element, complete_genomics, or ultima.',
    'model': 'Instrument or chemistry model string from LIMS.',
    'flowcell_geometry': 'Run geometry enum such as native or DNBSEQ_PATTERNED.'
}

reference_comments = {
    'reference_genome': 'Reference FASTA used during alignment and downstream variant normalization.',
    'reference_fai': 'FASTA index paired with reference_genome for coordinate lookup.',
    'reference_dict': 'Sequence dictionary used to validate BAM/CRAM header compatibility.',
    'bwa_index_base': 'BWA-MEM2 index basename or prefix used for alignment.',
    'onco_target_bed': 'Primary target BED used for assay-specific coverage and reporting contexts.',
    'sf_bed': 'Secondary findings BED used by opt-in optional reporting logic.',
    'clinvar_db': 'ClinVar or equivalent interpretation resource pinned for this run.'
}

for rec in records:
    lines.append('  # ---------------------------------------------------------------------------')
    lines.append('  # Stage 1 banked record. These fields define the aligned handoff contract for')
    lines.append('  # downstream variant calling and clinical reporting stages.')
    lines.append(f"  - sample_id: {q(rec['sample_id'])}  # Stable sample identifier propagated across all downstream stages.")
    append_kv(lines, 4, 'patient_id', rec.get('patient_id'), 'Clinical or LIMS patient identifier; may equal sample_id for controls.')
    append_kv(lines, 4, 'case_id', rec.get('case_id'), 'Case, family, or accession-group identifier used for multi-sample context.')
    append_kv(lines, 4, 'accession_id', rec.get('accession_id'), 'Laboratory accession identifier assigned at order intake.')
    append_kv(lines, 4, 'encounter_id', rec.get('encounter_id'), 'Clinical encounter or visit identifier tied to the order.')
    append_kv(lines, 4, 'specimen_id', rec.get('specimen_id'), 'Physical specimen identifier from accessioning or biobank custody.')
    append_kv(lines, 4, 'analysis_batch_id', rec.get('analysis_batch_id'), 'Batch or run-set identifier used for operational grouping.')
    append_kv(lines, 4, 'sample_type', rec.get('sample_type'), 'Primary biological context enum such as germline or somatic.')
    append_kv(lines, 4, 'pathologist_tumor_burden', rec.get('pathologist_tumor_burden', 0.0), 'Tumor burden fraction on a 0-1 scale; preserved for downstream callers and review.')
    append_kv(lines, 4, 'gender', rec.get('gender'), 'Declared sex/gender field carried forward from the intake contract.')
    append_map(lines, 4, 'consent', rec.get('consent', {}), consent_comments)
    append_map(lines, 4, 'consent_tokens', rec.get('consent_tokens', {}), consent_token_comments)
    append_map(lines, 4, 'variant_branches', rec.get('variant_branches', {}), {
        'snv_indel': 'Enable short-variant discovery branch for SNVs and indels.',
        'structural_variants': 'Enable structural-variant discovery branch.',
        'copy_number_cnv': 'Enable copy-number and CNV discovery branch.',
        'str_expansions': 'Enable short tandem repeat expansion discovery branch.',
        'trisomy_aneuploidy': 'Enable aneuploidy/trisomy discovery branch.',
        'homologous_pseudogenes': 'Enable homologous/pseudogene caller branch.'
    })
    append_kv(lines, 4, 'branch_target_catalog', rec.get('branch_target_catalog'), 'Optional branch target catalog required when branch toggles need an assay target file.')
    append_map(lines, 4, 'biological_context', rec.get('biological_context', {}), biological_comments)
    append_map(lines, 4, 'diagnosis', rec.get('diagnosis', {}), diagnosis_comments)
    append_map(lines, 4, 'specimen', rec.get('specimen', {}), specimen_comments)
    append_map(lines, 4, 'clinical_context', rec.get('clinical_context', {}), clinical_comments)
    append_map(lines, 4, 'sequencer', rec.get('sequencer', {}), sequencer_comments)
    append_kv(lines, 4, 'intake_validation_token', rec.get('intake_validation_token'), 'Stage 0 validation token retained for provenance and audit replay.')
    append_kv(lines, 4, 'intake_validation_report', rec.get('intake_validation_report'), 'Stage 0 intake audit JSON retained for cross-stage provenance.')
    append_kv(lines, 4, 'intake_route_decision', rec.get('intake_route_decision'), 'Stage 0 deterministic route decision JSON retained for lineage.')
    append_kv(lines, 4, 'preflight_lock', rec.get('preflight_lock'), 'Atomic intake lock token proving the manifest and control-plane YAMLs were sealed before Stage 1 execution.')
    append_kv(lines, 4, 'preflight_lock_status', rec.get('preflight_lock_status'), 'Run-level preflight status propagated from PREFLIGHT_INGESTION_GUARD.')
    append_kv(lines, 4, 'reference_snapshot_tokens', rec.get('reference_snapshot_tokens'), 'Compatibility copy of the preflight lock retained for older audit consumers.')
    append_kv(lines, 4, 'stage0_audit_bundle', rec.get('stage0_audit_bundle'), 'Compressed Stage 0 audit bundle retained so downstream review can reconstruct intake evidence.')
    append_kv(lines, 4, 'mapped_bam', rec.get('mapped_bam'), 'Identity-gated aligned BAM emitted by Stage 1 and required by Stage 2.')
    append_kv(lines, 4, 'mapped_bai', rec.get('mapped_bai'), 'BAM index paired with mapped_bam.')
    append_kv(lines, 4, 'identity_audit', rec.get('identity_audit'), 'VerifyBamID2 or equivalent identity/contamination audit for this aligned sample.')
    append_map(lines, 4, 'reference_build', rec.get('reference_build', {}), reference_comments)
    append_kv(lines, 4, 'save_dir', rec.get('save_dir'), 'Root banking directory in which Stage 1 published all aligned outputs.')

Path('samples_hg002_banked_stage1.yaml').write_text('\\n'.join(lines) + '\\n', encoding='utf-8')
PYEOF
    """
}
