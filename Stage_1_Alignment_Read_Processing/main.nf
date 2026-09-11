nextflow.enable.dsl = 2

include { PLATFORM_INIT_ROUTER } from './modules/local/platform_init_router.nf'
include { FASTP_TRIM } from './modules/local/fastp_trim.nf'
include { ELPREP_ALIGN_MARKDUP } from './modules/local/elprep_align_markdup.nf'
include { BWA_MEM2_ALIGN } from './modules/local/bwa_mem2_align.nf'
include { FORCE_CRAM_GRCh38_TAGS } from './modules/local/force_cram_grch38_tags.nf'
include { COORDINATE_STANDARDIZED_CRAM_JUNCTION_HUB } from './modules/local/coordinate_standardized_cram_junction_hub.nf'
include { CROSS_SAMPLE_IDENTITY_GATE } from './modules/local/cross_sample_identity_gate.nf'
include { STAGE1_BWA_FINALIZE } from './modules/local/stage1_bwa_finalize.nf'
include { STAGE1_FLAGSTAT } from './modules/local/stage1_flagstat.nf'
include { STAGE1_AUDIT_SINK } from './modules/local/stage1_audit_sink.nf'
include { BANK_STAGE1_CONTRACT } from './modules/local/bank_stage1_contract.nf'
include { ASSEMBLE_STAGE1_BANKED_MANIFEST } from './modules/local/assemble_stage1_banked_manifest.nf'

def mapOrEmpty(Object value) {
    value instanceof Map ? (value as Map) : [:]
}


def normalizeConsent(Object rawConsent) {
    def source = mapOrEmpty(rawConsent)
    [
        prs_opt_in         : (source.prs_opt_in ?: false),
        sf_opt_in          : (source.sf_opt_in ?: false),
        research_opt_in    : (source.research_opt_in ?: false),
        data_sharing_opt_in: (source.data_sharing_opt_in ?: false),
        recontact_opt_in   : (source.recontact_opt_in ?: false),
        consent_version    : (source.consent_version ?: 'UNSPECIFIED'),
        consent_signed_utc : source.consent_signed_utc,
        consent_source     : (source.consent_source ?: 'DECLARED_IN_SAMPLESHEET')
    ] + source
}


def deriveConsentTokens(Map consent) {
    [
        prs_reporting     : consent.prs_opt_in ? 'CONSENTED|PRS_ENABLED' : 'WITHHELD|PRS_DISABLED',
        secondary_findings: consent.sf_opt_in ? 'CONSENTED|SF_ENABLED' : 'WITHHELD|SF_DISABLED',
        research_use      : consent.research_opt_in ? 'CONSENTED|RESEARCH_ENABLED' : 'WITHHELD|RESEARCH_DISABLED',
        data_sharing      : consent.data_sharing_opt_in ? 'CONSENTED|DATA_SHARING_ENABLED' : 'WITHHELD|DATA_SHARING_DISABLED',
        recontact         : consent.recontact_opt_in ? 'CONSENTED|RECONTACT_ALLOWED' : 'WITHHELD|RECONTACT_PROHIBITED'
    ]
}


def normalizeVariantBranches(Object rawBranches) {
    def source = mapOrEmpty(rawBranches)
    [
        snv_indel          : (source.snv_indel ?: true),
        structural_variants: (source.structural_variants ?: true),
        copy_number_cnv    : (source.copy_number_cnv ?: true),
        str_expansions     : (source.str_expansions ?: false),
        trisomy_aneuploidy : (source.trisomy_aneuploidy ?: true),
        homologous_pseudogenes: (source.homologous_pseudogenes ?: false)
    ] + source
}


def validateVariantBranchesSchema(Object rawBranches, String sampleId, String outdir) {
    if (rawBranches == null) {
        return
    }
    if (!(rawBranches instanceof Map)) {
        writeStage1Rejection(outdir, sampleId, 'INVALID_VARIANT_BRANCHES_SCHEMA', "variant_branches must be a map, got ${rawBranches.getClass().simpleName}")
        throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: invalid variant_branches schema for sample '${sampleId}'")
    }
}


def writeStage1Rejection(String outdir, String sampleId, String reason, String detail, Map extra = [:]) {
    def auditDir = new File("${outdir}/audit_and_qc/stage1")
    auditDir.mkdirs()
    def payload = [
        failure_code: 'STAGE1_PRECONDITION_FAILURE',
        sample_id: sampleId,
        reason: reason,
        detail: detail,
        timestamp_utc: new Date().format("yyyy-MM-dd'T'HH:mm:ssXXX")
    ] + extra
    new File(auditDir, 'stage1_rejection_audit.json').text = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(payload)) + '\n'
}


