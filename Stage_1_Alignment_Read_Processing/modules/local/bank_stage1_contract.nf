process BANK_STAGE1_CONTRACT {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/aligned", mode: 'rellink', overwrite: true, pattern: '*.bam'
    publishDir "${params.outdir}/aligned", mode: 'rellink', overwrite: true, pattern: '*.bai'

    input:
    tuple val(meta), path(identity_audit), path(bam), path(bai)
    val reference_meta

    output:
    path "${meta.sample_id}.banked_stage1.fragment.json", emit: manifest_fragment

    script:
    def sid = meta.sample_id
    def patientId = (meta.patient_id ?: sid).toString()
    def caseId = (meta.case_id ?: patientId).toString()
    def accessionId = (meta.accession_id ?: '').toString()
    def encounterId = (meta.encounter_id ?: '').toString()
    def specimenId = (meta.specimen_id ?: '').toString()
    def analysisBatchId = (meta.analysis_batch_id ?: '').toString()
    def sampleType = (meta.sample_type ?: 'germline').toString()
    def gender = (meta.gender ?: 'unknown').toString()
    def platform = (meta.sequencer?.platform ?: 'unknown').toString()
    def model = (meta.sequencer?.model ?: 'unknown').toString()
    def geometry = (meta.sequencer?.flowcell_geometry ?: 'unknown').toString()
    def consentJson = groovy.json.JsonOutput.toJson(meta.consent ?: [:]).replace('\n', ' ').replace('\r', '')
    def consentTokensJson = groovy.json.JsonOutput.toJson(meta.consent_tokens ?: [:]).replace('\n', ' ').replace('\r', '')
    def variantBranchesJson = groovy.json.JsonOutput.toJson(meta.variant_branches ?: [:]).replace('\n', ' ').replace('\r', '')
    def biologicalContextJson = groovy.json.JsonOutput.toJson(meta.biological_context ?: [:]).replace('\n', ' ').replace('\r', '')
    def diagnosisJson = groovy.json.JsonOutput.toJson(meta.diagnosis ?: [:]).replace('\n', ' ').replace('\r', '')
    def specimenJson = groovy.json.JsonOutput.toJson(meta.specimen ?: [:]).replace('\n', ' ').replace('\r', '')
    def clinicalContextJson = groovy.json.JsonOutput.toJson(meta.clinical_context ?: [:]).replace('\n', ' ').replace('\r', '')
    def refJson = groovy.json.JsonOutput.toJson(reference_meta).replace('\n', ' ').replace('\r', '')
    def branchTargetCatalogJson = groovy.json.JsonOutput.toJson(meta.branch_target_catalog ?: '').replace('\n', ' ').replace('\r', '')
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json

ref = json.loads('''${refJson}''')
sid = '${sid}'
base = '${params.outdir}'
fragment = {
    'sample_id': sid,
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
    'variant_branches': json.loads('''${variantBranchesJson}'''),
    'biological_context': json.loads('''${biologicalContextJson}'''),
    'diagnosis': json.loads('''${diagnosisJson}'''),
    'specimen': json.loads('''${specimenJson}'''),
    'clinical_context': json.loads('''${clinicalContextJson}'''),
    'sequencer': {
        'platform': '${platform}',
        'model': '${model}',
        'flowcell_geometry': '${geometry}'
    },
    'branch_target_catalog': json.loads('''${branchTargetCatalogJson}'''),
    'stage0_audit_bundle': '${meta.stage0_audit_bundle ?: ''}',
    'intake_validation_token': '${meta.intake_validation_token ?: ''}',
    'intake_validation_report': '${meta.intake_validation_report ?: ''}',
    'intake_route_decision': '${meta.intake_route_decision ?: ''}',
    'preflight_lock': '${meta.preflight_lock ?: ''}',
    'preflight_lock_status': '${meta.preflight_lock_status ?: ''}',
    'reference_snapshot_tokens': '${meta.reference_snapshot_tokens ?: ''}',
    'mapped_bam': f"{base}/aligned/{sid}.identity_verified.bam",
    'mapped_bai': f"{base}/aligned/{sid}.identity_verified.bam.bai",
    'identity_audit': f"{base}/audit_and_qc/stage1/{sid}.identity_audit.json",
    'reference_build': ref,
    'save_dir': base
}
with open(f"{sid}.banked_stage1.fragment.json", 'w', encoding='utf-8') as out:
    json.dump(fragment, out, indent=2)
PYEOF
    """
}
