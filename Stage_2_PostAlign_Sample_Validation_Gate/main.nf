nextflow.enable.dsl = 2

include { VALIDATE_STAGE1_PRECONDITION } from './modules/local/validate_stage1_precondition.nf'
include { VALIDATE_CHROMOSOMAL_SEX } from './modules/local/validate_chromosomal_sex.nf'
include { SPECIMEN_PARADIGM_PURITY_RESOLVER } from './modules/local/specimen_paradigm_purity_resolver.nf'
include { ASSAY_TARGET_ROUTER } from './modules/local/assay_target_router.nf'
include { BANK_STAGE2_CONTRACT } from './modules/local/bank_stage2_contract.nf'
include { ASSEMBLE_STAGE2_BANKED_MANIFEST } from './modules/local/assemble_stage2_banked_manifest.nf'

def mapOrEmpty(Object value) {
    value instanceof Map ? (value as Map) : [:]
}

def resolvePath(String rawPath, String rootDir) {
    def candidate = new File(rawPath)
    return candidate.isAbsolute() ? candidate : new File(rootDir, rawPath)
}

def hostPathForReference(String pathText, String refDir) {
    if (!pathText) {
        return null
    }
    def candidate = new File(pathText)
    if (!pathText.startsWith('/opt/reference')) {
        return candidate
    }
    if (!refDir) {
        return null
    }
    def suffix = pathText.replaceFirst('^/opt/reference', '')
    return new File(refDir + suffix)
}

def normalizeSexToken(Object rawSex) {
    def sex = (rawSex ?: '').toString().trim().toUpperCase()
    if (['MALE', 'M', 'XY'].contains(sex)) {
        return 'XY'
    }
    if (['FEMALE', 'F', 'XX'].contains(sex)) {
        return 'XX'
    }
    return 'UNKNOWN'
}

def writeStage2Rejection(String outdir, String sampleId, String reason, String detail, Map extra = [:]) {
    def auditDir = new File("${outdir}/audit_and_qc/stage2")
    auditDir.mkdirs()
    def payload = [
        failure_code: 'STAGE2_PRECONDITION_FAILURE',
        sample_id: sampleId,
        reason: reason,
        detail: detail,
        timestamp_utc: new Date().format("yyyy-MM-dd'T'HH:mm:ssXXX")
    ] + extra
    new File(auditDir, "${sampleId}.stage2_rejection_audit.json").text = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(payload)) + '\n'
}

def buildMetaRow(Map sample, String outdir) {
    def sortedBam = sample.sorted_bam ?: sample.mapped_bam
    def sortedBai = sample.sorted_bai ?: sample.mapped_bai ?: (sortedBam ? "${sortedBam}.bai" : null)
    [
        sample_id: sample.sample_id,
        patient_id: sample.patient_id ?: sample.sample_id,
        case_id: sample.case_id ?: sample.patient_id ?: sample.sample_id,
        accession_id: sample.accession_id,
        encounter_id: sample.encounter_id,
        specimen_id: sample.specimen_id,
        analysis_batch_id: sample.analysis_batch_id,
        sample_type: sample.sample_type ?: 'germline',
        sequencing_type: (sample.sequencing_type ?: sample.assay_type ?: 'WES').toString().toUpperCase(),
        virtual_panel_bed: sample.virtual_panel_bed,
        pathologist_tumor_burden: sample.pathologist_tumor_burden ?: 0.0,
        physician_tumor_purity: sample.physician_tumor_purity ?: sample.pathologist_tumor_burden ?: 0.0,
        gender: sample.gender,
        reported_sex: normalizeSexToken(sample.reported_sex ?: sample.biological_context?.declared_sex ?: sample.gender),
        consent: mapOrEmpty(sample.consent),
        consent_tokens: mapOrEmpty(sample.consent_tokens),
        variant_branches: mapOrEmpty(sample.variant_branches),
        biological_context: mapOrEmpty(sample.biological_context),
        diagnosis: mapOrEmpty(sample.diagnosis),
        specimen: mapOrEmpty(sample.specimen),
        clinical_context: mapOrEmpty(sample.clinical_context),
        sequencer: mapOrEmpty(sample.sequencer),
        intake_validation_token: sample.intake_validation_token,
        intake_validation_report: sample.intake_validation_report,
        intake_route_decision: sample.intake_route_decision,
        stage0_audit_bundle: sample.stage0_audit_bundle,
        identity_audit: sample.identity_audit,
        mapped_bam: sample.mapped_bam,
        mapped_bai: sample.mapped_bai,
        sorted_bam: sortedBam,
        sorted_bai: sortedBai,
        save_dir: outdir
    ]
}

