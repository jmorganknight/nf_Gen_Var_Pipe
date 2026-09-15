process BANK_STAGE0_SUCCESS {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/validated_fastqs", mode: 'rellink', overwrite: true, pattern: '*_R*.validated.fastq.gz'
    publishDir "${params.outdir}/audit_and_qc", mode: 'copy', overwrite: true, pattern: '*.intake_validation_token'
    publishDir "${params.outdir}/audit_and_qc", mode: 'copy', overwrite: true, pattern: '*.stage0.audit_bundle.tar.gz'

    input:
    tuple val(meta),
          path(validated_r1),
          path(validated_r2),
          path(intake_token_file),
          path(intake_report),
          path(route_audit)
        path preflight_lock
    path snapshot_tokens
    path yaml_bundle
    path infrastructure_yaml

    output:
    tuple val(meta), path("${meta.sample_id}_R1.validated.fastq.gz"), path("${meta.sample_id}_R2.validated.fastq.gz"), emit: validated_fastqs
    tuple val(meta), path("${meta.sample_id}.intake_validation_token"), emit: intake_token
    tuple val(meta), path("${meta.sample_id}.stage0.audit_bundle.tar.gz"), emit: audit_bundle
    path "${meta.sample_id}.banked_stage0.fragment.json", emit: manifest_fragment

    script:
    def sid = meta.sample_id
    def patientId = (meta.patient_id ?: sid).toString()
    def caseId = (meta.case_id ?: patientId).toString()
    def accessionId = (meta.accession_id ?: '').toString()
    def encounterId = (meta.encounter_id ?: '').toString()
    def specimenId = (meta.specimen_id ?: '').toString()
    def analysisBatchId = (meta.analysis_batch_id ?: '').toString()
    def sampleType = meta.sample_type ?: 'unknown'
    def gender = meta.gender ?: 'unknown'
    def consentJson = groovy.json.JsonOutput.toJson(meta.consent ?: [:]).replace('\n', ' ').replace('\r', '')
    def consentTokensJson = groovy.json.JsonOutput.toJson(meta.consent_tokens ?: [:]).replace('\n', ' ').replace('\r', '')
    def biologicalContextJson = groovy.json.JsonOutput.toJson(meta.biological_context ?: [:]).replace('\n', ' ').replace('\r', '')
    def diagnosisJson = groovy.json.JsonOutput.toJson(meta.diagnosis ?: [:]).replace('\n', ' ').replace('\r', '')
    def specimenJson = groovy.json.JsonOutput.toJson(meta.specimen ?: [:]).replace('\n', ' ').replace('\r', '')
    def clinicalContextJson = groovy.json.JsonOutput.toJson(meta.clinical_context ?: [:]).replace('\n', ' ').replace('\r', '')
    def ingestManifestJson = groovy.json.JsonOutput.toJson(meta.ingest_manifest ?: [:]).replace('\n', ' ').replace('\r', '')
    def sequencerJson = groovy.json.JsonOutput.toJson(meta.sequencer ?: [:]).replace('\n', ' ').replace('\r', '')
    def variantBranchesJson = groovy.json.JsonOutput.toJson(meta.variant_branches ?: [:]).replace('\n', ' ').replace('\r', '')
    """
    set -euo pipefail

    cp "${intake_token_file}" "${sid}.intake_validation_token"
    tar -czf "${sid}.stage0.audit_bundle.tar.gz" \
        "${intake_report}" \
        "${route_audit}" \
        "${preflight_lock}" \
        "${snapshot_tokens}" \
        "${yaml_bundle}" \
        "${infrastructure_yaml}"

    python3 - <<'PYEOF'
import json

fragment = {
    'sample_id': '${sid}',
    'run_mode': '${meta.run_mode ?: 'production'}',
    'patient_id': '${patientId}',
    'case_id': '${caseId}',
    'accession_id': '${accessionId}',
    'encounter_id': '${encounterId}',
    'specimen_id': '${specimenId}',
    'analysis_batch_id': '${analysisBatchId}',
    'sample_type': '${sampleType}',
    'pathologist_tumor_burden': ${meta.pathologist_tumor_burden ?: 0.0},
    'gender': '${gender}',
    'consent': json.loads('''${consentJson}'''),
    'consent_tokens': json.loads('''${consentTokensJson}'''),
    'biological_context': json.loads('''${biologicalContextJson}'''),
    'diagnosis': json.loads('''${diagnosisJson}'''),
    'specimen': json.loads('''${specimenJson}'''),
    'clinical_context': json.loads('''${clinicalContextJson}'''),
    'ingest_manifest': json.loads('''${ingestManifestJson}'''),
    'sequencer': json.loads('''${sequencerJson}'''),
    'variant_branches': json.loads('''${variantBranchesJson}'''),
    'fastq_forward': '${params.outdir}/validated_fastqs/${sid}_R1.validated.fastq.gz',
    'fastq_reverse': '${params.outdir}/validated_fastqs/${sid}_R2.validated.fastq.gz',
    'intake_validation_token': '${params.outdir}/audit_and_qc/${sid}.intake_validation_token',
    'preflight_lock': '${params.outdir}/audit_and_qc/preflight_lock/preflight_lock.json',
    'preflight_lock_status': 'STAGE0_PREFLIGHT_LOCK_PASS',
    'reference_snapshot_tokens': '${params.outdir}/audit_and_qc/preflight_lock/reference_snapshot.tokens',
    'stage0_audit_bundle': '${params.outdir}/audit_and_qc/${sid}.stage0.audit_bundle.tar.gz',
    'intake_validation_report': '${params.outdir}/audit_and_qc/${sid}.intake_validation_report.json',
    'intake_route_decision': '${params.outdir}/audit_and_qc/${sid}.intake_route_decision.json',
    'save_dir': '${params.outdir}'
}

with open('${sid}.banked_stage0.fragment.json', 'w', encoding='utf-8') as handle:
    json.dump(fragment, handle, indent=2)
PYEOF
    """
}