def resolvePath(String rawPath, String rootDir) {
    def candidate = new File(rawPath)
    if (candidate.isAbsolute() || candidate.exists()) {
        return candidate
    }
    def primary = new File(rootDir, rawPath)
    if (primary.exists()) {
        return primary
    }
    if (rawPath.startsWith('tests/')) {
        def root = new File(rootDir)
        def fallbackBase = root.parentFile ?: root
        def secondary = new File(fallbackBase, rawPath)
        if (secondary.exists()) {
            return secondary
        }
    }
    return primary
}


def hostPathForReference(String pathText, String refDir) {
    if (!pathText.startsWith('/opt/reference')) {
        return new File(pathText)
    }
    if (!refDir) {
        return null
    }
    def suffix = pathText.replaceFirst('^/opt/reference', '')
    return new File(refDir + suffix)
}


def normalizePlatform(String platform) {
    def p = (platform ?: 'illumina').toString().toLowerCase()
    if (p == 'complete_genomics') {
        return 'complete'
    }
    return p
}


def buildMetaRow(Map sample, String outdir, String branchTargetCatalogDefault = null) {
    def platformRaw = sample.sequencer?.platform ?: 'illumina'
    def platform = normalizePlatform(platformRaw.toString())
    def consent = normalizeConsent(sample.consent)
    [
        sample_id: sample.sample_id,
        patient_id: (sample.patient_id ?: sample.sample_id),
        case_id: (sample.case_id ?: sample.patient_id ?: sample.sample_id),
        accession_id: sample.accession_id,
        encounter_id: sample.encounter_id,
        specimen_id: sample.specimen_id,
        analysis_batch_id: sample.analysis_batch_id,
        sample_type: (sample.sample_type ?: 'germline'),
        pathologist_tumor_burden: sample.pathologist_tumor_burden ?: 0.0,
        gender: (sample.gender ?: 'unknown'),
        consent: consent,
        consent_tokens: mapOrEmpty(sample.consent_tokens) ?: deriveConsentTokens(consent),
        variant_branches: normalizeVariantBranches(sample.variant_branches),
        biological_context: mapOrEmpty(sample.biological_context),
        diagnosis: mapOrEmpty(sample.diagnosis),
        specimen: mapOrEmpty(sample.specimen),
        clinical_context: mapOrEmpty(sample.clinical_context),
        sequencer: (sample.sequencer ?: [:]) + [platform: platform],
        stage0_audit_bundle: sample.stage0_audit_bundle,
        intake_validation_token: sample.intake_validation_token,
        intake_validation_report: sample.intake_validation_report,
        intake_route_decision: sample.intake_route_decision,
        branch_target_catalog: (sample.branch_target_catalog ?: branchTargetCatalogDefault),
        mapped_bam: sample.mapped_bam,
        mapped_bai: sample.mapped_bai,
        save_dir: outdir
    ]
}


