nextflow.enable.dsl = 2

include { PREFLIGHT_INGESTION_GUARD } from './modules/local/preflight_ingestion_guard.nf'
include { AUTOMATED_INGEST_GATE } from './modules/local/automated_ingest_gate.nf'
include { EVALUATE_INTAKE_STATUS } from './modules/local/evaluate_intake_status.nf'
include { INGEST_FAIL_REJECT } from './modules/local/ingest_fail_reject.nf'
include { BANK_STAGE0_SUCCESS } from './modules/local/bank_stage0_success.nf'
include { ASSEMBLE_STAGE0_BANKED_MANIFEST } from './modules/local/assemble_stage0_banked_manifest.nf'

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

def isStubMode() {
    def commandLine = workflow.hasProperty('commandLine') ? (workflow.commandLine ?: '') : ''
    def stubFlag = workflow.hasProperty('stubRun') ? workflow.stubRun : null
    (stubFlag instanceof Boolean && stubFlag) || commandLine.contains('-stub')
}

def resolvePathWithBases(String rawPath, List<String> roots) {
    def candidate = new File(rawPath)
    if (candidate.isAbsolute() || candidate.exists()) {
        return candidate
    }
    def resolved = null
    roots.each { base ->
        if (!base) {
            return
        }
        def rooted = new File(base, rawPath)
        if (resolved == null && rooted.exists()) {
            resolved = rooted
            return
        }
    }
    resolved ?: new File(roots ? roots[0] : projectDir.toString(), rawPath)
}

def resolveStageConfigPath(Object overridePath, Object configuredPath, String fileName) {
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

    def launchRoot = workflow.hasProperty('launchDir') ? workflow.launchDir?.toString() : null
    def candidatePaths = [
        new File(projectDir.toString(), "conf/${fileName}"),
        new File(projectDir.toString(), "../conf/${fileName}")
    ]
    if (launchRoot) {
        candidatePaths << new File(launchRoot, "conf/${fileName}")
    }

    def resolved = candidatePaths.find { candidate -> candidate.exists() }
    if (resolved != null) {
        return file(resolved.path)
    }

    return configuredText ? file(configuredText) : file(candidatePaths[-1].path)
}

def readOptionalParam(String paramName) {
    params.containsKey(paramName) ? params[paramName] : null
}

def sha256Hex(File fileObj) {
    def digest = java.security.MessageDigest.getInstance('SHA-256')
    if (fileObj.isDirectory()) {
        def children = []
        fileObj.eachFileRecurse(groovy.io.FileType.FILES) { child ->
            children << child
        }
        children.sort { left, right ->
            fileObj.toPath().relativize(left.toPath()).toString().replace('\\', '/') <=> fileObj.toPath().relativize(right.toPath()).toString().replace('\\', '/')
        }.each { child ->
            def rel = fileObj.toPath().relativize(child.toPath()).toString().replace('\\', '/')
            digest.update(rel.getBytes('UTF-8'))
            digest.update('\u0000'.getBytes('UTF-8'))
            digest.update(sha256Hex(child).getBytes('US-ASCII'))
            digest.update('\u0000'.getBytes('UTF-8'))
        }
    } else {
        fileObj.withInputStream { stream ->
            stream.eachByte(1024 * 1024) { buffer, size ->
                digest.update(buffer, 0, size)
            }
        }
    }
    digest.digest().collect { value -> String.format('%02x', value) }.join()
}

