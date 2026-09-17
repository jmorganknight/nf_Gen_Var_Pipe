nextflow.enable.dsl = 2

params.outdir = java.nio.file.Paths.get((params.outdir ?: 'results').toString()).toAbsolutePath().normalize().toString()
params.stage6_outdir = java.nio.file.Paths.get((params.stage6_outdir ?: "${params.outdir}/Stage_6").toString()).toAbsolutePath().normalize().toString()

include { STAGE6_PRECONDITION_GUARD } from './modules/local/stage6_precondition_guard.nf'
include { VERIFY_STAGE5_SIGNATURE } from './modules/local/verify_stage5_signature.nf'
include { STAGE6_VARIANT_INTEGRITY_AUDITOR } from './modules/local/stage6_variant_integrity_auditor.nf'
include { DOWNGRADED_VARIANT_SINK } from './modules/local/downgraded_variant_sink.nf'
include { STAGE6_WETLAB_CONFIRMATION_GATE } from './modules/local/stage6_wetlab_confirmation_gate.nf'
include { MEDICAL_DIRECTOR_WORKBENCH_GATEWAY } from './modules/local/medical_director_workbench_gateway.nf'
include { FHIR_REPORT_BUILDER } from './modules/local/fhir_report_builder.nf'
include { AUDIT_SINK } from './modules/local/audit_sink.nf'
include { LAB_METRICS_SINK } from './modules/local/lab_metrics_sink.nf'
include { ASSEMBLE_STAGE6_MANIFEST } from './modules/local/assemble_stage6_manifest.nf'
include { STAGE6_RELEASE_FINALIZER } from './modules/local/stage6_release_finalizer.nf'


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

    def primary = new File(projectDir.toString(), "control_plane/${fileName}")
    if (primary.exists()) {
        return file(primary.path)
    }

    def fallback = new File(projectDir.toString(), "../control_plane/${fileName}")
    if (fallback.exists()) {
        return file(fallback.path)
    }

    def launchRoot = workflow.hasProperty('launchDir') ? workflow.launchDir?.toString() : null
    if (launchRoot) {
        def launchFallback = new File(launchRoot, "control_plane/${fileName}")
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


def writeStage6Rejection(String outdir, String sampleId, String reason, String detail, Map extra = [:]) {
    def auditDir = new File("${outdir}/audit_and_qc")
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


def resolveGovernedAssetPath(String rawPath, File anchorFile = null) {
    def candidate = new File(rawPath)
    if (candidate.isAbsolute()) {
        return candidate.absoluteFile
    }
    if (candidate.exists()) {
        return candidate.absoluteFile
    }

    def roots = [] as List<File>
    if (anchorFile?.parentFile != null) {
        roots << anchorFile.parentFile
        if (anchorFile.parentFile.parentFile != null) {
            roots << anchorFile.parentFile.parentFile
        }
    }
    roots << new File(projectDir.toString())
    if (new File(projectDir.toString()).parentFile != null) {
        roots << new File(projectDir.toString()).parentFile
    }
    def launchRoot = workflow.hasProperty('launchDir') ? workflow.launchDir?.toString() : null
    if (launchRoot) {
        roots << new File(launchRoot)
    }

    roots.findAll { rootDir -> rootDir != null }.each { rootDir ->
        def resolved = new File(rootDir, rawPath)
        if (resolved.exists()) {
            candidate = resolved.absoluteFile
            return
        }
    }

    if (candidate.exists()) {
        return candidate.absoluteFile
    }
    def defaultRoot = roots.find { rootDir -> rootDir != null }
    return defaultRoot != null ? new File(defaultRoot, rawPath).absoluteFile : candidate.absoluteFile
}

Map resolveStage6SignerPolicy(File thresholdsFile) {
    def thresholdsDoc = mapOrEmpty(new groovy.yaml.YamlSlurper().parse(thresholdsFile))
    def reporting = mapOrEmpty(mapOrEmpty(thresholdsDoc.clinical).reporting)

    def rawPubPath = readOptionalParam('signer_pub_path')?.toString()?.trim() ?: reporting.pki_pub_key_path?.toString()?.trim()
    if (!rawPubPath) {
        throw new IllegalStateException('STAGE6_PRECONDITION_FAILURE: missing governed signer public-key path (reporting.pki_pub_key_path or --signer_pub_path)')
    }

    def pubFile = resolveGovernedAssetPath(rawPubPath, thresholdsFile)
    if (!pubFile.exists() || !pubFile.isFile()) {
        throw new IllegalStateException("STAGE6_PRECONDITION_FAILURE: signer public key not found: ${pubFile}")
    }

    def signerScope = readOptionalParam('signer_scope')?.toString()?.trim() ?: reporting.pki_signer_scope?.toString()?.trim() ?: 'bootstrap'
    def signerId = readOptionalParam('signer_id')?.toString()?.trim() ?: reporting.pki_signer_id?.toString()?.trim() ?: "${signerScope}-signer"
    def allowBootstrapRaw = readOptionalParam('allow_bootstrap_for_production_run')
    def allowBootstrap = allowBootstrapRaw != null
        ? ((allowBootstrapRaw instanceof Boolean) ? (allowBootstrapRaw as boolean) : ['1', 'true', 't', 'yes', 'y', 'on'].contains(allowBootstrapRaw.toString().trim().toLowerCase()))
        : ((reporting.allow_bootstrap_for_production_run instanceof Boolean) ? (reporting.allow_bootstrap_for_production_run as boolean) : ['1', 'true', 't', 'yes', 'y', 'on'].contains((reporting.allow_bootstrap_for_production_run ?: '').toString().trim().toLowerCase()))

    [
        pub_file: pubFile.absoluteFile,
        signer_scope: signerScope,
        signer_id: signerId,
        allow_bootstrap_for_production_run: allowBootstrap,
    ]
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

process STAGE6_RUO_DEV_REPORT_LOCK {
    label 'process_low'
    container 'genvar-reporting:2.1.0'
    stageInMode 'copy'
    publishDir "${params.stage6_outdir}", mode: 'copy', overwrite: true, pattern: 'RUO_DEV_REPORT_LOCKED.txt'

    input:
    path stage5_manifest
    val clinical_validity
    val regulatory_warning

    output:
    path 'RUO_DEV_REPORT_LOCKED.txt', emit: lock_notice

    script:
    """
    set -euo pipefail
    cat > RUO_DEV_REPORT_LOCKED.txt <<TXT
STAGE6_CLINICAL_REPORTING_LOCKED
Reason: Stage 5 manifest is marked RESEARCH_USE_ONLY from dev mode.
Manifest: ${stage5_manifest}
CLINICAL_VALIDITY: ${clinical_validity}
REGULATORY_WARNING: ${regulatory_warning}
Action: Full Stage 6 report artifacts were generated with explicit research-use-only labeling.
TXT
    """
}


workflow STAGE6_CLINICAL_REPORTING_WORKBENCH_GATEWAY {
    take:
    ch_stage6_inputs

    main:
    STAGE6_PRECONDITION_GUARD(ch_stage6_inputs)
    def verificationInput = STAGE6_PRECONDITION_GUARD.out.validated_bundle
        .map { meta, stage5_manifest, clinical_bundle_tar_gz, stage5_provenance_json, acmg_tiered_variants_json, candidate_vus_json, vus_queue_json, sf_artifact, prs_artifact, pgx_artifact, reference_meta ->
            tuple(meta, stage5_manifest, clinical_bundle_tar_gz, stage5_provenance_json, acmg_tiered_variants_json, candidate_vus_json, vus_queue_json, sf_artifact, prs_artifact, pgx_artifact, reference_meta, file(meta.stage5_production_release_json, checkIfExists: true), file(meta.stage5_signer_public_key, checkIfExists: true))
        }

    VERIFY_STAGE5_SIGNATURE(verificationInput)

    STAGE6_VARIANT_INTEGRITY_AUDITOR(VERIFY_STAGE5_SIGNATURE.out.verified_bundle)
    DOWNGRADED_VARIANT_SINK(VERIFY_STAGE5_SIGNATURE.out.verified_bundle)
    STAGE6_WETLAB_CONFIRMATION_GATE(VERIFY_STAGE5_SIGNATURE.out.verified_bundle)
    MEDICAL_DIRECTOR_WORKBENCH_GATEWAY(VERIFY_STAGE5_SIGNATURE.out.verified_bundle)
    FHIR_REPORT_BUILDER(VERIFY_STAGE5_SIGNATURE.out.verified_bundle)
    AUDIT_SINK(VERIFY_STAGE5_SIGNATURE.out.verified_bundle)
    LAB_METRICS_SINK(VERIFY_STAGE5_SIGNATURE.out.verified_bundle)

    def allFragments = STAGE6_PRECONDITION_GUARD.out.fragment
        .mix(STAGE6_VARIANT_INTEGRITY_AUDITOR.out.fragment)
        .mix(DOWNGRADED_VARIANT_SINK.out.fragment)
        .mix(STAGE6_WETLAB_CONFIRMATION_GATE.out.fragment)
        .mix(MEDICAL_DIRECTOR_WORKBENCH_GATEWAY.out.fragment)
        .mix(FHIR_REPORT_BUILDER.out.fragment)
        .mix(AUDIT_SINK.out.fragment)
        .mix(LAB_METRICS_SINK.out.fragment)
        .map { _meta, fragment -> fragment }

    def provenanceAudits = AUDIT_SINK.out.provenance_json
        .map { _meta, provenance -> provenance }

    def labMetrics = LAB_METRICS_SINK.out.lab_metrics_json
        .map { _meta, metrics -> metrics }

    ASSEMBLE_STAGE6_MANIFEST(allFragments.collect(), provenanceAudits.collect(), labMetrics.collect())

    def releaseArtifacts = FHIR_REPORT_BUILDER.out.fhir_json
        .mix(FHIR_REPORT_BUILDER.out.html_report)
        .mix(FHIR_REPORT_BUILDER.out.pdf_report)
        .mix(MEDICAL_DIRECTOR_WORKBENCH_GATEWAY.out.signoff)
        .mix(ASSEMBLE_STAGE6_MANIFEST.out.stage6_manifest)
        .mix(AUDIT_SINK.out.provenance_json.map { _meta, provenance -> provenance })
        .mix(LAB_METRICS_SINK.out.lab_metrics_json.map { _meta, metrics -> metrics })

    STAGE6_RELEASE_FINALIZER(releaseArtifacts.collect())

    emit:
    stage6_manifest = ASSEMBLE_STAGE6_MANIFEST.out.stage6_manifest
    integrity_manifest = STAGE6_RELEASE_FINALIZER.out.sha256_manifest
}

workflow {
    def ys = new groovy.yaml.YamlSlurper()

    def stage5InputPath = (params.input ?: params.samples)?.toString()
    if (!stage5InputPath) {
        throw new IllegalArgumentException('STAGE6_PRECONDITION_FAILURE: --input is required and must reference Stage 5 manifest')
    }
    def stage5ManifestFile = file(stage5InputPath)
    def referencesFile = resolveStageConfigPath(readOptionalParam('ref_config'), params.references, 'references.yaml')
    def thresholdsFile = resolveStageConfigPath(readOptionalParam('thresh_config'), params.thresholds, 'thresholds.yaml')
    def infrastructureFile = resolveStageConfigPath(readOptionalParam('infra_config'), params.infrastructure, 'infrastructure.yaml')

    if (!stage5ManifestFile.exists()) {
        throw new IllegalArgumentException('STAGE6_PRECONDITION_FAILURE: missing Stage 5 manifest')
    }
    if (!stage5ManifestFile.name.contains('_stage5.yaml')) {
        throw new IllegalArgumentException('STAGE6_PRECONDITION_FAILURE: input does not appear to be a Stage 5 manifest')
    }
    if (referencesFile != null && !referencesFile.exists()) {
        throw new IllegalArgumentException('STAGE6_PRECONDITION_FAILURE: missing references manifest')
    }
    if (thresholdsFile != null && !thresholdsFile.exists()) {
        throw new IllegalArgumentException('STAGE6_PRECONDITION_FAILURE: missing thresholds manifest')
    }

    def stage5Parsed = ys.parse(stage5ManifestFile)
    def referenceInfo = referencesFile ? loadResolvedReferences(referencesFile) : [refs: [:], refDataRoot: null]
    def referencesDocument = mapOrEmpty(referenceInfo.document)
    def referencesDocumentMap = mapOrEmpty(referencesDocument.references ?: referencesDocument)
    def refsParsed = mapOrEmpty(referenceInfo.refs)
    def refsMerged = mapOrEmpty(refsParsed) + mapOrEmpty(params.refs)
    def thresholdsParsed = thresholdsFile ? mapOrEmpty(ys.parse(thresholdsFile)) : [:]
    def signerPolicy = thresholdsFile ? resolveStage6SignerPolicy(new File(thresholdsFile.toString())) : null
    def infrastructureParsed = infrastructureFile ? mapOrEmpty(ys.parse(infrastructureFile)) : [:]
    def samples = stage5Parsed.samples
    def infrastructureRoot = infrastructureFile?.parent ? infrastructureFile.parent.toString() : projectDir.toString()
    def refDir = null
    [params.ref_data_root, params.ref_dir, infrastructureParsed?.storage?.reference_host_root, referenceInfo.yamlRefDataRoot, '/opt/reference'].find { candidate ->
        def text = candidate?.toString()?.trim()
        if (!text) {
            return false
        }
        def resolved = resolvePath(text, infrastructureRoot)
        refDir = resolved.toString()
        resolved.exists()
    }
    def stage5Root = new File(stage5ManifestFile.toString()).parentFile ?: new File(projectDir.toString())

    if (!(samples instanceof List) || samples.isEmpty()) {
        throw new IllegalArgumentException('STAGE6_PRECONDITION_FAILURE: Stage 5 manifest contains no samples')
    }

    def clinicalValidity = stage5Parsed.CLINICAL_VALIDITY?.toString()?.trim()
    def regulatoryWarning = stage5Parsed.REGULATORY_WARNING?.toString()?.trim() ?: ''
    def isRuoDevManifest = clinicalValidity == 'RESEARCH_USE_ONLY'
    def hasDevModeSample = samples.any { sample ->
        def mode = (sample.run_mode ?: 'production').toString().trim().toLowerCase()
        mode in ['dev', 'audit_only']
    }

    if (hasDevModeSample && !isRuoDevManifest) {
        writeStage6Rejection(
            params.stage6_outdir.toString(),
            'GLOBAL',
            'DEV_MODE_MANIFEST_WATERMARK_MISSING',
            "run_mode=dev detected but CLINICAL_VALIDITY is not RESEARCH_USE_ONLY"
        )
        throw new IllegalStateException(
            'STAGE6_PRECONDITION_FAILURE: dev-mode Stage 5 manifest missing required CLINICAL_VALIDITY watermark'
        )
    }

    def runModeBySample = samples.collectEntries { sample ->
        [(sample.sample_id?.toString() ?: 'UNKNOWN'): (sample.run_mode ?: 'production').toString()]
    }
    def stage2StatusBySample = samples.collectEntries { sample ->
        [(sample.sample_id?.toString() ?: 'UNKNOWN'): (sample.stage2_contamination_status ?: '').toString()]
    }
    def stage2PolicyBySample = samples.collectEntries { sample ->
        [(sample.sample_id?.toString() ?: 'UNKNOWN'): (sample.stage2_contamination_policy_action ?: '').toString()]
    }

    def referencesMeta = [
        reference_genome : refsMerged.reference_genome ?: refsMerged.grch38_fasta,
        reference_fai    : refsMerged.reference_fai ?: refsMerged.grch38_fai,
        reference_dict   : refsMerged.reference_dict ?: refsMerged.grch38_dict,
        vep_cache_dir    : refsMerged.vep_cache_dir,
        hotspot_registry : refsMerged.hotspot_registry,
        clinvar_db       : refsMerged.clinvar_db,
        gnomad_db        : refsMerged.gnomad_db,
        hgmd_db          : refsMerged.hgmd_db ?: refsMerged.hgmd_pro_db,
        sf_bed           : refsMerged.sf_bed,
        prs_weights      : refsMerged.prs_weights ?: refsMerged.prs?.marker_weights_tsv,
        cyp2d6_mask      : refsMerged.stage3?.cyp2d6_paralog_mask_bed,
        reference_checksum_manifest: refsMerged.reference_checksum_manifest ?: "${projectDir}/../assets/reference_checksums.sha256",
        reference_asset_checksums  : mapOrEmpty(refsMerged.reference_asset_checksums),
        preflight_lock   : refsMerged.preflight_lock,
        preflight_lock_status: referencesDocumentMap.preflight_lock_status ?: refsMerged.preflight_lock_status,
    ]

    ['reference_genome', 'reference_fai', 'reference_dict', 'hotspot_registry', 'clinvar_db', 'gnomad_db', 'hgmd_db', 'sf_bed', 'prs_weights'].each { key ->
        def value = referencesMeta[key]
        if (!value) {
            writeStage6Rejection(params.stage6_outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', key)
            throw new IllegalStateException("STAGE6_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}'")
        }
        def resolved = hostPathForReference(value.toString(), refDir)
        if (resolved == null || !resolved.exists()) {
            writeStage6Rejection(params.stage6_outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', "${key}=${value}")
            throw new IllegalStateException("STAGE6_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}=${value}'")
        }
    }

    def sampleBundles = samples.collect { sample ->
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        def token = sample.validation_token?.toString() ?: ''
        if (!token.contains('VALID_PASS|VARIANTS_HARMONIZED')) {
            writeStage6Rejection(params.stage6_outdir.toString(), sid, 'INVALID_STAGE5_TOKEN', token ?: 'missing')
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
        def clinicalBundle = resolveStage5Artifact(pgxDir, sample.stage5_outputs?.clinical_bundle_tar_gz?.toString(), "${sid}.clinical_bundle.tar.gz")
        def stage5Provenance = resolveStage5Artifact(pgxDir, sample.stage5_outputs?.provenance_json?.toString(), "${sid}.provenance.json")
        def releaseDir = new File(stage5Root, 'clinical_release')
        def stage5ProductionRelease = resolveStage5Artifact(releaseDir, sample.stage5_outputs?.production_release_json?.toString(), "${sid}_production_release.json")
        def hasClinicalBundle = clinicalBundle != null && clinicalBundle.exists()
        def hasStage5Provenance = stage5Provenance != null && stage5Provenance.exists()
        def hasStage5ProductionRelease = stage5ProductionRelease != null && stage5ProductionRelease.exists()
        if (!hasClinicalBundle) {
            writeStage6Rejection(params.stage6_outdir.toString(), sid, 'MISSING_STAGE5_SIGNED_BUNDLE', sample.stage5_outputs?.clinical_bundle_tar_gz?.toString() ?: 'unset')
            throw new IllegalStateException("STAGE6_PRECONDITION_FAILURE: missing Stage 5 signed clinical bundle for sample '${sid}'")
        }
        if (!hasStage5Provenance) {
            writeStage6Rejection(params.stage6_outdir.toString(), sid, 'MISSING_STAGE5_PROVENANCE', sample.stage5_outputs?.provenance_json?.toString() ?: 'unset')
            throw new IllegalStateException("STAGE6_PRECONDITION_FAILURE: missing Stage 5 provenance payload for sample '${sid}'")
        }
        if (!hasStage5ProductionRelease) {
            writeStage6Rejection(params.stage6_outdir.toString(), sid, 'MISSING_STAGE5_PRODUCTION_RELEASE', sample.stage5_outputs?.production_release_json?.toString() ?: 'unset')
            throw new IllegalStateException("STAGE6_PRECONDITION_FAILURE: missing Stage 5 production release payload for sample '${sid}'")
        }

        def isRuoDevSample = isRuoDevManifest || ['dev', 'audit_only'].contains((runModeBySample[sid] ?: '').toString().trim().toLowerCase())

        if (!isRuoDevSample) {
            [acmgTiered, candidateVus, vusQueue, sfArtifact, prsArtifact, pgxArtifact].each { pathObj ->
                if (pathObj == null || !pathObj.exists()) {
                    writeStage6Rejection(params.stage6_outdir.toString(), sid, 'MISSING_STAGE5_ARTIFACT', pathObj?.toString() ?: 'null')
                    throw new IllegalStateException("STAGE6_PRECONDITION_FAILURE: missing Stage 5 artifact for sample '${sid}'")
                }
            }
        }

        // RUO/dev runs may legitimately have zero or bypassed branch artifacts;
        // reuse signed provenance as a real file fallback instead of creating placeholders.
        def acmgTieredResolved = isRuoDevSample ? ((acmgTiered != null && acmgTiered.exists()) ? acmgTiered : stage5Provenance) : acmgTiered
        def candidateVusResolved = isRuoDevSample ? ((candidateVus != null && candidateVus.exists()) ? candidateVus : stage5Provenance) : candidateVus
        def vusQueueResolved = isRuoDevSample ? ((vusQueue != null && vusQueue.exists()) ? vusQueue : stage5Provenance) : vusQueue
        def sfArtifactResolved = isRuoDevSample ? ((sfArtifact != null && sfArtifact.exists()) ? sfArtifact : stage5Provenance) : sfArtifact
        def prsArtifactResolved = isRuoDevSample ? ((prsArtifact != null && prsArtifact.exists()) ? prsArtifact : stage5Provenance) : prsArtifact
        def pgxArtifactResolved = isRuoDevSample ? ((pgxArtifact != null && pgxArtifact.exists()) ? pgxArtifact : stage5Provenance) : pgxArtifact

        def meta = [
            sample_id        : sid,
            run_mode         : runModeBySample[sid] ?: 'production',
            clinical_validity: clinicalValidity ?: '',
            regulatory_warning: regulatoryWarning,
            research_grade_report: isRuoDevSample,
            stage2_contamination_status: stage2StatusBySample[sid] ?: '',
            stage2_contamination_policy_action: stage2PolicyBySample[sid] ?: '',
            validation_token : token,
            stage5_manifest  : stage5ManifestFile.toString(),
            stage5_root      : stage5Root.toString(),
            stage5_outputs   : mapOrEmpty(sample.stage5_outputs),
            stage5_bundle    : clinicalBundle.toString(),
            stage5_provenance: stage5Provenance.toString(),
            stage5_production_release_json: stage5ProductionRelease.toString(),
            stage5_signer_public_key: signerPolicy.pub_file.toString(),
            expected_stage5_signer_scope: signerPolicy.signer_scope,
            expected_stage5_signer_id: signerPolicy.signer_id,
            allow_bootstrap_for_production_run: signerPolicy.allow_bootstrap_for_production_run,
            stage5_bundle_present: hasClinicalBundle,
            stage5_provenance_present: hasStage5Provenance,
            reference_build  : mapOrEmpty(sample.reference_build),
            references_meta  : referencesMeta,
            thresholds_meta  : thresholdsParsed,
            save_dir         : params.stage6_outdir.toString(),
            workbench_note   : 'Stage 6 clinical reporting workbench gateway.'
        ]

        tuple(
            meta,
            file(stage5ManifestFile, checkIfExists: true),
            file(clinicalBundle, checkIfExists: true),
            file(stage5Provenance, checkIfExists: true),
            file(acmgTieredResolved, checkIfExists: true),
            file(candidateVusResolved, checkIfExists: true),
            file(vusQueueResolved, checkIfExists: true),
            file(sfArtifactResolved, checkIfExists: true),
            file(prsArtifactResolved, checkIfExists: true),
            file(pgxArtifactResolved, checkIfExists: true),
            referencesMeta
        )
    }

    if (isRuoDevManifest) {
        STAGE6_RUO_DEV_REPORT_LOCK(
            channel.value(file(stage5ManifestFile, checkIfExists: true)),
            channel.value(clinicalValidity),
            channel.value(regulatoryWarning)
        )
    }

    STAGE6_CLINICAL_REPORTING_WORKBENCH_GATEWAY(channel.fromList(sampleBundles))
}
