nextflow.enable.dsl = 2

include { STAGE5_INPUT_NORMALIZER } from './modules/local/stage5_input_normalizer.nf'
include { STAGE5_PRECONDITION_GUARD } from './modules/local/stage5_precondition_guard.nf'
include { STAGE5_ASSAY_AWARE_ROUTER } from './modules/local/stage5_assay_aware_router.nf'
include { VEP_CORE_ENGINE } from './modules/local/vep_core_engine.nf'
include { CLINVAR_SYNC_ENGINE } from './modules/local/clinvar_sync_engine.nf'
include { GNOMAD_AGGREGATOR_SIEVE } from './modules/local/gnomad_aggregator_sieve.nf'
include { ACMG_BAYESIAN_CLASSIFIER_STAGE5; VUS_TRIAGE_HGMD_SEARCH } from './modules/local/vus_triage_hgmd_search.nf'
include { ACMG_SF_GATED_EVALUATOR } from './modules/local/acmg_sf_gated_evaluator.nf'
include { PRS_SCORE_CALCULATOR } from './modules/local/prs_score_calculator.nf'
include { PYPGX_PHARMCAT_CALLER } from './modules/local/pypgx_pharmcat_caller.nf'
include { ASSEMBLE_STAGE5_BANKED_MANIFEST } from './modules/local/assemble_stage5_banked_manifest.nf'
include { STAGE5_ANNOTATION_PGX } from './workflows/stage5_annotation_pgx.nf'

def mapOrEmpty(Object value) {
    value instanceof Map ? (value as Map) : [:]
}


def normalizeVariantBranches(Object rawBranches) {
    def source = mapOrEmpty(rawBranches)
    [
        snv_indel             : (source.snv_indel ?: false),
        structural_variants   : (source.structural_variants ?: false),
        copy_number_cnv       : (source.copy_number_cnv ?: false),
        str_expansions        : (source.str_expansions ?: false),
        trisomy_aneuploidy    : (source.trisomy_aneuploidy ?: false),
        homologous_pseudogenes: (source.homologous_pseudogenes ?: false)
    ] + source
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


def resolveStage4Asset(String rawPath, String rootDir) {
    def first = resolvePath(rawPath, rootDir)
    if (first.exists()) {
        return first
    }
    def phasedCandidate = new File(rootDir, "phased/${new File(rawPath).name}")
    if (phasedCandidate.exists()) {
        return phasedCandidate
    }
    return first
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
    if (resolved != null) {
        return resolved
    }
    return new File(roots ? roots[0] : projectDir.toString(), rawPath)
}


def resolvePkiPair(Map reportingCfg, String thresholdRoot, String projectRoot) {
    def pkiRoot = resolvePathWithBases((params.pki_key_dir ?: 'keys').toString(), [projectRoot, thresholdRoot])
    def keyPath = (params.signer_key_path ?: reportingCfg.pki_key_path ?: new File(pkiRoot, 'clinical_signer.pem').toString()).toString()
    def pubPath = (params.signer_pub_path ?: reportingCfg.pki_pub_key_path ?: keyPath.replaceFirst(/\.pem$/, '.pub.pem')).toString()
    [
        key: resolvePathWithBases(keyPath, [thresholdRoot, projectRoot, pkiRoot.toString()]),
        pub: resolvePathWithBases(pubPath, [thresholdRoot, projectRoot, pkiRoot.toString()]),
        root: pkiRoot
    ]
}


def hostPathForReference(String pathText, String refDir) {
    if (!pathText?.startsWith('/opt/reference')) {
        return new File(pathText)
    }
    if (!refDir) {
        return null
    }
    def suffix = pathText.replaceFirst('^/opt/reference', '')
    return new File(refDir + suffix)
}


def resolveStage5Script(String scriptName) {
    def candidates = [
        new File(projectDir.toString(), "bin/${scriptName}"),
        new File(projectDir.toString(), "Stage_5_Clinical_Annotation_PGx_Triage/bin/${scriptName}")
    ]
    def resolved = candidates.find { candidate -> candidate.exists() }
    if (!resolved) {
        throw new IllegalArgumentException("STAGE5_PRECONDITION_FAILURE: missing helper script '${scriptName}'")
    }
    return file(resolved, checkIfExists: true)
}


def writeStage5Rejection(String outdir, String sampleId, String reason, String detail, Map extra = [:]) {
    def auditDir = new File("${outdir}/audit_and_qc/stage5")
    auditDir.mkdirs()
    def payload = [
        failure_code  : 'STAGE5_PRECONDITION_FAILURE',
        sample_id     : sampleId,
        reason        : reason,
        detail        : detail,
        timestamp_utc : new Date().format("yyyy-MM-dd'T'HH:mm:ssXXX")
    ] + extra
    new File(auditDir, 'stage5_rejection_audit.json').text = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(payload)) + '\n'
}


