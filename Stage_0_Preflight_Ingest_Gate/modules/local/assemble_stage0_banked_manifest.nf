process ASSEMBLE_STAGE0_BANKED_MANIFEST {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    publishDir "${params.outdir}", mode: 'copy', overwrite: true, saveAs: { _name -> params.banked_samplesheet_name.toString() }

    input:
    path fragment_jsons

    output:
    path 'banked_stage0.yaml', emit: banked_samplesheet

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path

def quote_scalar(value):
    if value is None:
        return 'null'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, (int, float)):
        return json.dumps(value)
    return json.dumps(str(value))


def append_kv(lines, indent, key, value, comment):
    pad = ' ' * indent
    lines.append(f"{pad}{key}: {quote_scalar(value)}  # {comment}")


def append_section_comment(lines, indent, text):
    pad = ' ' * indent
    lines.append(f"{pad}# {text}")


def append_map(lines, indent, name, mapping, comments):
    pad = ' ' * indent
    lines.append(f"{pad}{name}:")
    if mapping:
        for key, value in mapping.items():
            comment = comments.get(key, 'Additional metadata preserved from the upstream manifest.')
            append_kv(lines, indent + 2, key, value, comment)
    else:
        lines.append(f"{pad}  {{}}  # Upstream manifest did not provide this optional metadata section.")

records = []
for path in sorted(Path('.').glob('*.json')):
    with path.open('r', encoding='utf-8') as handle:
        records.append(json.load(handle))

records.sort(key=lambda item: item['sample_id'])

lines = [
    '# ==============================================================================',
    '# STAGE 0 BANKED MANIFEST',
    '# Purpose: Immutable Stage 0 handoff after intake validation, consent routing,',
    '#          reference snapshot locking, and audit bundle creation.',
    '# Regulatory note: This file is intended to be human-auditable. Each field is',
    '#                  annotated inline so clinicians and external reviewers can',
    '#                  inspect provenance without cross-referencing source code.',
    '# ==============================================================================',
    'samples:'
]

consent_comments = {
    'prs_opt_in': 'True permits downstream polygenic risk scoring branches.',
    'sf_opt_in': 'True permits ACMG secondary findings analysis and reporting.',
    'research_opt_in': 'Optional research-only use permission captured at intake.',
    'data_sharing_opt_in': 'Optional controlled data sharing permission for approved repositories.',
    'recontact_opt_in': 'Optional permission allowing future clinically relevant recontact.',
    'consent_version': 'Human-readable consent form or policy revision identifier.',
    'consent_signed_utc': 'Timestamp when consent was signed, in ISO 8601 UTC form.',
    'consent_source': 'System or workflow source from which consent values were ingested.'
}

