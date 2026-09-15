nextflow.enable.dsl = 2

include { PREFLIGHT_INGESTION_GUARD } from '../Stage_0_Preflight_Ingest_Gate/modules/local/preflight_ingestion_guard.nf'
include { STAGE1_ALIGNMENT as STAGE1_ALIGNMENT_SUBFLOW } from './workflows/stage1_alignment.nf'

def mapOrEmpty(Object value) {
    value instanceof Map ? (value as Map) : [:]
}

def resolveRefPath(String entryPath, String yamlRefDataRoot) {
    if (!entryPath) {
        return entryPath
    }
    if (entryPath.startsWith('/')) {
        return entryPath
    }
    def baseRoot = yamlRefDataRoot?.trim() ? yamlRefDataRoot.toString().trim() : '/opt/reference'
    return new File(baseRoot, entryPath).path
}

def resolveReferencePathValue(Object value, String yamlRefDataRoot, String keyName = null) {
    if (value instanceof Map) {
        return (value as Map).collectEntries { key, nested ->
            [(key): resolveReferencePathValue(nested, yamlRefDataRoot, key.toString())]
        }
    }
    if (value instanceof List) {
        return (value as List).collect { nested -> resolveReferencePathValue(nested, yamlRefDataRoot, keyName) }
    }
    if (!(value instanceof CharSequence)) {
        return value
    }

    def pathText = value.toString()
    if (['reference_checksum_manifest', 'stage3_vcf_schema'].contains(keyName)) {
        return pathText
    }
    return resolveRefPath(pathText, yamlRefDataRoot)
}