def buildMetaRow(Map sample, String outdir, Map referencesMeta, Map thresholdsMeta) {
    def consentTokens = mapOrEmpty(sample.consent_tokens)
    def stage0Tokens = mapOrEmpty(sample.stage0_consent_tokens) ?: consentTokens
    def referenceBuild = mapOrEmpty(sample.reference_build)
    [
        sample_id            : sample.sample_id,
        patient_id           : (sample.patient_id ?: sample.sample_id),
        case_id              : (sample.case_id ?: sample.patient_id ?: sample.sample_id),
        validation_token     : sample.validation_token?.toString(),
        consent_tokens       : consentTokens,
        stage0_consent_tokens: stage0Tokens,
        variant_branches     : normalizeVariantBranches(sample.variant_branches),
        active_branches      : (sample.active_branches instanceof List ? sample.active_branches : []),
        phased_vcf           : sample.phased_vcf?.toString(),
        phased_vcf_tbi       : sample.phased_vcf_tbi?.toString(),
        ancestry_label       : (sample.ancestry_label ?: 'UNSET').toString(),
        superpopulation      : (sample.superpopulation ?: 'UNSET').toString(),
        subpopulation        : (sample.subpopulation ?: 'UNSET').toString(),
        pc_coordinates       : mapOrEmpty(sample.pc_coordinates),
        sequencing_type      : (sample.sequencing_type ?: 'WES').toString(),
        snv_mask_bed         : (sample.snv_mask_bed ?: referenceBuild.onco_target_bed ?: referenceBuild.capture_wes_bed ?: referencesMeta.onco_target_bed ?: referencesMeta.capture_wes_bed ?: '').toString(),
        reference_build      : referenceBuild,
        references_meta      : referencesMeta,
        thresholds_meta      : thresholdsMeta,
        stage5_handoff_note  : 'Clinical annotation, SF/PRS gated triage, and independent PGx evaluation.',
        save_dir             : outdir
    ]
}