def validateChecksumManifest(File manifestFile, String refDir, String projectRoot) {
    manifestFile.eachLine('UTF-8') { raw ->
        def line = raw.trim()
        if (!line || line.startsWith('#')) {
            return
        }
        def parts = line.split(/\s+/, 2)
        if (parts.size() != 2) {
            throw new IllegalArgumentException("Invalid checksum manifest line: ${raw}")
        }
        def pathText = parts[1].trim()
        def resolved = pathText.startsWith('/opt/reference')
            ? hostPathForReference(pathText, refDir)
            : resolvePathWithBases(pathText, [projectRoot, manifestFile.parent])
        if (sha256Hex(resolved) != parts[0].trim().toLowerCase()) {
            throw new IllegalStateException("REFERENCE_CHECKSUM_MISMATCH: ${pathText}")
        }
    }
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


def normalizeVariantBranches(Object rawBranches) {
    def source = mapOrEmpty(rawBranches)
    [
        snv_indel           : (source.snv_indel ?: true),
        structural_variants : (source.structural_variants ?: true),
        copy_number_cnv     : (source.copy_number_cnv ?: true),
        str_expansions      : (source.str_expansions ?: false),
        trisomy_aneuploidy  : (source.trisomy_aneuploidy ?: true)
    ] + source
}


def writeStage0Rejection(String outdir, String sampleId, String reason, String detail, Map extra = [:]) {
    def auditDir = new File("${outdir}/audit_and_qc/stage0")
    auditDir.mkdirs()
    def payload = [
        failure_code: 'STAGE0_PRECONDITION_FAILURE',
        sample_id: sampleId,
        reason: reason,
        detail: detail,
        timestamp_utc: new Date().format("yyyy-MM-dd'T'HH:mm:ssXXX")
    ] + extra
    new File(auditDir, "${sampleId}.stage0_rejection_audit.json").text = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(payload)) + '\n'
}