def loadResolvedReferences(def referencesFile) {
    def ys = new groovy.yaml.YamlSlurper()
    def referencesDoc = mapOrEmpty(ys.parse(referencesFile))
    def yamlRefDataRoot = referencesDoc.ref_data_root?.toString()?.trim()
    def refsParsed = mapOrEmpty(resolveReferencePathValue(mapOrEmpty(referencesDoc.references ?: referencesDoc), yamlRefDataRoot))
    def stage3Refs = mapOrEmpty(refsParsed.stage3)
    if (stage3Refs.stage3_vcf_schema && !refsParsed.stage3_vcf_schema) {
        refsParsed.stage3_vcf_schema = stage3Refs.stage3_vcf_schema
    }
    [document: referencesDoc, refs: refsParsed, yamlRefDataRoot: yamlRefDataRoot]
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


def resolveStage1ConfigPath(Object overridePath, Object configuredPath, String fileName) {
    def overrideText = overridePath?.toString()?.trim()
    if (overrideText) {
        return file(overrideText)
    }

    def configuredText = configuredPath?.toString()?.trim()
    if (configuredText) {
        def configuredFile = file(configuredText)
        if (configuredFile.exists()) {
            return configuredFile
        }
    }

    def primary = new File(projectDir.toString(), "conf/${fileName}")
    if (primary.exists()) {
        return file(primary.path)
    }

    def fallback = new File(projectDir.toString(), "../conf/${fileName}")
    if (fallback.exists()) {
        return file(fallback.path)
    }

    def launchRoot = workflow.hasProperty('launchDir') ? workflow.launchDir?.toString() : null
    if (launchRoot) {
        def launchFallback = new File(launchRoot, "conf/${fileName}")
        if (launchFallback.exists()) {
            return file(launchFallback.path)
        }
        return configuredText ? file(configuredText) : file(launchFallback.path)
    }

    return configuredText ? file(configuredText) : file(fallback.path)
}


def readOptionalParam(String paramName) {
    params.containsKey(paramName) ? params[paramName] : null
}


def materializeStubStage0Token(String outdir, String sampleId) {
    def tokenDir = new File("${outdir}/audit_and_qc/stage1_stub_tokens")
    tokenDir.mkdirs()
    def tokenFile = new File(tokenDir, "${sampleId}.intake_validation_token")
    tokenFile.text = 'VALID_PASS|INTAKE_VALIDATED\n'
    tokenFile
}


def materializeStubStage1Input(String outdir, String sampleId, String requestedPath, String fallbackName) {
    def inputDir = new File("${outdir}/audit_and_qc/stage1_stub_inputs/${sampleId}")
    inputDir.mkdirs()
    def fileName = requestedPath ? new File(requestedPath).name : fallbackName
    def placeholder = new File(inputDir, fileName)
    if (!placeholder.exists()) {
        placeholder.createNewFile()
    }
    placeholder
}


def resolveStage1SampleInput(String rawPath, String samplesRoot, String outdir, String sampleId, boolean stubRun, String fallbackName) {
    if (!rawPath) {
        return stubRun ? materializeStubStage1Input(outdir, sampleId, null, fallbackName) : null
    }

    def resolved = resolvePath(rawPath, samplesRoot)
    if (resolved.exists()) {
        return resolved
    }

    stubRun ? materializeStubStage1Input(outdir, sampleId, rawPath, fallbackName) : resolved
}


def resolveStage1IntakeToken(Map sample, String samplesRoot, String outdir, boolean stubRun) {
    def tokenPathRaw = sample.intake_validation_token?.toString()?.trim()
    if (tokenPathRaw) {
        return [
            pathText : tokenPathRaw,
            tokenFile: resolvePath(tokenPathRaw, samplesRoot),
            synthetic: false
        ]
    }

    if (stubRun) {
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        def tokenFile = materializeStubStage0Token(outdir, sid)
        return [
            pathText : tokenFile.toString(),
            tokenFile: tokenFile,
            synthetic: true
        ]
    }

    [pathText: null, tokenFile: null, synthetic: false]
}


def hostPathForReference(String pathText, String refDir) {
    if (!pathText) {
        return null
    }
    if (pathText.startsWith('/opt/reference') && refDir) {
        def suffix = pathText.replaceFirst('^/opt/reference/?', '')
        return suffix ? new File(refDir, suffix) : new File(refDir)
    }
    if (pathText.startsWith('/')) {
        return new File(pathText)
    }
    if (refDir) {
        return new File(refDir, pathText)
    }
    return new File(pathText)
}


def normalizePlatform(String platform) {
    def p = (platform ?: 'illumina').toString().toLowerCase()
    if (p == 'complete_genomics') {
        return 'complete'
    }
    return p
}


def inferAssayRoute(Map sample) {
    def sampleType = (sample.sample_type ?: 'germline').toString().toLowerCase()
    def pairRole = (sample.pair_role ?: sample.tumor_normal_role ?: '').toString().toLowerCase()
    def hasPairId = (sample.pair_id ?: sample.tumor_normal_pair_id)
    if (sampleType.contains('somatic') || sampleType.contains('tumor') || pairRole in ['tumor', 'normal'] || hasPairId) {
        return 'somatic_paired'
    }
    return 'germline_single'
}


def buildMetaRow(Map sample, String outdir, String branchTargetCatalogDefault = null, String preflightLockPath = null) {
    def platformRaw = sample.sequencing_platform ?: sample.platform ?: sample.sequencer?.platform ?: 'illumina'
    def platform = normalizePlatform(platformRaw.toString())
    def consent = normalizeConsent(sample.consent)
    def assayRoute = inferAssayRoute(sample)
    [
        sample_id: sample.sample_id,
        patient_id: (sample.patient_id ?: sample.sample_id),
        case_id: (sample.case_id ?: sample.patient_id ?: sample.sample_id),
        accession_id: sample.accession_id,
        encounter_id: sample.encounter_id,
        specimen_id: sample.specimen_id,
        analysis_batch_id: sample.analysis_batch_id,
        sample_type: (sample.sample_type ?: 'germline'),
        run_mode: (sample.run_mode ?: 'production').toString(),
        pathologist_tumor_burden: sample.pathologist_tumor_burden ?: 0.0,
        physician_tumor_purity: sample.physician_tumor_purity,
        gender: (sample.gender ?: 'unknown'),
        reported_sex: (sample.reported_sex ?: sample.gender ?: 'unknown'),
        consent: consent,
        consent_tokens: mapOrEmpty(sample.consent_tokens) ?: deriveConsentTokens(consent),
        variant_branches: normalizeVariantBranches(sample.variant_branches),
        biological_context: mapOrEmpty(sample.biological_context),
        diagnosis: mapOrEmpty(sample.diagnosis),
        specimen: mapOrEmpty(sample.specimen),
        clinical_context: mapOrEmpty(sample.clinical_context),
        sequencer: (sample.sequencer ?: [:]) + [platform: platform],
        sequencing_platform: platform,
        assay_route: assayRoute,
        pair_role: (sample.pair_role ?: sample.tumor_normal_role),
        pair_id: (sample.pair_id ?: sample.tumor_normal_pair_id),
        stage0_audit_bundle: sample.stage0_audit_bundle,
        intake_validation_token: sample.intake_validation_token,
        intake_validation_report: sample.intake_validation_report,
        intake_route_decision: sample.intake_route_decision,
        branch_target_catalog: (sample.branch_target_catalog ?: branchTargetCatalogDefault),
        mapped_bam: sample.mapped_bam,
        mapped_bai: sample.mapped_bai,
        preflight_lock: (sample.preflight_lock ?: preflightLockPath),
        preflight_lock_status: (sample.preflight_lock_status ?: 'STAGE0_PREFLIGHT_LOCK_PASS'),
        reference_snapshot_tokens: sample.reference_snapshot_tokens,
        save_dir: outdir
    ]
}


def loadAtomicStage1Contract() {
    def ys = new groovy.yaml.YamlSlurper()
    def projectRoot = projectDir.toString()
    def samplesFile = file(((params.input ?: params.samples) ?: '').toString())
    def referencesFile = resolveStage1ConfigPath(readOptionalParam('ref_config'), params.references, 'references.yaml')
    def thresholdsFile = resolveStage1ConfigPath(readOptionalParam('thresh_config'), params.thresholds, 'thresholds.yaml')
    def infrastructureFile = resolveStage1ConfigPath(readOptionalParam('infra_config'), params.infrastructure, 'infrastructure.yaml')

    def samplesDoc = ys.parse(samplesFile) ?: [:]
    def referenceInfo = loadResolvedReferences(referencesFile)
    def thresholdsDoc = ys.parse(thresholdsFile) ?: [:]
    def infrastructureDoc = ys.parse(infrastructureFile) ?: [:]

    def samplesParsed = samplesDoc.samples
    def refsParsed = referenceInfo.refs
    if (!(samplesParsed instanceof List) || samplesParsed.isEmpty()) {
        throw new IllegalArgumentException('STAGE1_PRECONDITION_FAILURE: samples manifest contains no samples')
    }
    if (!(refsParsed instanceof Map) || refsParsed.isEmpty()) {
        throw new IllegalArgumentException('STAGE1_PRECONDITION_FAILURE: references manifest contains no references block')
    }

    [
        projectRoot       : projectRoot,
        samplesFile       : samplesFile,
        referencesFile    : referencesFile,
        thresholdsFile    : thresholdsFile,
        infrastructureFile: infrastructureFile,
        samplesParsed     : samplesParsed,
        refsParsed        : refsParsed,
        yamlRefDataRoot   : referenceInfo.yamlRefDataRoot,
        thresholdsParsed  : thresholdsDoc,
        infrastructureParsed: infrastructureDoc,
        samplesRoot       : samplesFile.parent ? samplesFile.parent.toString() : projectRoot,
        infrastructureRoot: infrastructureFile.parent ? infrastructureFile.parent.toString() : projectRoot,
    ]
}


workflow STAGE1_ALIGNMENT {
    def intake = loadAtomicStage1Contract()
    def stage1StubRun = workflow.stubRun as boolean

    def samplesFile = intake.samplesFile
    def referencesFile = intake.referencesFile
    def thresholdsFile = intake.thresholdsFile
    def infrastructureFile = intake.infrastructureFile
    def samplesParsed = intake.samplesParsed as List
    def refsParsed = intake.refsParsed as Map
    def thresholdsParsed = intake.thresholdsParsed as Map
    def infrastructureParsed = intake.infrastructureParsed as Map

    def allowedPlatforms = ['illumina', 'element', 'complete', 'complete_genomics', 'ultima', 'ont'] as Set
    def samplesRoot = intake.samplesRoot.toString()
    def infrastructureRoot = intake.infrastructureRoot.toString()
    def refDir = null
    [params.ref_data_root, params.ref_dir, infrastructureParsed?.storage?.reference_host_root, intake.yamlRefDataRoot, '/opt/reference'].find { candidate ->
        def text = candidate?.toString()?.trim()
        if (!text) {
            return false
        }
        def resolved = resolvePath(text, infrastructureRoot)
        refDir = resolved.toString()
        resolved.exists()
    }
    def preflightLockPublishedPath = "${params.outdir}/audit_and_qc/preflight_lock/preflight_lock.json"

    def chPreflightRows = channel.fromList(samplesParsed).map { sample ->
        [
            sample_id: (sample.sample_id ?: 'UNKNOWN').toString(),
            patient_id: (sample.patient_id ?: sample.sample_id ?: '').toString(),
            case_id: (sample.case_id ?: sample.patient_id ?: sample.sample_id ?: '').toString(),
            sample_type: (sample.sample_type ?: 'germline').toString(),
            fastq_forward: sample.fastq_forward?.toString() ?: sample.read_file_paths?.read1?.toString() ?: '',
            fastq_reverse: sample.fastq_reverse?.toString() ?: sample.read_file_paths?.read2?.toString() ?: '',
            mapped_bam: sample.mapped_bam?.toString() ?: '',
            mapped_bai: sample.mapped_bai?.toString() ?: '',
            intake_validation_token: sample.intake_validation_token?.toString() ?: '',
            branch_target_catalog: sample.branch_target_catalog?.toString() ?: '',
            variant_branches: mapOrEmpty(sample.variant_branches)
        ]
    }.collect()

    PREFLIGHT_INGESTION_GUARD(
        chPreflightRows,
        channel.value(referencesFile),
        channel.value(samplesFile),
        channel.value(samplesFile),
        channel.value(thresholdsFile),
        channel.value(infrastructureFile)
    )

    samplesParsed.each { sample ->
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        validateVariantBranchesSchema(sample.variant_branches, sid, params.outdir.toString())
        def tokenInfo = resolveStage1IntakeToken(sample as Map, samplesRoot, params.outdir.toString(), stage1StubRun)
        def tokenPathRaw = tokenInfo.pathText
        if (!tokenPathRaw) {
            writeStage1Rejection(params.outdir.toString(), sid, 'MISSING_STAGE0_TOKEN', 'samplesheet missing intake_validation_token path')
            throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: missing intake_validation_token for sample '${sid}'")
        }
        def tokenFile = tokenInfo.tokenFile as File
        if (!tokenFile.exists()) {
            writeStage1Rejection(params.outdir.toString(), sid, 'TOKEN_PATH_NOT_FOUND', tokenPathRaw)
            throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: token file not found for sample '${sid}'")
        }
        def token = tokenFile.text.trim()
        if (!token.startsWith('VALID_PASS|INTAKE_VALIDATED')) {
            writeStage1Rejection(params.outdir.toString(), sid, 'INVALID_STAGE0_TOKEN', token)
            throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: sample '${sid}' token was '${token}'")
        }

        def platform = normalizePlatform((sample.sequencing_platform ?: sample.platform ?: sample.sequencer?.platform ?: 'illumina').toString())
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
            def branchCatalogFile = branchCatalogPath.startsWith('/opt/reference') ? hostPathForReference(branchCatalogPath, refDir) : resolvePath(branchCatalogPath, samplesRoot)
            if (branchCatalogFile == null || !branchCatalogFile.exists() || branchCatalogFile.length() == 0L) {
                writeStage1Rejection(params.outdir.toString(), sid, 'REJECT_MISSING_BRANCH_CATALOG', branchCatalogPath)
                throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: branch_target_catalog missing or empty for sample '${sid}'")
            }
        }

        if (sample.mapped_bam) {
            def mappedBam = resolveStage1SampleInput(sample.mapped_bam.toString(), samplesRoot, params.outdir.toString(), sid, stage1StubRun, "${sid}.mapped.bam")
            def mappedBai = sample.mapped_bai
                ? resolveStage1SampleInput(sample.mapped_bai.toString(), samplesRoot, params.outdir.toString(), sid, stage1StubRun, "${sid}.mapped.bam.bai")
                : resolveStage1SampleInput("${mappedBam}.bai", samplesRoot, params.outdir.toString(), sid, stage1StubRun, "${sid}.mapped.bam.bai")
            if (!mappedBam.exists() || !mappedBai.exists()) {
                writeStage1Rejection(params.outdir.toString(), sid, 'MAPPED_INPUT_MISSING', "bam=${mappedBam}; bai=${mappedBai}")
                throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: mapped inputs missing for sample '${sid}'")
            }

            if (stage1StubRun) {
                return
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
            def fq1Raw = sample.fastq_forward?.toString() ?: sample.read_file_paths?.read1?.toString()
            def fq2Raw = sample.fastq_reverse?.toString() ?: sample.read_file_paths?.read2?.toString()
            if (!fq1Raw) {
                writeStage1Rejection(params.outdir.toString(), sid, 'FASTQ_INPUT_MISSING', 'r1 path missing')
                throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: FASTQ R1 input missing for sample '${sid}'")
            }
            def fq1 = resolveStage1SampleInput(fq1Raw, samplesRoot, params.outdir.toString(), sid, stage1StubRun, "${sid}_R1.fastq.gz")
            def fq2 = fq2Raw
                ? resolveStage1SampleInput(fq2Raw, samplesRoot, params.outdir.toString(), sid, stage1StubRun, "${sid}_R2.fastq.gz")
                : fq1
            if (!fq1.exists() || !fq2.exists()) {
                writeStage1Rejection(params.outdir.toString(), sid, 'FASTQ_INPUT_MISSING', "r1=${fq1}; r2=${fq2}")
                throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: FASTQ inputs missing for sample '${sid}'")
            }
        }
    }

    def refsDynamic = (params.refs instanceof Map) ? (params.refs as Map) : [:]
    def refGenome = refsDynamic.reference_genome ?: refsDynamic.fasta ?: refsParsed.reference_genome ?: refsParsed.grch38_fasta
    def refFai = refsDynamic.reference_fai ?: refsDynamic.fai ?: refsParsed.reference_fai ?: refsParsed.grch38_fai ?: (refGenome ? "${refGenome}.fai" : null)
    def refDict = refsDynamic.reference_dict ?: refsDynamic.dict ?: refsParsed.reference_dict ?: refsParsed.grch38_dict
    def bwaBase = refsDynamic.bwa_index_base ?: refsDynamic.bwa_index ?: refsParsed.bwa_index_base ?: refsParsed.bwa_index
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
        def f = hostPathForReference(p, refDir)
        if (f == null || !f.exists()) {
            writeStage1Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', "${key}=${p}")
            throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}=${p}'")
        }
    }

    def hostBwaBase = hostPathForReference(bwaBase.toString(), refDir)
    def indexSuffixes = ['.0123', '.amb', '.ann', '.bwt.2bit.64', '.pac']
    indexSuffixes.each { suffix ->
        def idxFile = new File("${hostBwaBase}${suffix}")
        if (!idxFile.exists()) {
            writeStage1Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', idxFile.toString())
            throw new IllegalStateException("STAGE1_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${idxFile}'")
        }
    }

    def chPlatformPayload = channel.fromList(samplesParsed.findAll { s -> !s.mapped_bam })
        .combine(PREFLIGHT_INGESTION_GUARD.out.preflight_lock)
        .map { sample, _preflightLock ->
        def tokenInfo = resolveStage1IntakeToken(sample as Map, samplesRoot, params.outdir.toString(), stage1StubRun)
        def normalizedSample = (sample as Map) + [intake_validation_token: tokenInfo.pathText]
        def meta = buildMetaRow(normalizedSample, params.outdir.toString(), branchTargetCatalogDefault, preflightLockPublishedPath)
        def fq1Raw = sample.fastq_forward?.toString() ?: sample.read_file_paths?.read1?.toString()
        def fq2Raw = sample.fastq_reverse?.toString() ?: sample.read_file_paths?.read2?.toString()
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        def fq1 = resolveStage1SampleInput(fq1Raw, samplesRoot, params.outdir.toString(), sid, stage1StubRun, "${sid}_R1.fastq.gz")
        def fq2 = fq2Raw
            ? resolveStage1SampleInput(fq2Raw, samplesRoot, params.outdir.toString(), sid, stage1StubRun, "${sid}_R2.fastq.gz")
            : fq1
        def tokenPath = tokenInfo.tokenFile as File
        def intakeReport = sample.intake_validation_report ? resolvePath(sample.intake_validation_report.toString(), samplesRoot) : tokenPath
        tuple(
            meta,
            file(fq1, checkIfExists: true),
            file(fq2, checkIfExists: true),
            file(tokenPath, checkIfExists: true),
            file(intakeReport, checkIfExists: true)
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
        clinvar_db: refsParsed.clinvar_db,
        preflight_lock: preflightLockPublishedPath,
        preflight_lock_status: 'STAGE0_PREFLIGHT_LOCK_PASS',
        reference_snapshot_tokens: "${params.outdir}/audit_and_qc/preflight_lock/reference_snapshot.tokens",
        yaml_snapshot_bundle: "${params.outdir}/audit_and_qc/preflight_lock/yaml_snapshot_bundle.tar.gz"
    ]
    def chReferenceMeta = channel.value(referenceMeta)

    STAGE1_ALIGNMENT_SUBFLOW(
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

workflow {
    STAGE1_ALIGNMENT()
}