workflow STAGE1_ALIGNMENT {

    take:
    ch_platform_payload
    ch_ref_genome
    ch_ref_fai
    ch_bwa_index
    ch_ref_dict
    ch_svd_panel
    ch_freemix_limit
    ch_reference_meta

    main:
    PLATFORM_INIT_ROUTER(ch_platform_payload)

    def ch_routed_reads = PLATFORM_INIT_ROUTER.out.routed_payload.map { meta, fastq1, fastq2, _token, _report ->
        tuple(meta, fastq1, fastq2)
    }

    def lanes = ch_routed_reads.branch { meta, _r1, _r2 ->
        illumina: ['illumina', 'element', 'complete'].contains(normalizePlatform(meta.sequencer?.platform?.toString()))
        ultima: normalizePlatform(meta.sequencer?.platform?.toString()) == 'ultima'
        unsupported: true
    }

    FASTP_TRIM(lanes.illumina)
    ELPREP_ALIGN_MARKDUP(
        FASTP_TRIM.out.reads,
        ch_ref_genome,
        ch_ref_fai,
        ch_bwa_index
    )

    def ch_ultima_reads = lanes.ultima.map { meta, r1, r2 ->
        tuple(meta + [single_end: true, fastp_disable_poly_g: true], r1, r2)
    }
    BWA_MEM2_ALIGN(
        ch_ultima_reads,
        ch_ref_genome,
        ch_ref_fai,
        ch_bwa_index
    )
    STAGE1_BWA_FINALIZE(BWA_MEM2_ALIGN.out.bam)

    def ch_all_bam_bai = ELPREP_ALIGN_MARKDUP.out.bam_bai
        .mix(STAGE1_BWA_FINALIZE.out.bam_bai)

    def ch_force_input = ch_all_bam_bai
        .combine(ch_ref_dict)
        .map { meta, bam, bai, refDict -> tuple(meta, bam, bai, refDict) }

    FORCE_CRAM_GRCh38_TAGS(ch_force_input)
    COORDINATE_STANDARDIZED_CRAM_JUNCTION_HUB(FORCE_CRAM_GRCh38_TAGS.out.normalized_stream)

    def ch_identity_input = COORDINATE_STANDARDIZED_CRAM_JUNCTION_HUB.out.verified_stream
        .combine(ch_svd_panel)
        .combine(ch_freemix_limit)
        .map { meta, bam, bai, svdPanel, freemixLimit -> tuple(meta, bam, bai, svdPanel, freemixLimit) }

    CROSS_SAMPLE_IDENTITY_GATE(ch_identity_input)
    STAGE1_FLAGSTAT(CROSS_SAMPLE_IDENTITY_GATE.out.audited_stream)

    def ch_route_audits = PLATFORM_INIT_ROUTER.out.route_audit.collect()
    def ch_fastp_jsons = FASTP_TRIM.out.json.map { _meta, jsonPath -> jsonPath }.collect()
    def ch_align_metrics = ELPREP_ALIGN_MARKDUP.out.json_metrics.map { _meta, p -> p }
        .mix(STAGE1_BWA_FINALIZE.out.json_metrics.map { _meta, p -> p })
        .collect()
    def ch_identity_audits = CROSS_SAMPLE_IDENTITY_GATE.out.audited_stream.map { _meta, audit, _bam, _bai -> audit }.collect()
    def ch_junction_audits = COORDINATE_STANDARDIZED_CRAM_JUNCTION_HUB.out.audit.collect()
    def ch_flagstats = STAGE1_FLAGSTAT.out.flagstat.collect()

    STAGE1_AUDIT_SINK(
        ch_route_audits,
        ch_fastp_jsons,
        ch_align_metrics,
        ch_flagstats,
        ch_identity_audits,
        ch_junction_audits
    )

    BANK_STAGE1_CONTRACT(CROSS_SAMPLE_IDENTITY_GATE.out.audited_stream, ch_reference_meta)
    ASSEMBLE_STAGE1_BANKED_MANIFEST(BANK_STAGE1_CONTRACT.out.manifest_fragment.collect())

    emit:
    aligned_contract = ASSEMBLE_STAGE1_BANKED_MANIFEST.out.banked_manifest
    stage1_audit_payload = STAGE1_AUDIT_SINK.out.payload
}


