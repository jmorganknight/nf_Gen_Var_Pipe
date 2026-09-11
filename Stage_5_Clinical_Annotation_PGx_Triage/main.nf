nextflow.enable.dsl = 2

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
    def translateVepScript = file("${projectDir}/bin/translate_vep_to_acmg.py", checkIfExists: true)
    def customFreqSieveScript = file("${projectDir}/bin/custom_freq_sieve.py", checkIfExists: true)
    def acmgBayesianClassifierScript = file("${projectDir}/bin/acmg_bayesian_classifier.py", checkIfExists: true)

    STAGE5_PRECONDITION_GUARD(ch_stage5_inputs)
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
    PYPGX_PHARMCAT_CALLER(STAGE5_PRECONDITION_GUARD.out.validated_bundle)

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

    if (!(params.input?.toString())) {
        throw new IllegalArgumentException('STAGE5_PRECONDITION_FAILURE: --input is required and must reference Stage 4 banked manifest')
    }

    def stage4ManifestFile = file(params.input.toString())
    def referencesFile = file(params.references)
    def thresholdsFile = file(params.thresholds)

    if (!stage4ManifestFile.exists()) {
        throw new IllegalArgumentException('STAGE5_PRECONDITION_FAILURE: missing Stage 4 banked manifest')
    }
    if (!stage4ManifestFile.name.contains('banked_stage4')) {
        throw new IllegalArgumentException('STAGE5_PRECONDITION_FAILURE: input does not appear to be a Stage 4 banked manifest')
    }

    def stage4Parsed = ys.parse(stage4ManifestFile)
    def refsParsed = ys.parse(referencesFile).references
    def thresholdsParsed = ys.parse(thresholdsFile)
    def samples = stage4Parsed.samples

    if (!(samples instanceof List) || samples.isEmpty()) {
        throw new IllegalArgumentException('STAGE5_PRECONDITION_FAILURE: Stage 4 manifest contains no samples')
    }

    def samplesRoot = stage4ManifestFile.parent ? stage4ManifestFile.parent.toString() : projectDir.toString()

    def referencesMeta = [
        reference_genome  : refsParsed.reference_genome ?: refsParsed.grch38_fasta,
        reference_fai     : refsParsed.reference_fai ?: refsParsed.grch38_fai,
        reference_dict    : refsParsed.reference_dict ?: refsParsed.grch38_dict,
        onco_target_bed   : refsParsed.onco_target_bed ?: refsParsed.capture_wes_bed,
        capture_wes_bed   : refsParsed.capture_wes_bed ?: refsParsed.onco_target_bed,
        sf_bed            : refsParsed.sf_bed,
        prs_backbone_bed  : refsParsed.models?.prs_backbone_bed ?: refsParsed.prs_backbone_bed ?: refsParsed.onco_target_bed ?: refsParsed.capture_wes_bed,
        clinvar_db        : refsParsed.clinvar_db,
        gnomad_vcf        : refsParsed.gnomad_vcf,
        vep_cache_dir     : refsParsed.vep_cache_dir,
        hotspot_registry  : refsParsed.hotspot_registry,
        hgmd_db           : refsParsed.hgmd_db ?: refsParsed.hgmd_pro_db,
        prs_weights       : refsParsed.prs_weights ?: refsParsed.models?.prs_weights
    ]

    ['reference_genome', 'reference_fai', 'reference_dict', 'onco_target_bed', 'capture_wes_bed', 'sf_bed', 'vep_cache_dir', 'clinvar_db', 'hotspot_registry', 'hgmd_db', 'prs_weights'].each { key ->
        def value = referencesMeta[key]
        if (!value) {
            writeStage5Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', key)
            throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}'")
        }
        def resolved = hostPathForReference(value.toString(), params.ref_dir?.toString())
        if (resolved == null || !resolved.exists()) {
            writeStage5Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', "${key}=${value}")
            throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}=${value}'")
        }
    }

    samples.each { sample ->
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        def token = sample.validation_token?.toString()
        if (!token || !token.contains('VALID_PASS|VARIANTS_HARMONIZED')) {
            writeStage5Rejection(params.outdir.toString(), sid, 'INVALID_STAGE4_TOKEN', token ?: 'missing')
            throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: invalid Stage 4 validation token for sample '${sid}'")
        }

        ['phased_vcf', 'phased_vcf_tbi'].each { field ->
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
        tuple(
            meta,
            file(phasedVcf, checkIfExists: true),
            file(phasedVcfTbi, checkIfExists: true),
            referencesMeta
        )
    }

    STAGE5_ANNOTATION_PGX_TRIAGE(chStage5Inputs)
}