workflow STAGE2_SAMPLE_VALIDATION {

    take:
    ch_stage2_input

    main:
    VALIDATE_STAGE1_PRECONDITION(ch_stage2_input)
    VALIDATE_CHROMOSOMAL_SEX(VALIDATE_STAGE1_PRECONDITION.out.validated)
    SPECIMEN_PARADIGM_PURITY_RESOLVER(VALIDATE_CHROMOSOMAL_SEX.out.validated)
    ASSAY_TARGET_ROUTER(SPECIMEN_PARADIGM_PURITY_RESOLVER.out.validated)

    def ch_stage2_for_bank = ASSAY_TARGET_ROUTER.out.validated.map { meta, bam, bai, refs, thresholds, preAudit, purityAudit, routingJson, routerAudit ->
        def routePayload = new groovy.json.JsonSlurper().parseText(routingJson.text) as Map
        def enriched = meta + [
            snv_mask_bed: routePayload.snv_mask_bed,
            cnv_target_bed: routePayload.cnv_target_bed,
            sv_calling_enabled: routePayload.sv_calling_enabled,
            stage2_router_token: routePayload.stage2_router_token,
            variant_branches: routePayload.variant_branches ?: meta.variant_branches,
            stage2_precondition_audit: preAudit.toString(),
            purity_and_sex_validation_audit: purityAudit.toString(),
            assay_target_router_audit: routerAudit.toString()
        ]
        tuple(enriched, bam, bai, refs, thresholds, preAudit, purityAudit, routerAudit)
    }

    BANK_STAGE2_CONTRACT(ch_stage2_for_bank)
    ASSEMBLE_STAGE2_BANKED_MANIFEST(BANK_STAGE2_CONTRACT.out.manifest_fragment.collect())

    emit:
    stage2_contract = ASSEMBLE_STAGE2_BANKED_MANIFEST.out.banked_manifest
}