workflow {
    def ys = new groovy.yaml.YamlSlurper()

    def samplesFilePath = (params.input ?: params.samples).toString()
    def samplesFile = file(samplesFilePath)
    def referencesFile = file(params.references)
    def thresholdsFile = file(params.thresholds)

    def samplesParsed = ys.parse(samplesFile).samples
    def refsParsed = ys.parse(referencesFile).references
    def thresholdsParsed = ys.parse(thresholdsFile)

    if (!(samplesParsed instanceof List) || samplesParsed.isEmpty()) {
        throw new IllegalArgumentException('STAGE1_PRECONDITION_FAILURE: samples manifest contains no samples')
    }

    def allowedPlatforms = ['illumina', 'element', 'complete', 'complete_genomics', 'ultima'] as Set
    def samplesRoot = samplesFile.parent ? samplesFile.parent.toString() : projectDir.toString()

    samplesParsed.each { sample ->
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        validateVariantBranchesSchema(sample.variant_branches, sid, params.outdir.toString())
        def tokenPathRaw = sample.intake_validation_token?.toString()
        if (!tokenPathRaw) {
            writeStage1Rejection(params.outdir.toString(), sid, 'MISSING_STAGE0_TOKEN', 'samplesheet missing intake_validation_token path')
            throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: missing intake_validation_token for sample '${sid}'")
        }
        def tokenFile = resolvePath(tokenPathRaw, samplesRoot)
        if (!tokenFile.exists()) {
            writeStage1Rejection(params.outdir.toString(), sid, 'TOKEN_PATH_NOT_FOUND', tokenPathRaw)
            throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: token file not found for sample '${sid}'")
        }
        def token = tokenFile.text.trim()
        if (!token.startsWith('VALID_PASS|INTAKE_VALIDATED')) {
            writeStage1Rejection(params.outdir.toString(), sid, 'INVALID_STAGE0_TOKEN', token)
            throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: sample '${sid}' token was '${token}'")
        }

        def platform = (sample.sequencer?.platform ?: 'illumina').toString().toLowerCase()
        if (!allowedPlatforms.contains(platform)) {
            writeStage1Rejection(params.outdir.toString(), sid, 'UNSUPPORTED_PLATFORM', platform)
            throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: unsupported platform '${platform}' for sample '${sid}'")
        }

        def branchBranches = mapOrEmpty(sample.variant_branches)
        def branchCatalogRequired = (branchBranches.snv_indel ?: false) || (branchBranches.str_expansions ?: false)
        def branchCatalogDefault = (refsParsed.capture_wes_bed ?: refsParsed.onco_target_bed)?.toString()
        def branchCatalogPath = (sample.branch_target_catalog ?: branchCatalogDefault)?.toString()
        if (branchCatalogRequired) {
            if (!branchCatalogPath) {
                writeStage1Rejection(params.outdir.toString(), sid, 'REJECT_MISSING_BRANCH_CATALOG', 'branch_target_catalog missing for enabled variant branches')
                throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: branch_target_catalog missing for sample '${sid}'")
            }
            def branchCatalogFile = branchCatalogPath.startsWith('/opt/reference') ? hostPathForReference(branchCatalogPath, params.ref_dir?.toString()) : resolvePath(branchCatalogPath, samplesRoot)
            if (branchCatalogFile == null || !branchCatalogFile.exists() || branchCatalogFile.length() == 0L) {
                writeStage1Rejection(params.outdir.toString(), sid, 'REJECT_MISSING_BRANCH_CATALOG', branchCatalogPath)
                throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: branch_target_catalog missing or empty for sample '${sid}'")
            }
        }

        if (sample.mapped_bam) {
            def mappedBam = resolvePath(sample.mapped_bam.toString(), samplesRoot)
            def mappedBai = sample.mapped_bai ? resolvePath(sample.mapped_bai.toString(), samplesRoot) : new File(mappedBam.toString() + '.bai')
            if (!mappedBam.exists() || !mappedBai.exists()) {
                writeStage1Rejection(params.outdir.toString(), sid, 'MAPPED_INPUT_MISSING', "bam=${mappedBam}; bai=${mappedBai}")
                throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: mapped inputs missing for sample '${sid}'")
            }

            if (mappedBam.length() == 0L) {
                writeStage1Rejection(params.outdir.toString(), sid, 'BAM_HEADER_UNREADABLE', 'empty BAM fixture')
                throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: unable to read BAM header for sample '${sid}'")
            }

            def headerCmd = ['samtools', 'view', '-H', mappedBam.toString()].execute()
            def headerOut = new StringBuffer()
            def headerErr = new StringBuffer()
            headerCmd.waitForProcessOutput(headerOut, headerErr)
            if (headerCmd.exitValue() != 0) {
                writeStage1Rejection(params.outdir.toString(), sid, 'BAM_HEADER_UNREADABLE', headerErr.toString().trim())
                throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: unable to read BAM header for sample '${sid}'")
            }

            def rgLine = headerOut.toString().readLines().find { line -> line.startsWith('@RG') }
            def requiredTags = ['ID:', 'PL:', 'PU:', 'SM:', 'LB:', 'DS:']
            def missingTags = []
            if (!rgLine) {
                missingTags << '@RG'
            } else {
                requiredTags.each { tag -> if (!rgLine.contains(tag)) missingTags << tag }
            }
            if (!missingTags.isEmpty()) {
                writeStage1Rejection(params.outdir.toString(), sid, 'MISSING_READ_GROUP_TAGS', missingTags.join(','))
                throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: BAM @RG tags missing for sample '${sid}'")
            }
        } else {
            def fq1 = resolvePath(sample.fastq_forward.toString(), samplesRoot)
            def fq2 = resolvePath(sample.fastq_reverse.toString(), samplesRoot)
            if (!fq1.exists() || !fq2.exists()) {
                writeStage1Rejection(params.outdir.toString(), sid, 'FASTQ_INPUT_MISSING', "r1=${fq1}; r2=${fq2}")
                throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: FASTQ inputs missing for sample '${sid}'")
            }
        }
    }

    def refGenome = refsParsed.reference_genome ?: refsParsed.grch38_fasta
    def refFai = refsParsed.reference_fai ?: refsParsed.grch38_fai ?: (refGenome ? "${refGenome}.fai" : null)
    def refDict = refsParsed.reference_dict ?: refsParsed.grch38_dict
    def bwaBase = refsParsed.bwa_index_base ?: refsParsed.bwa_index
    def branchTargetCatalogDefault = (refsParsed.capture_wes_bed ?: refsParsed.onco_target_bed)?.toString()
    def elprepIntervals = refsParsed.elprep_intervals ?: refsParsed.onco_target_intervals ?: branchTargetCatalogDefault

    def requiredRefMap = [
        reference_genome: refGenome,
        reference_fai: refFai,
        reference_dict: refDict,
        bwa_index_base: bwaBase,
        onco_target_bed: refsParsed.onco_target_bed,
        capture_wes_bed: refsParsed.capture_wes_bed ?: refsParsed.onco_target_bed,
        sf_bed: refsParsed.sf_bed,
        elprep_intervals: elprepIntervals
    ]
    requiredRefMap.each { key, value ->
        if (!value) {
            writeStage1Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', key)
            throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}'")
        }
    }

    ['reference_genome', 'reference_fai', 'reference_dict', 'onco_target_bed', 'capture_wes_bed', 'sf_bed', 'elprep_intervals'].each { key ->
        def p = requiredRefMap[key].toString()
        def f = hostPathForReference(p, params.ref_dir?.toString())
        if (f == null || !f.exists()) {
            writeStage1Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', "${key}=${p}")
            throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}=${p}'")
        }
    }

    def hostBwaBase = hostPathForReference(bwaBase.toString(), params.ref_dir?.toString())
    if (hostBwaBase == null) {
        writeStage1Rejection(params.outdir.toString(), 'GLOBAL', 'REFERENCE_MOUNT_UNSET', 'references use /opt/reference but --ref_dir is unset')
        throw new IllegalStateException('STAGE1_PRECONDITION_FAILURE: references use /opt/reference but --ref_dir is unset')
    }
    def indexSuffixes = ['.0123', '.amb', '.ann', '.bwt.2bit.64', '.pac']
    indexSuffixes.each { suffix ->
        def idxFile = new File("${hostBwaBase}${suffix}")
        if (!idxFile.exists()) {
            writeStage1Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', idxFile.toString())
            throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${idxFile}'")
        }
    }

    def chPlatformPayload = channel.fromList(samplesParsed.findAll { s -> !s.mapped_bam }).map { sample ->
        def meta = buildMetaRow(sample as Map, params.outdir.toString(), branchTargetCatalogDefault)
        def fq1 = resolvePath(sample.fastq_forward.toString(), samplesRoot)
        def fq2 = resolvePath(sample.fastq_reverse.toString(), samplesRoot)
        def tokenPath = resolvePath(sample.intake_validation_token.toString(), samplesRoot)
        def intakeReport = sample.intake_validation_report ? resolvePath(sample.intake_validation_report.toString(), samplesRoot) : null
        tuple(
            meta,
            file(fq1, checkIfExists: true),
            file(fq2, checkIfExists: true),
            file(tokenPath, checkIfExists: true),
            file(intakeReport, checkIfExists: intakeReport != null)
        )
    }

    def chRefGenome = channel.value(refGenome.toString())
    def chRefFai = channel.value(refFai.toString())
    def chBwaIndex = channel.value(bwaBase.toString())
    def chRefDict = channel.value(refDict.toString())
    def chSvdPanel = channel.value(refsParsed.sf_bed.toString())
    def chFreemix = channel.value(thresholdsParsed.clinical?.contamination?.freemix_germline_limit ?: 0.01)

    def referenceMeta = [
        reference_genome: refGenome.toString(),
        reference_fai: refFai.toString(),
        reference_dict: refDict.toString(),
        bwa_index_base: bwaBase.toString(),
        onco_target_bed: (refsParsed.onco_target_bed ?: refsParsed.capture_wes_bed),
        sf_bed: refsParsed.sf_bed,
        clinvar_db: refsParsed.clinvar_db
    ]
    def chReferenceMeta = channel.value(referenceMeta)

    STAGE1_ALIGNMENT(
        chPlatformPayload,
        chRefGenome,
        chRefFai,
        chBwaIndex,
        chRefDict,
        chSvdPanel,
        chFreemix,
        chReferenceMeta
    )
}