workflow STAGE5_ANNOTATION_PGX_TRIAGE {
    take:
    ch_stage5_inputs

    main:
    def translateVepScript = resolveStage5Script('translate_vep_to_acmg.py')
    def customFreqSieveScript = resolveStage5Script('custom_freq_sieve.py')
    def acmgBayesianClassifierScript = resolveStage5Script('acmg_bayesian_classifier.py')

    STAGE5_INPUT_NORMALIZER(ch_stage5_inputs)
    def normalizedBundle = STAGE5_INPUT_NORMALIZER.out.normalized_bundle.map { sample_id, phasedVcf, phasedTbi, ancestryJson, phasingAudit, referenceMeta ->
        def meta = [
            sample_id: sample_id,
            validation_token: 'VALID_PASS|VARIANTS_HARMONIZED',
            ancestry_label: 'UNSET',
            superpopulation: 'UNSET',
            subpopulation: 'UNSET',
            pc_coordinates: [:],
            phased_vcf: phasedVcf.toString(),
            phased_vcf_tbi: phasedTbi.toString(),
            ancestry_metrics_json: ancestryJson.toString(),
            phasing_audit_json: phasingAudit.toString(),
            sequencing_type: 'WES',
            save_dir: params.outdir?.toString() ?: './'
        ]
        tuple(meta, phasedVcf, phasedTbi, referenceMeta)
    }

    STAGE5_PRECONDITION_GUARD(normalizedBundle)

    STAGE5_ASSAY_AWARE_ROUTER(STAGE5_PRECONDITION_GUARD.out.validated_bundle)
    VEP_CORE_ENGINE(STAGE5_ASSAY_AWARE_ROUTER.out.router_bundle.map { meta, phasedVcf, phasedTbi, referenceMeta, routerJson -> tuple(meta, phasedVcf, phasedTbi, referenceMeta, routerJson, translateVepScript) })
    CLINVAR_SYNC_ENGINE(STAGE5_ASSAY_AWARE_ROUTER.out.router_bundle)
    GNOMAD_AGGREGATOR_SIEVE(STAGE5_ASSAY_AWARE_ROUTER.out.router_bundle.map { meta, phasedVcf, phasedTbi, referenceMeta, routerJson -> tuple(meta, phasedVcf, phasedTbi, referenceMeta, routerJson, customFreqSieveScript) })

    def vepById = VEP_CORE_ENGINE.out.annotation_bundle.map { meta, annotations, rules -> tuple(meta.sample_id, meta, annotations, rules) }
    def clinvarById = CLINVAR_SYNC_ENGINE.out.clinvar_payload.map { meta, clinvar -> tuple(meta.sample_id, clinvar) }
    def freqById = GNOMAD_AGGREGATOR_SIEVE.out.freq_payload.map { meta, freq -> tuple(meta.sample_id, freq) }

    def classifierInputs = vepById
        .join(clinvarById)
        .join(freqById)
        .map { _sampleId, meta, annotations, rules, clinvar, freq -> tuple(meta, annotations, rules, clinvar, freq, acmgBayesianClassifierScript) }

    ACMG_BAYESIAN_CLASSIFIER_STAGE5(classifierInputs)
    VUS_TRIAGE_HGMD_SEARCH(ACMG_BAYESIAN_CLASSIFIER_STAGE5.out.candidate_vus)
    ACMG_SF_GATED_EVALUATOR(STAGE5_ASSAY_AWARE_ROUTER.out.router_bundle)
    PRS_SCORE_CALCULATOR(STAGE5_ASSAY_AWARE_ROUTER.out.router_bundle)
    PYPGX_PHARMCAT_CALLER(STAGE5_ASSAY_AWARE_ROUTER.out.router_bundle.map { meta, phasedVcf, phasedTbi, referenceMeta, _routerJson ->
        tuple(meta, phasedVcf, phasedTbi, referenceMeta)
    })

    def allFragments = STAGE5_ASSAY_AWARE_ROUTER.out.router_fragment
        .mix(VUS_TRIAGE_HGMD_SEARCH.out.fragment)
        .mix(ACMG_SF_GATED_EVALUATOR.out.fragment)
        .mix(PRS_SCORE_CALCULATOR.out.fragment)
        .mix(PYPGX_PHARMCAT_CALLER.out.fragment)
        .map { _meta, fragment -> fragment }

    ASSEMBLE_STAGE5_BANKED_MANIFEST(allFragments.collect())

    emit:
    banked_manifest = ASSEMBLE_STAGE5_BANKED_MANIFEST.out.banked_manifest
}

