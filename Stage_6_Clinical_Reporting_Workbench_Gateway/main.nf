nextflow.enable.dsl = 2

include { STAGE6_PRECONDITION_GUARD } from './modules/local/stage6_precondition_guard.nf'
include { STAGE6_VARIANT_INTEGRITY_AUDITOR } from './modules/local/stage6_variant_integrity_auditor.nf'
include { DOWNGRADED_VARIANT_SINK } from './modules/local/downgraded_variant_sink.nf'
include { STAGE6_WETLAB_CONFIRMATION_GATE } from './modules/local/stage6_wetlab_confirmation_gate.nf'
include { MEDICAL_DIRECTOR_WORKBENCH_GATEWAY } from './modules/local/medical_director_workbench_gateway.nf'
include { FHIR_REPORT_BUILDER } from './modules/local/fhir_report_builder.nf'
include { ASSEMBLE_STAGE6_BANKED_MANIFEST } from './modules/local/assemble_stage6_banked_manifest.nf'


def mapOrEmpty(Object value) {
    value instanceof Map ? (value as Map) : [:]
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
    if (!pathText?.startsWith('/opt/reference')) {
        return new File(pathText)
    }
    if (!refDir) {
        return null
    }
    def suffix = pathText.replaceFirst('^/opt/reference', '')
    return new File(refDir + suffix)
}


def writeStage6Rejection(String outdir, String sampleId, String reason, String detail, Map extra = [:]) {
    def auditDir = new File("${outdir}/audit_and_qc/stage6")
    auditDir.mkdirs()
    def payload = [
        failure_code: 'STAGE6_PRECONDITION_FAILURE',
        sample_id: sampleId,
        reason: reason,
        detail: detail,
        timestamp_utc: new Date().format("yyyy-MM-dd'T'HH:mm:ssXXX")
    ] + extra
    new File(auditDir, "${sampleId}.stage6_rejection_audit.json").text = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(payload)) + '\n'
}


def resolveStage5Artifact(File stage5Root, String artifactName, String fallbackName = null) {
    if (artifactName) {
        def direct = resolvePath(artifactName, stage5Root.toString())
        if (direct.exists()) {
            return direct
        }
    }
    if (fallbackName) {
        def fallback = new File(stage5Root, fallbackName)
        if (fallback.exists()) {
            return fallback
        }
    }
    return artifactName ? resolvePath(artifactName, stage5Root.toString()) : (fallbackName ? new File(stage5Root, fallbackName) : null)
}


workflow STAGE6_CLINICAL_REPORTING_WORKBENCH_GATEWAY {
    take:
    ch_stage6_inputs

    main:
    STAGE6_PRECONDITION_GUARD(ch_stage6_inputs)
    STAGE6_VARIANT_INTEGRITY_AUDITOR(STAGE6_PRECONDITION_GUARD.out.validated_bundle)
    DOWNGRADED_VARIANT_SINK(STAGE6_PRECONDITION_GUARD.out.validated_bundle)
    STAGE6_WETLAB_CONFIRMATION_GATE(STAGE6_PRECONDITION_GUARD.out.validated_bundle)
    MEDICAL_DIRECTOR_WORKBENCH_GATEWAY(STAGE6_PRECONDITION_GUARD.out.validated_bundle)
    FHIR_REPORT_BUILDER(STAGE6_PRECONDITION_GUARD.out.validated_bundle)

    def allFragments = STAGE6_PRECONDITION_GUARD.out.fragment
        .mix(STAGE6_VARIANT_INTEGRITY_AUDITOR.out.fragment)
        .mix(DOWNGRADED_VARIANT_SINK.out.fragment)
        .mix(STAGE6_WETLAB_CONFIRMATION_GATE.out.fragment)
        .mix(MEDICAL_DIRECTOR_WORKBENCH_GATEWAY.out.fragment)
        .mix(FHIR_REPORT_BUILDER.out.fragment)
        .map { _meta, fragment -> fragment }

    def provenanceAudits = FHIR_REPORT_BUILDER.out.provenance_audit
        .map { _meta, provenance -> provenance }

    ASSEMBLE_STAGE6_BANKED_MANIFEST(allFragments.collect(), provenanceAudits.collect())

    emit:
    banked_manifest = ASSEMBLE_STAGE6_BANKED_MANIFEST.out.banked_manifest
}

