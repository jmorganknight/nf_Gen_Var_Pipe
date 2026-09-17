process STAGE1_CONTRACT {

    label 'process_low'
    container 'genvar-core:2.1.0'
    stageInMode 'copy'

    tag "${meta.sample_id}"

    publishDir "${params.stage1_outdir}/aligned", mode: 'rellink', overwrite: true, pattern: '*.identity_verified.bam'
    publishDir "${params.stage1_outdir}/aligned", mode: 'rellink', overwrite: true, pattern: '*.identity_verified.bam.bai'
    publishDir "${params.stage1_outdir}/aligned", mode: 'copy', overwrite: true, pattern: '*.identity_audit.json'

    input:
    tuple val(meta), path(identity_audit), path(bam), path(bai)
    val reference_meta

    output:
    path "${meta.sample_id}.stage1.fragment.json", emit: manifest_fragment
    path "${meta.sample_id}.identity_verified.bam", emit: published_bam
    path "${meta.sample_id}.identity_verified.bam.bai", emit: published_bai
    path "${meta.sample_id}.identity_audit.json", emit: published_identity_audit

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
    def metaJson = groovy.json.JsonOutput.toJson(meta).replace('\n', ' ').replace('\r', '')
    def branchTargetCatalogJson = groovy.json.JsonOutput.toJson(meta.branch_target_catalog ?: '').replace('\n', ' ').replace('\r', '')
    """
    set -euo pipefail

    if [ "${bam}" != "${sid}.identity_verified.bam" ]; then
        cp -L "${bam}" "${sid}.identity_verified.bam"
    fi
    if [ "${bai}" != "${sid}.identity_verified.bam.bai" ]; then
        cp -L "${bai}" "${sid}.identity_verified.bam.bai"
    fi
    if [ "${identity_audit}" != "${sid}.identity_audit.json" ]; then
        cp -L "${identity_audit}" "${sid}.identity_audit.json"
    fi

    python3 - <<'PYEOF'
import json
from pathlib import Path

ref = json.loads('''${refJson}''')
meta = json.loads('''${metaJson}''')
sid = '${sid}'
base = Path('${params.stage1_outdir}').joinpath('aligned').as_posix()
asset_base_uri = base
fragment = dict(meta)
fragment.update({
    'sample_id': sid,
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
    # Preserve both portable names and stable base URI for downstream re-materialization.
    'asset_base_uri': asset_base_uri,
    'stage1_asset_base_uri': asset_base_uri,
    'mapped_bam': f"{asset_base_uri}/{sid}.identity_verified.bam",
    'mapped_bai': f"{asset_base_uri}/{sid}.identity_verified.bam.bai",
    'mapped_bam_basename': f"{sid}.identity_verified.bam",
    'mapped_bai_basename': f"{sid}.identity_verified.bam.bai",
    'identity_audit': f"{asset_base_uri}/{sid}.identity_audit.json",
    'reference_build': ref,
    'save_dir': str(Path('${params.stage1_outdir}'))
})
with open(f"{sid}.stage1.fragment.json", 'w', encoding='utf-8') as out:
    json.dump(fragment, out, indent=2)
PYEOF
    """
}