def validateVariantBranchesSchema(Object rawBranches, String sampleId, String outdir) {
    if (rawBranches == null) {
        return
    }
    if (!(rawBranches instanceof Map)) {
        writeStage0Rejection(outdir, sampleId, 'INVALID_VARIANT_BRANCHES_SCHEMA', "variant_branches must be a map, got ${rawBranches.getClass().simpleName}")
        throw new IllegalArgumentException("FATAL: invalid variant_branches schema for sample '${sampleId}'")
    }
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


def validateReferenceAsset(String key, String rawPath, String refDir, String outdir) {
    if (!rawPath) {
        throw new IllegalStateException("STAGE0_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}'")
    }
    def hostPath = hostPathForReference(rawPath.toString(), refDir)
    if (hostPath == null || !hostPath.exists()) {
        def auditDir = new File("${outdir}/audit_and_qc/stage0")
        auditDir.mkdirs()
        def payload = [
            failure_code: 'STAGE0_PRECONDITION_FAILURE',
            sample_id: 'GLOBAL',
            reason: 'MISSING_REFERENCE_ASSET',
            detail: "${key}=${rawPath}",
            timestamp_utc: new Date().format("yyyy-MM-dd'T'HH:mm:ssXXX")
        ]
        new File(auditDir, 'stage0_rejection_audit.json').text = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(payload)) + '\n'
        throw new IllegalStateException("STAGE0_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}' -> ${rawPath}")
    }
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


def buildMetaRow(Map sample, String outdir) {
    def consent = normalizeConsent(sample.consent)
    [
        sample_id               : sample.sample_id,
        patient_id              : (sample.patient_id ?: sample.sample_id),
        case_id                 : (sample.case_id ?: sample.patient_id ?: sample.sample_id),
        accession_id            : sample.accession_id,
        encounter_id            : sample.encounter_id,
        specimen_id             : sample.specimen_id,
        analysis_batch_id       : sample.analysis_batch_id,
        sample_type             : sample.sample_type,
        pathologist_tumor_burden: sample.pathologist_tumor_burden ?: 0.0,
        gender                  : sample.gender,
        prs_consent             : (consent.prs_opt_in ?: false),
        sf_consent              : (consent.sf_opt_in ?: false),
        consent                 : consent,
        consent_tokens          : deriveConsentTokens(consent),
        biological_context      : mapOrEmpty(sample.biological_context),
        diagnosis               : mapOrEmpty(sample.diagnosis),
        specimen                : mapOrEmpty(sample.specimen),
        clinical_context        : mapOrEmpty(sample.clinical_context),
        ingest_manifest         : mapOrEmpty(sample.ingest_manifest),
        sequencer               : mapOrEmpty(sample.sequencer),
        variant_branches        : normalizeVariantBranches(sample.variant_branches),
        save_dir                : outdir
    ]
}

def canonicalizeStage0Sample(Map sample) {
    def normalized = [:] + sample

    if (!normalized.fastq_forward && sample.read_file_paths?.read1) {
        normalized.fastq_forward = sample.read_file_paths.read1
    }
    if (!normalized.fastq_reverse && sample.read_file_paths?.read2) {
        normalized.fastq_reverse = sample.read_file_paths.read2
    }
    if (!normalized.mapped_bam && sample.mapped_paths?.bam) {
        normalized.mapped_bam = sample.mapped_paths.bam
    }
    if (!normalized.mapped_bai && sample.mapped_paths?.bai) {
        normalized.mapped_bai = sample.mapped_paths.bai
    }
    if (!normalized.gender && sample.reported_sex) {
        normalized.gender = sample.reported_sex
    }
    if (!normalized.consent && sample.consent_flags instanceof Map) {
        normalized.consent = [
            prs_opt_in: sample.consent_flags.prs_consent ?: false,
            sf_opt_in: sample.consent_flags.sf_acmg_consent ?: false
        ]
    }
    if (!(normalized.sequencer instanceof Map) && sample.sequencing_platform) {
        normalized.sequencer = [platform: sample.sequencing_platform]
    }

    normalized
}

workflow STAGE0_PREFLIGHT_INGEST {

    take:
    ch_raw_reads
    ch_thresholds_yaml
    ch_references_yaml
    ch_samples_yaml
    ch_infrastructure_yaml
    ch_signer_key
    ch_signer_pub

    main:
    def ch_preflight_rows = ch_raw_reads.map { meta, fastq1, fastq2 ->
        [
            sample_id: meta.sample_id?.toString() ?: 'UNKNOWN',
            patient_id: meta.patient_id?.toString() ?: '',
            case_id: meta.case_id?.toString() ?: '',
            sample_type: meta.sample_type?.toString() ?: '',
            fastq_forward: fastq1.toString(),
            fastq_reverse: fastq2.toString(),
            mapped_bam: meta.mapped_bam?.toString() ?: '',
            mapped_bai: meta.mapped_bai?.toString() ?: '',
            intake_validation_token: meta.intake_validation_token?.toString() ?: '',
            variant_branches: mapOrEmpty(meta.variant_branches)
        ]
    }.collect()

    PREFLIGHT_INGESTION_GUARD(ch_preflight_rows, ch_references_yaml, ch_samples_yaml, ch_thresholds_yaml, ch_infrastructure_yaml)

    def ch_preflight_lock = PREFLIGHT_INGESTION_GUARD.out.preflight_lock
    def ch_snapshot_tokens = PREFLIGHT_INGESTION_GUARD.out.snapshot_tokens
    def ch_yaml_bundle = PREFLIGHT_INGESTION_GUARD.out.yaml_bundle

    def ch_guarded_reads = ch_raw_reads.combine(ch_preflight_lock).map { meta, fastq1, fastq2, _preflightLock ->
        tuple(meta, fastq1, fastq2)
    }

    AUTOMATED_INGEST_GATE(ch_guarded_reads, ch_thresholds_yaml)
    EVALUATE_INTAKE_STATUS(AUTOMATED_INGEST_GATE.out.intake_payload)

    def intake_gate_routes = EVALUATE_INTAKE_STATUS.out.evaluated_payload.branch { row ->
        valid: row[3].text.trim().startsWith('VALID_PASS|')
        invalid: true
    }

    INGEST_FAIL_REJECT(intake_gate_routes.invalid, ch_signer_key, ch_signer_pub)

    def valid_by_sample = intake_gate_routes.valid.map { row -> tuple(row[0].sample_id.toString(), row) }
    def route_audit_by_sample = EVALUATE_INTAKE_STATUS.out.route_audit.map { audit ->
        def sampleId = audit.name.replaceFirst(/\.intake_route_decision\.json$/, '')
        tuple(sampleId, audit)
    }

    def bankable_valid_payload = valid_by_sample.join(route_audit_by_sample).map { _sampleId, row, routeAudit ->
        tuple(row[0], row[1], row[2], row[3], row[4], routeAudit)
    }

    BANK_STAGE0_SUCCESS(
        bankable_valid_payload,
        ch_preflight_lock,
        ch_snapshot_tokens,
        ch_yaml_bundle,
        ch_infrastructure_yaml
    )

    ASSEMBLE_STAGE0_BANKED_MANIFEST(BANK_STAGE0_SUCCESS.out.manifest_fragment.collect())

    emit:
    validated_fastqs = BANK_STAGE0_SUCCESS.out.validated_fastqs
    intake_token = BANK_STAGE0_SUCCESS.out.intake_token
    audit_bundle = BANK_STAGE0_SUCCESS.out.audit_bundle
    banked_samplesheet = ASSEMBLE_STAGE0_BANKED_MANIFEST.out.banked_samplesheet
    preflight_lock = ch_preflight_lock
}

workflow {
    def ys = new groovy.yaml.YamlSlurper()
    def launchRoot = workflow.hasProperty('launchDir') ? workflow.launchDir?.toString() : projectDir.toString()
    def repoRoot = new File(projectDir.toString()).parent ?: projectDir.toString()

    def samplesFilePath = (params.input ?: params.samples).toString()
    def samplesFile = resolvePathWithBases(samplesFilePath, [launchRoot, projectDir.toString(), repoRoot])
    def referencesFile = resolveStageConfigPath(readOptionalParam('ref_config'), params.references, 'references.yaml')
    def thresholdsFile = resolveStageConfigPath(readOptionalParam('thresh_config'), params.thresholds, 'thresholds.yaml')
    def infrastructureFile = resolveStageConfigPath(readOptionalParam('infra_config'), params.infrastructure, 'infrastructure.yaml')
    def referenceInfo = loadResolvedReferences(referencesFile)

    def samplesParsed = ys.parse(samplesFile).samples
    def thresholdsParsed = ys.parse(thresholdsFile)
    def infrastructureParsed = ys.parse(infrastructureFile) ?: [:]
    def reportingCfg = thresholdsParsed.reporting ?: thresholdsParsed.clinical?.reporting ?: [:]
    def effectiveOutdir = params.outdir.toString()
    def refsParsed = referenceInfo.refs

    if (!(samplesParsed instanceof List) || samplesParsed.isEmpty()) {
        throw new IllegalArgumentException('FATAL: samples manifest contains no samples')
    }

    def infrastructureRoot = infrastructureFile.parent ? infrastructureFile.parent.toString() : projectDir.toString()
    def refDir = null
    [params.ref_data_root, params.ref_dir, infrastructureParsed?.storage?.reference_host_root, referenceInfo.yamlRefDataRoot, '/opt/reference'].find { candidate ->
        def text = candidate?.toString()?.trim()
        if (!text) {
            return false
        }
        def resolved = resolvePathWithBases(text, [infrastructureRoot, projectDir.toString(), repoRoot])
        refDir = resolved.toString()
        resolved.exists()
    }
    def checksumManifest = resolvePathWithBases('../assets/reference_checksums.sha256', [projectDir.toString(), thresholdsFile.parent?.toString() ?: projectDir.toString()])
    if (checksumManifest.exists()) {
        validateChecksumManifest(checksumManifest, refDir, projectDir.toString())
    }
    [
        reference_genome      : (refsParsed.reference_genome ?: refsParsed.grch38_fasta),
        reference_fai         : (refsParsed.reference_fai ?: refsParsed.grch38_fai),
        reference_dict        : (refsParsed.reference_dict ?: refsParsed.grch38_dict),
        bwa_index_base        : (refsParsed.bwa_index_base ?: refsParsed.bwa_index),
        bwa_index_amb         : refsParsed.bwa_index_amb,
        bwa_index_ann         : refsParsed.bwa_index_ann,
        bwa_index_pac         : refsParsed.bwa_index_pac,
        bwa_index_bwt_2bit_64 : refsParsed.bwa_index_bwt_2bit_64,
        bwa_index_0123        : refsParsed.bwa_index_0123
    ].each { key, value -> validateReferenceAsset(key.toString(), value?.toString(), refDir, effectiveOutdir) }

    def samplesRoot = samplesFile.parent ? samplesFile.parent.toString() : projectDir.toString()
    def thresholdsRoot = thresholdsFile.parent ? thresholdsFile.parent.toString() : projectDir.toString()

    def pkiRoot = resolvePathWithBases((params.pki_key_dir ?: '../keys').toString(), [projectDir.toString(), thresholdsRoot])
    def signerKeyRaw = (params.signer_key_path ?: reportingCfg.pki_key_path ?: new File(pkiRoot, 'clinical_signer.pem').toString())
    def signerKeyResolved = resolvePathWithBases(signerKeyRaw.toString(), [thresholdsRoot, projectDir.toString(), pkiRoot.toString()])

    def inferredPubKey = signerKeyRaw.toString().endsWith('.pem')
        ? signerKeyRaw.toString().replaceFirst(/\.pem$/, '.pub.pem')
        : "${signerKeyRaw}.pub.pem"
    def signerPubRaw = params.signer_pub_path ?: reportingCfg.pki_pub_key_path ?: inferredPubKey
    def signerPubResolved = resolvePathWithBases(signerPubRaw.toString(), [thresholdsRoot, projectDir.toString(), pkiRoot.toString()])
    if ((!signerKeyResolved.exists() || !signerPubResolved.exists()) && !isStubMode()) {
        throw new IllegalStateException("STAGE5_PKI_KEY_MISSING: key=${signerKeyResolved}; pub=${signerPubResolved}")
    }
    if (isStubMode()) {
        if (!signerKeyResolved.exists()) {
            signerKeyResolved.parentFile?.mkdirs()
            signerKeyResolved.text = "-----BEGIN PRIVATE KEY-----\nSTUB\n-----END PRIVATE KEY-----\n"
        }
        if (!signerPubResolved.exists()) {
            signerPubResolved.parentFile?.mkdirs()
            signerPubResolved.text = "-----BEGIN PUBLIC KEY-----\nSTUB\n-----END PUBLIC KEY-----\n"
        }
    }

    def chRawReads = channel.fromList(samplesParsed).map { sample ->
        def normalizedSample = canonicalizeStage0Sample(sample as Map)
        def sid = (normalizedSample.sample_id ?: 'UNKNOWN').toString()
        def fq1Raw = normalizedSample.fastq_forward?.toString()
        def fq2Raw = normalizedSample.fastq_reverse?.toString()
        if (!fq1Raw || !fq2Raw) {
            throw new IllegalArgumentException("FATAL: Stage 0 requires fastq_forward/fastq_reverse or read_file_paths.read1/read2 for sample '${sid}'")
        }

        validateVariantBranchesSchema(normalizedSample.variant_branches, sid, effectiveOutdir)

        def fastq1 = resolvePathWithBases(fq1Raw, [launchRoot, projectDir.toString(), repoRoot, samplesRoot])
        def fastq2 = resolvePathWithBases(fq2Raw, [launchRoot, projectDir.toString(), repoRoot, samplesRoot])

        if (!fastq1.exists()) {
            throw new IllegalArgumentException("FATAL: fastq_forward not found for sample '${sid}': ${fq1Raw}")
        }
        if (!fastq2.exists()) {
            throw new IllegalArgumentException("FATAL: fastq_reverse not found for sample '${sid}': ${fq2Raw}")
        }

        tuple(
            buildMetaRow(normalizedSample, effectiveOutdir),
            file(fastq1, checkIfExists: true),
            file(fastq2, checkIfExists: true)
        )
    }

    def chThresholdsYaml = channel.value(file(thresholdsFile, checkIfExists: true))
    def chReferencesYaml = channel.value(file(referencesFile, checkIfExists: true))
    def chSamplesYaml = channel.value(file(samplesFile, checkIfExists: true))
    def chInfrastructureYaml = channel.value(file(infrastructureFile, checkIfExists: true))
    def chSignerKey = channel.value(file(signerKeyResolved, checkIfExists: true))
    def chSignerPub = channel.value(file(signerPubResolved, checkIfExists: true))

    STAGE0_PREFLIGHT_INGEST(
        chRawReads,
        chThresholdsYaml,
        chReferencesYaml,
        chSamplesYaml,
        chInfrastructureYaml,
        chSignerKey,
        chSignerPub
    )
}