workflow {
    def ys = new groovy.yaml.YamlSlurper()

    def stage4InputPath = (params.input ?: params.samples)?.toString()
    if (!stage4InputPath) {
        throw new IllegalArgumentException('STAGE5_PRECONDITION_FAILURE: --input is required and must reference Stage 4 banked manifest')
    }

    def stage4ManifestFile = file(stage4InputPath)

    if (!stage4ManifestFile.exists()) {
        throw new IllegalArgumentException('STAGE5_PRECONDITION_FAILURE: missing Stage 4 banked manifest')
    }
    if (!stage4ManifestFile.name.contains('banked_stage4')) {
        throw new IllegalArgumentException('STAGE5_PRECONDITION_FAILURE: input does not appear to be a Stage 4 banked manifest')
    }

    def stage4Parsed = ys.parse(stage4ManifestFile)
    def refsParsed = params.refs instanceof Map ? params.refs : [:]
    def projectRoot = projectDir.toString()
    def thresholdPath = params.thresholds?.toString() ?: "${projectRoot}/../conf/thresholds.yaml"
    def thresholdFile = file(thresholdPath)
    def thresholdRoot = thresholdFile.parent ? thresholdFile.parent.toString() : projectRoot
    def thresholdsParsed = thresholdFile.exists() ? ys.parse(thresholdFile) : [:]
    def reportingCfg = thresholdsParsed.reporting ?: thresholdsParsed.clinical?.reporting ?: [:]
    def pkiPair = resolvePkiPair(reportingCfg as Map, thresholdRoot, projectRoot)
    def signerKeyResolved = pkiPair.key as File
    def signerPubResolved = pkiPair.pub as File
    def samples = stage4Parsed.samples

    if ((!signerKeyResolved.exists() || !signerPubResolved.exists()) && !workflow.stubRun) {
        throw new IllegalStateException("STAGE5_PKI_KEY_MISSING: key=${signerKeyResolved}; pub=${signerPubResolved}")
    }

    if (workflow.stubRun) {
        if (!signerKeyResolved.exists()) {
            signerKeyResolved.parentFile?.mkdirs()
            signerKeyResolved.text = "-----BEGIN PRIVATE KEY-----\nSTUB\n-----END PRIVATE KEY-----\n"
        }
        if (!signerPubResolved.exists()) {
            signerPubResolved.parentFile?.mkdirs()
            signerPubResolved.text = "-----BEGIN PUBLIC KEY-----\nSTUB\n-----END PUBLIC KEY-----\n"
        }
    }

    if (!(samples instanceof List) || samples.isEmpty()) {
        throw new IllegalArgumentException('STAGE5_PRECONDITION_FAILURE: Stage 4 manifest contains no samples')
    }

    def samplesRoot = stage4ManifestFile.parent ? stage4ManifestFile.parent.toString() : projectDir.toString()
    def referencesMeta = refsParsed

    samples.each { sample ->
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        def token = sample.validation_token?.toString()
        if (!token || !token.contains('VALID_PASS|VARIANTS_HARMONIZED')) {
            writeStage5Rejection(params.outdir.toString(), sid, 'INVALID_STAGE4_TOKEN', token ?: 'missing')
            throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: invalid Stage 4 validation token for sample '${sid}'")
        }

        ['phased_vcf', 'phased_vcf_tbi', 'ancestry_metrics_json', 'phasing_audit_json'].each { field ->
            def raw = sample[field]?.toString()
            if (!raw) {
                writeStage5Rejection(params.outdir.toString(), sid, 'MISSING_STAGE4_ASSET', field)
                throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: missing '${field}' for sample '${sid}'")
            }
            def resolved = resolveStage4Asset(raw, samplesRoot)
            if (!resolved.exists()) {
                writeStage5Rejection(params.outdir.toString(), sid, 'STAGE4_ASSET_NOT_FOUND', "${field}=${raw}")
                throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: stage 4 asset not found '${field}' for sample '${sid}'")
            }
        }
    }

    def chStage5Inputs = channel.fromList(samples).map { sample ->
        def meta = buildMetaRow(sample as Map, params.outdir.toString(), referencesMeta, thresholdsParsed)
        def phasedVcf = resolveStage4Asset(sample.phased_vcf.toString(), samplesRoot)
        def phasedVcfTbi = resolveStage4Asset(sample.phased_vcf_tbi.toString(), samplesRoot)
        def ancestryMetrics = resolveStage4Asset(sample.ancestry_metrics_json?.toString() ?: '', samplesRoot)
        def phasingAudit = resolveStage4Asset(sample.phasing_audit_json?.toString() ?: '', samplesRoot)
        def stage5ReferenceMeta = params.refs instanceof Map ? params.refs : [:]
        tuple(
            meta.sample_id,
            file(phasedVcf, checkIfExists: true),
            file(phasedVcfTbi, checkIfExists: true),
            file(ancestryMetrics, checkIfExists: true),
            file(phasingAudit, checkIfExists: true),
            stage5ReferenceMeta
        )
    }

    STAGE5_ANNOTATION_PGX(
        chStage5Inputs,
        channel.value(file(signerKeyResolved, checkIfExists: true)),
        channel.value(file(signerPubResolved, checkIfExists: true))
    )
}