workflow {
    def ys = new groovy.yaml.YamlSlurper()

    if (!(params.input?.toString())) {
        throw new IllegalArgumentException('STAGE6_PRECONDITION_FAILURE: --input is required and must reference Stage 5 banked manifest')
    }
    if (!(params.references?.toString())) {
        throw new IllegalArgumentException('STAGE6_PRECONDITION_FAILURE: --references is required')
    }
    if (!(params.thresholds?.toString())) {
        throw new IllegalArgumentException('STAGE6_PRECONDITION_FAILURE: --thresholds is required')
    }

    def stage5ManifestFile = file(params.input.toString())
    def referencesFile = file(params.references)
    def thresholdsFile = file(params.thresholds)

    if (!stage5ManifestFile.exists()) {
        throw new IllegalArgumentException('STAGE6_PRECONDITION_FAILURE: missing Stage 5 banked manifest')
    }
    if (!stage5ManifestFile.name.contains('banked_stage5')) {
        throw new IllegalArgumentException('STAGE6_PRECONDITION_FAILURE: input does not appear to be a Stage 5 banked manifest')
    }
    if (!referencesFile.exists()) {
        throw new IllegalArgumentException('STAGE6_PRECONDITION_FAILURE: missing references manifest')
    }
    if (!thresholdsFile.exists()) {
        throw new IllegalArgumentException('STAGE6_PRECONDITION_FAILURE: missing thresholds manifest')
    }

    def stage5Parsed = ys.parse(stage5ManifestFile)
    def refsParsed = ys.parse(referencesFile).references
    def thresholdsParsed = ys.parse(thresholdsFile)
    def samples = stage5Parsed.samples
    def refDir = params.ref_dir?.toString()
    def stage5Root = new File(stage5ManifestFile.toString()).parentFile ?: new File(projectDir.toString())

    if (!(samples instanceof List) || samples.isEmpty()) {
        throw new IllegalArgumentException('STAGE6_PRECONDITION_FAILURE: Stage 5 manifest contains no samples')
    }

    def referencesMeta = [
        reference_genome : refsParsed.reference_genome ?: refsParsed.grch38_fasta,
        reference_fai    : refsParsed.reference_fai ?: refsParsed.grch38_fai,
        reference_dict   : refsParsed.reference_dict ?: refsParsed.grch38_dict,
        vep_cache_dir    : refsParsed.vep_cache_dir,
        hotspot_registry : refsParsed.hotspot_registry,
        clinvar_db       : refsParsed.clinvar_db,
        gnomad_db        : refsParsed.gnomad_db,
        hgmd_db          : refsParsed.hgmd_db ?: refsParsed.hgmd_pro_db,
        sf_bed           : refsParsed.sf_bed,
        prs_weights      : refsParsed.prs_weights,
        cyp2d6_mask      : refsParsed.stage3?.cyp2d6_paralog_mask_bed,
    ]

    ['reference_genome', 'reference_fai', 'reference_dict', 'vep_cache_dir', 'hotspot_registry', 'clinvar_db', 'gnomad_db', 'hgmd_db', 'sf_bed', 'prs_weights'].each { key ->
        def value = referencesMeta[key]
        if (!value) {
            writeStage6Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', key)
            throw new IllegalStateException("STAGE6_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}'")
        }
        def resolved = hostPathForReference(value.toString(), refDir)
        if (resolved == null || !resolved.exists()) {
            writeStage6Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', "${key}=${value}")
            throw new IllegalStateException("STAGE6_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}=${value}'")
        }
    }

    def sampleBundles = samples.collect { sample ->
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        def token = sample.validation_token?.toString() ?: ''
        if (!token.contains('VALID_PASS|VARIANTS_HARMONIZED')) {
            writeStage6Rejection(params.outdir.toString(), sid, 'INVALID_STAGE5_TOKEN', token ?: 'missing')
            throw new IllegalStateException("STAGE6_PRECONDITION_FAILURE: invalid Stage 5 validation token for sample '${sid}'")
        }

        def annotationsDir = new File(stage5Root, 'annotation')
        def sfDir = new File(stage5Root, 'secondary_findings')
        def prsDir = new File(stage5Root, 'prs')
        def pgxDir = new File(stage5Root, 'pgx')

        def acmgTiered = resolveStage5Artifact(annotationsDir, sample.stage5_outputs?.acmg_tiered_variants_json?.toString(), "${sid}.stage5_acmg_tiered_variants.json")
        def candidateVus = resolveStage5Artifact(annotationsDir, "${sid}.stage5_candidate_vus.json")
        def vusQueue = resolveStage5Artifact(annotationsDir, sample.stage5_outputs?.vus_triage_queue_json?.toString(), "${sid}.stage5_vus_triage_queue.json")
        def sfArtifact = sample.stage5_outputs?.sf_report_json?.toString() ? resolveStage5Artifact(sfDir, sample.stage5_outputs.sf_report_json.toString(), "${sid}.acmg_sf_bypassed_audit.json") : resolveStage5Artifact(sfDir, "${sid}.acmg_sf_bypassed_audit.json")
        def prsArtifact = sample.stage5_outputs?.prs_calibrated_report_json?.toString() ? resolveStage5Artifact(prsDir, sample.stage5_outputs.prs_calibrated_report_json.toString(), "${sid}.prs_bypassed_audit.json") : resolveStage5Artifact(prsDir, "${sid}.prs_bypassed_audit.json")
        def pgxArtifact = resolveStage5Artifact(pgxDir, sample.stage5_outputs?.pgx_report_json?.toString(), "${sid}.pgx_report.json")

        [acmgTiered, candidateVus, vusQueue, sfArtifact, prsArtifact, pgxArtifact].each { pathObj ->
            if (pathObj == null || !pathObj.exists()) {
                writeStage6Rejection(params.outdir.toString(), sid, 'MISSING_STAGE5_ARTIFACT', pathObj?.toString() ?: 'null')
                throw new IllegalStateException("STAGE6_PRECONDITION_FAILURE: missing Stage 5 artifact for sample '${sid}'")
            }
        }

        def meta = [
            sample_id        : sid,
            validation_token : token,
            stage5_manifest  : stage5ManifestFile.toString(),
            stage5_root      : stage5Root.toString(),
            stage5_outputs   : mapOrEmpty(sample.stage5_outputs),
            reference_build  : mapOrEmpty(sample.reference_build),
            references_meta  : referencesMeta,
            thresholds_meta  : thresholdsParsed,
            save_dir         : params.outdir.toString(),
            workbench_note   : 'Stage 6 clinical reporting workbench gateway.'
        ]

        tuple(
            meta,
            file(stage5ManifestFile, checkIfExists: true),
            file(acmgTiered, checkIfExists: true),
            file(candidateVus, checkIfExists: true),
            file(vusQueue, checkIfExists: true),
            file(sfArtifact, checkIfExists: true),
            file(prsArtifact, checkIfExists: true),
            file(pgxArtifact, checkIfExists: true),
            referencesMeta
        )
    }

    STAGE6_CLINICAL_REPORTING_WORKBENCH_GATEWAY(channel.fromList(sampleBundles))
}
