nextflow.enable.dsl = 2

include { REF_MANIFEST_SNAPSHOT_LOCK } from './modules/local/ref_manifest_snapshot_lock.nf'
include { AUTOMATED_INGEST_GATE } from './modules/local/automated_ingest_gate.nf'
include { EVALUATE_INTAKE_STATUS } from './modules/local/evaluate_intake_status.nf'
include { INGEST_FAIL_REJECT } from './modules/local/ingest_fail_reject.nf'
include { BANK_STAGE0_SUCCESS } from './modules/local/bank_stage0_success.nf'
include { ASSEMBLE_STAGE0_BANKED_MANIFEST } from './modules/local/assemble_stage0_banked_manifest.nf'

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
    REF_MANIFEST_SNAPSHOT_LOCK(ch_references_yaml, ch_samples_yaml, ch_thresholds_yaml, ch_infrastructure_yaml)

    def ch_snapshot_tokens = REF_MANIFEST_SNAPSHOT_LOCK.out.snapshot_tokens
    def ch_yaml_bundle = REF_MANIFEST_SNAPSHOT_LOCK.out.yaml_bundle

    AUTOMATED_INGEST_GATE(ch_raw_reads, ch_thresholds_yaml)
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
}

workflow {
    def ys = new groovy.yaml.YamlSlurper()

    def samplesFilePath = (params.input ?: params.samples).toString()
    def samplesFile = file(samplesFilePath)
    def referencesFile = file(params.references)
    def thresholdsFile = file(params.thresholds)
    def infrastructureFile = file(params.infrastructure)

    def samplesParsed = ys.parse(samplesFile).samples
    def thresholdsParsed = ys.parse(thresholdsFile)
    def infrastructureParsed = ys.parse(infrastructureFile) ?: [:]
    def reportingCfg = thresholdsParsed.reporting ?: thresholdsParsed.clinical?.reporting ?: [:]
    def effectiveOutdir = params.outdir.toString()
    def refsParsed = ys.parse(referencesFile).references

    if (!(samplesParsed instanceof List) || samplesParsed.isEmpty()) {
        throw new IllegalArgumentException('FATAL: samples manifest contains no samples')
    }

    def referenceMountRoot = infrastructureParsed?.storage?.reference_host_root?.toString()
    def referencesText = referencesFile.text
    if (referencesText.contains('/opt/reference') && !referenceMountRoot && !params.ref_dir) {
        throw new IllegalArgumentException(
            'FATAL: references manifest uses /opt/reference assets but no host reference mount is configured. Set storage.reference_host_root in infrastructure.yaml or provide --ref_dir.'
        )
    }

    def refDir = referenceMountRoot ?: params.ref_dir?.toString()
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

    def signerKeyRaw = (params.signer_key_path ?: reportingCfg.pki_key_path)
    if (!signerKeyRaw) {
        throw new IllegalArgumentException('FATAL: no signing key path configured. Set clinical.reporting.pki_key_path in thresholds.yaml or provide --signer_key_path.')
    }
    def signerKeyCandidate = new File(signerKeyRaw.toString())
    def signerKeyResolved = signerKeyCandidate.isAbsolute() ? signerKeyCandidate : new File(thresholdsRoot, signerKeyRaw.toString())

    def inferredPubKey = signerKeyRaw.toString().endsWith('.pem')
        ? signerKeyRaw.toString().replaceFirst(/\.pem$/, '.pub.pem')
        : "${signerKeyRaw}.pub.pem"
    def signerPubRaw = params.signer_pub_path ?: reportingCfg.pki_pub_key_path ?: inferredPubKey
    def signerPubCandidate = new File(signerPubRaw.toString())
    def signerPubResolved = signerPubCandidate.isAbsolute() ? signerPubCandidate : new File(thresholdsRoot, signerPubRaw.toString())

    def chRawReads = channel.fromList(samplesParsed).map { sample ->
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        if (!sample.fastq_forward || !sample.fastq_reverse) {
            throw new IllegalArgumentException("FATAL: Stage 0 requires fastq_forward and fastq_reverse for sample '${sid}'")
        }

        validateVariantBranchesSchema(sample.variant_branches, sid, effectiveOutdir)

        def fastq1Candidate = new File(sample.fastq_forward.toString())
        def fastq2Candidate = new File(sample.fastq_reverse.toString())
        def fastq1 = fastq1Candidate.isAbsolute() ? fastq1Candidate : new File(samplesRoot, sample.fastq_forward.toString())
        def fastq2 = fastq2Candidate.isAbsolute() ? fastq2Candidate : new File(samplesRoot, sample.fastq_reverse.toString())

        if (!fastq1.exists()) {
            throw new IllegalArgumentException("FATAL: fastq_forward not found for sample '${sid}': ${sample.fastq_forward}")
        }
        if (!fastq2.exists()) {
            throw new IllegalArgumentException("FATAL: fastq_reverse not found for sample '${sid}': ${sample.fastq_reverse}")
        }

        tuple(
            buildMetaRow(sample as Map, effectiveOutdir),
            file(fastq1, checkIfExists: true),
            file(fastq2, checkIfExists: true)
        )
    }

    def chThresholdsYaml = channel.value(thresholdsFile)
    def chReferencesYaml = channel.value(referencesFile)
    def chSamplesYaml = channel.value(samplesFile)
    def chInfrastructureYaml = channel.value(infrastructureFile)
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