consent_token_comments = {
    'prs_reporting': 'Deterministic route token used to gate PRS-producing downstream tasks.',
    'secondary_findings': 'Deterministic route token used to gate secondary-findings tasks.',
    'research_use': 'Deterministic route token for research-only derivative workflows.',
    'data_sharing': 'Deterministic route token for any controlled federation/export path.',
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

ingest_manifest_comments = {
    'expected_fastq_md5': 'Expected MD5 block used for intake parity checks.',
    'observed_q30_fraction': 'Precomputed Q30 fraction used by intake quality gating when supplied.',
    'declared_sex': 'Sex value used by the intake concordance precheck.',
    'chromosome_y_depth': 'Observed ChrY depth proxy used during sex concordance checks.',
    'x_inbreeding_coefficient': 'Observed X-chromosome inbreeding coefficient used during intake checks.',
    'strict_pair_count_check': 'When true, Stage 0 counts FASTQ records and enforces R1/R2 parity.'
}

sequencer_comments = {
    'platform': 'Permitted short-read platform enum: illumina, element, complete_genomics, or ultima.',
    'model': 'Instrument or chemistry model string from LIMS.',
    'flowcell_geometry': 'Run geometry enum such as native or DNBSEQ_PATTERNED.'
}

for record in records:
    lines.append('  # ---------------------------------------------------------------------------')
    lines.append('  # Stage 0 banked record. All paths below are immutable outputs from the run')
    lines.append('  # that validated this sample at intake.')
    lines.append(f"  - sample_id: {quote_scalar(record['sample_id'])}  # Stable sample identifier propagated across all stages.")
    append_kv(lines, 4, 'patient_id', record.get('patient_id'), 'Clinical or LIMS patient identifier; may equal sample_id for controls.')
    append_kv(lines, 4, 'case_id', record.get('case_id'), 'Case, family, or accession-group identifier used for multi-sample context.')
    append_kv(lines, 4, 'accession_id', record.get('accession_id'), 'Laboratory accession identifier assigned at order intake.')
    append_kv(lines, 4, 'encounter_id', record.get('encounter_id'), 'Clinical encounter or visit identifier tied to the order.')
    append_kv(lines, 4, 'specimen_id', record.get('specimen_id'), 'Physical specimen identifier from accessioning or biobank custody.')
    append_kv(lines, 4, 'analysis_batch_id', record.get('analysis_batch_id'), 'Batch or run-set identifier used for operational grouping.')
    append_kv(lines, 4, 'sample_type', record.get('sample_type'), 'Primary biological context enum such as germline or somatic.')
    append_kv(lines, 4, 'run_mode', record.get('run_mode', 'production'), 'Sample-sheet governed run mode; production stays fail-closed while audit/dev can continue.')
    append_kv(lines, 4, 'pathologist_tumor_burden', record.get('pathologist_tumor_burden', 0.0), 'Tumor burden fraction on a 0-1 scale; 0.0 is expected for germline controls.')
    append_kv(lines, 4, 'gender', record.get('gender'), 'Declared sex/gender field required by the Stage 0 sex concordance gate.')

    append_section_comment(lines, 4, 'Locked consent declarations copied from the source manifest.')
    append_map(lines, 4, 'consent', record.get('consent', {}), consent_comments)
    append_section_comment(lines, 4, 'Derived route tokens used by downstream optional clinical branches.')
    append_map(lines, 4, 'consent_tokens', record.get('consent_tokens', {}), consent_token_comments)

    append_section_comment(lines, 4, 'Stage 0 variant branch toggles carried forward into Stage 2 and Stage 3 routing.')
    append_map(lines, 4, 'variant_branches', record.get('variant_branches', {}), {
        'snv_indel': 'Enable short-variant discovery branch for SNVs and indels.',
        'structural_variants': 'Enable structural-variant discovery branch.',
        'copy_number_cnv': 'Enable copy-number and CNV discovery branch.',
        'str_expansions': 'Enable short tandem repeat expansion discovery branch.',
        'trisomy_aneuploidy': 'Enable aneuploidy/trisomy discovery branch.'
    })

    append_section_comment(lines, 4, 'Optional upstream biological descriptors preserved for interpretation context.')
    append_map(lines, 4, 'biological_context', record.get('biological_context', {}), biological_comments)
    append_section_comment(lines, 4, 'Optional diagnosis block preserved exactly from the intake contract.')
    append_map(lines, 4, 'diagnosis', record.get('diagnosis', {}), diagnosis_comments)
    append_section_comment(lines, 4, 'Optional specimen descriptors preserved for laboratory provenance.')
    append_map(lines, 4, 'specimen', record.get('specimen', {}), specimen_comments)
    append_section_comment(lines, 4, 'Optional clinical context preserved for downstream interpretation and reporting.')
    append_map(lines, 4, 'clinical_context', record.get('clinical_context', {}), clinical_comments)
    append_section_comment(lines, 4, 'Raw intake QC hints and integrity expectations captured from the source manifest.')
    append_map(lines, 4, 'ingest_manifest', record.get('ingest_manifest', {}), ingest_manifest_comments)

    append_section_comment(lines, 4, 'Instrument metadata used for platform-specific gating in later stages.')
    append_map(lines, 4, 'sequencer', record.get('sequencer', {}), sequencer_comments)

    append_kv(lines, 4, 'fastq_forward', record.get('fastq_forward'), 'Validated Stage 0 forward-read FASTQ path; downstream stages must consume this, not raw ingress data.')
    append_kv(lines, 4, 'fastq_reverse', record.get('fastq_reverse'), 'Validated Stage 0 reverse-read FASTQ path paired with fastq_forward.')
    append_kv(lines, 4, 'intake_validation_token', record.get('intake_validation_token'), 'Machine-readable Stage 0 pass token required by Stage 1 preconditions.')
    append_kv(lines, 4, 'preflight_lock', record.get('preflight_lock'), 'Atomic intake lock token proving the manifest and control-plane YAMLs were hashed together.')
    append_kv(lines, 4, 'preflight_lock_status', record.get('preflight_lock_status'), 'Status code emitted by PREFLIGHT_INGESTION_GUARD for this run-level intake seal.')
    append_kv(lines, 4, 'reference_snapshot_tokens', record.get('reference_snapshot_tokens'), 'Compatibility copy of the preflight lock retained for older audit consumers.')
    append_kv(lines, 4, 'stage0_audit_bundle', record.get('stage0_audit_bundle'), 'Compressed audit bundle containing validation, routing, and reference-lock artifacts.')
    append_kv(lines, 4, 'intake_validation_report', record.get('intake_validation_report'), 'Detailed JSON audit for Stage 0 intake validation decisions.')
    append_kv(lines, 4, 'intake_route_decision', record.get('intake_route_decision'), 'JSON record showing deterministic Stage 0 routing after token evaluation.')
    append_kv(lines, 4, 'save_dir', record.get('save_dir'), 'Root banking directory in which Stage 0 published all sample-scoped outputs.')

Path('banked_stage0.yaml').write_text('\n'.join(lines) + '\n', encoding='utf-8')
PYEOF
    """
}