workflow {
    def ys = new groovy.yaml.YamlSlurper()

    def samplesFilePath = (params.input ?: params.samples)?.toString()
    if (!samplesFilePath) {
        throw new IllegalArgumentException('STAGE2_PRECONDITION_FAILURE: missing --input Stage 1 banked manifest')
    }
    def samplesFile = file(samplesFilePath)
    if (!samplesFile.exists()) {
        throw new IllegalArgumentException("STAGE2_PRECONDITION_FAILURE: input manifest does not exist: ${samplesFilePath}")
    }
    if (!samplesFile.name.contains('banked_stage1')) {
        throw new IllegalArgumentException("STAGE2_PRECONDITION_FAILURE: expected a Stage 1 banked manifest, got '${samplesFile.name}'")
    }

    def referencesFile = file(params.references)
    def thresholdsFile = file(params.thresholds)

    def samplesParsed = ys.parse(samplesFile).samples
    def refsParsed = ys.parse(referencesFile).references
    def thresholdsParsed = ys.parse(thresholdsFile)

    if (!(samplesParsed instanceof List) || samplesParsed.isEmpty()) {
        throw new IllegalArgumentException('STAGE2_PRECONDITION_FAILURE: samples manifest contains no samples')
    }

    def refsNormalized = mapOrEmpty(refsParsed) + [
        capture_wes_bed: refsParsed.capture_wes_bed ?: refsParsed.onco_target_bed,
        onco_target_bed: refsParsed.onco_target_bed ?: refsParsed.capture_wes_bed
    ]
    def refDir = params.ref_dir?.toString()
    [
        reference_genome: (refsParsed.reference_genome ?: refsParsed.grch38_fasta),
        reference_fai   : (refsParsed.reference_fai ?: refsParsed.grch38_fai),
        reference_dict  : (refsParsed.reference_dict ?: refsParsed.grch38_dict),
        onco_target_bed : refsNormalized.onco_target_bed,
        capture_wes_bed : refsNormalized.capture_wes_bed,
        sf_bed          : refsParsed.sf_bed
    ].each { key, value ->
        if (!value) {
            writeStage2Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', key)
            throw new IllegalStateException("STAGE2_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}'")
        }
        def resolved = hostPathForReference(value.toString(), refDir)
        if (resolved == null || !resolved.exists()) {
            writeStage2Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', "${key}=${value}")
            throw new IllegalStateException("STAGE2_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}=${value}'")
        }
    }

    def samplesRoot = samplesFile.parent ? samplesFile.parent.toString() : projectDir.toString()

    def sampleRows = samplesParsed.collect { sample ->
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        def sortedBamRaw = (sample.sorted_bam ?: sample.mapped_bam)?.toString()
        if (!sortedBamRaw) {
            writeStage2Rejection(params.outdir.toString(), sid, 'MISSING_SORTED_BAM', 'sample did not declare sorted_bam or mapped_bam')
            throw new IllegalStateException("STAGE2_PRECONDITION_FAILURE: sorted_bam/mapped_bam missing for sample '${sid}'")
        }
        def sortedBam = resolvePath(sortedBamRaw, samplesRoot)
        def sortedBaiRaw = (sample.sorted_bai ?: sample.mapped_bai ?: "${sortedBamRaw}.bai")?.toString()
        def sortedBai = resolvePath(sortedBaiRaw, samplesRoot)

        if (!sortedBam.exists() || !sortedBai.exists()) {
            writeStage2Rejection(params.outdir.toString(), sid, 'SORTED_BAM_OR_BAI_MISSING', "bam=${sortedBam}; bai=${sortedBai}")
            throw new IllegalStateException("STAGE2_PRECONDITION_FAILURE: sorted BAM/BAI missing for sample '${sid}'")
        }

        def tokenField = sample.intake_validation_token?.toString()
        if (!tokenField) {
            writeStage2Rejection(params.outdir.toString(), sid, 'MISSING_INTAKE_VALIDATION_TOKEN', 'intake_validation_token missing from Stage 1 contract')
            throw new IllegalStateException("STAGE2_PRECONDITION_FAILURE: intake_validation_token missing for sample '${sid}'")
        }

        def tokenPath = resolvePath(tokenField, samplesRoot)
        def token = tokenPath.exists() ? tokenPath.text.trim() : tokenField.trim()
        if (!token.contains('VALID_PASS|INTAKE_VALIDATED')) {
            writeStage2Rejection(params.outdir.toString(), sid, 'INVALID_STAGE1_PRECONDITION_TOKEN', token)
            throw new IllegalStateException("STAGE2_PRECONDITION_FAILURE: invalid intake token for sample '${sid}' -> '${token}'")
        }

        def branchBranches = mapOrEmpty(sample.variant_branches)
        def branchCatalogRequired = (branchBranches.snv_indel ?: false) || (branchBranches.str_expansions ?: false)
        def targetCatalog = (sample.branch_target_catalog ?: refsNormalized.capture_wes_bed ?: refsNormalized.onco_target_bed)?.toString()
        if (branchCatalogRequired && (!targetCatalog || !new File(targetCatalog).exists())) {
            writeStage2Rejection(params.outdir.toString(), sid, 'REJECT_MISSING_BRANCH_CATALOG', targetCatalog ?: 'missing')
            throw new IllegalStateException("STAGE2_PRECONDITION_FAILURE: REJECT_MISSING_BRANCH_CATALOG for sample '${sid}' -> ${targetCatalog ?: 'missing'}")
        }

        def baseMeta = buildMetaRow(sample as Map, params.outdir.toString()) + [
            intake_validation_token_value: token,
            validation_token: token
        ]

        tuple(
            baseMeta,
            file(sortedBam.toString()),
            file(sortedBai.toString()),
            refsNormalized,
            thresholdsParsed
        )
    }

    STAGE2_SAMPLE_VALIDATION(channel.fromList(sampleRows))
}
