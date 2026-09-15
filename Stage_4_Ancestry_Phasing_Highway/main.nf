nextflow.enable.dsl = 2

include { STAGE4_ANCESTRY_PGX } from './workflows/stage4_ancestry_pgx.nf'
include { POPPCA_REFERENCE_PROJECTION } from './modules/local/poppca_reference_projection.nf'
include { WHATSHAP_SHAPEIT_PHASER } from './modules/local/whatshap_shapeit_phaser.nf'
include { BANK_STAGE4_CONTRACT } from './modules/local/bank_stage4_contract.nf'
include { ASSEMBLE_STAGE4_BANKED_MANIFEST } from './modules/local/assemble_stage4_banked_manifest.nf'

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


def normalizeVariantBranches(Object rawBranches) {
    def source = mapOrEmpty(rawBranches)
    [
        snv_indel            : (source.snv_indel ?: false),
        structural_variants  : (source.structural_variants ?: false),
        copy_number_cnv      : (source.copy_number_cnv ?: false),
        str_expansions       : (source.str_expansions ?: false),
        trisomy_aneuploidy   : (source.trisomy_aneuploidy ?: false),
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

def resolveAssetPath(String rawPath, String rootDir, String baseUri = null) {
    if (!rawPath) {
        return null
    }
    def resolved = resolvePath(rawPath, rootDir)
    if (resolved.exists()) {
        return resolved
    }
    if (baseUri) {
        def joined = resolvePath(new File(baseUri, rawPath).path, rootDir)
        if (joined.exists()) {
            return joined
        }
    }
    return resolved
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

def sha256Hex(File fileObj) {
    def digest = java.security.MessageDigest.getInstance('SHA-256')
    digest.update(fileObj.bytes)
    digest.digest().collect { byte b -> String.format('%02x', b) }.join()
}


def writeStage4Rejection(String outdir, String sampleId, String reason, String detail, Map extra = [:]) {
    def auditDir = new File("${outdir}/audit_and_qc/stage4")
    auditDir.mkdirs()
    def payload = [
        failure_code: 'STAGE4_PRECONDITION_FAILURE',
        sample_id: sampleId,
        reason: reason,
        detail: detail,
        timestamp_utc: new Date().format("yyyy-MM-dd'T'HH:mm:ssXXX")
    ] + extra
    new File(auditDir, 'stage4_rejection_audit.json').text = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(payload)) + '\n'
}


def buildMetaRow(Map sample, String outdir) {
    def consentTokens = mapOrEmpty(sample.consent_tokens)
    def stage0Tokens = mapOrEmpty(sample.stage0_consent_tokens) ?: consentTokens
    def referenceBuild = mapOrEmpty(sample.reference_build)
    def stage1AssetBase = (sample.stage1_asset_base_uri ?: sample.asset_base_uri)?.toString()
    def preserved = new LinkedHashMap(sample)
    preserved + [
        sample_id: sample.sample_id,
        patient_id: (sample.patient_id ?: sample.sample_id),
        case_id: (sample.case_id ?: sample.patient_id ?: sample.sample_id),
        run_mode: (sample.run_mode ?: 'production').toString(),
        stage2_contamination_status: sample.stage2_contamination_status ?: '',
        stage2_contamination_policy_action: sample.stage2_contamination_policy_action ?: '',
        validation_token: sample.validation_token?.toString(),
        consent_tokens: consentTokens,
        stage0_consent_tokens: stage0Tokens,
        variant_branches: normalizeVariantBranches(sample.variant_branches),
        active_branches: (sample.active_branches instanceof List ? sample.active_branches : []),
        normalized_vcf: sample.normalized_vcf?.toString(),
        normalized_vcf_tbi: sample.normalized_vcf_tbi?.toString(),
        sorted_bam: sample.sorted_bam?.toString(),
        sorted_bai: sample.sorted_bai?.toString(),
        sorted_bam_basename: (sample.sorted_bam_basename ?: (sample.sorted_bam ? new File(sample.sorted_bam.toString()).name : null)),
        sorted_bai_basename: (sample.sorted_bai_basename ?: (sample.sorted_bai ? new File(sample.sorted_bai.toString()).name : null)),
        stage1_asset_base_uri: stage1AssetBase,
        asset_base_uri: stage1AssetBase,
        harmonization_audit: sample.harmonization_audit?.toString(),
        reference_build: referenceBuild,
        stage4_handoff_note: (sample.stage4_handoff_note ?: 'Stage 4 ancestry and phasing handoff.'),
        save_dir: outdir
    ]
}

workflow STAGE4_ANCESTRY_PHASING {
    take:
    ch_stage4_inputs

    main:
    POPPCA_REFERENCE_PROJECTION(ch_stage4_inputs)
    WHATSHAP_SHAPEIT_PHASER(POPPCA_REFERENCE_PROJECTION.out.ancestry_ready)
    BANK_STAGE4_CONTRACT(WHATSHAP_SHAPEIT_PHASER.out.phase_bundle)
    ASSEMBLE_STAGE4_BANKED_MANIFEST(BANK_STAGE4_CONTRACT.out.manifest_fragment.collect())

    emit:
    banked_manifest = ASSEMBLE_STAGE4_BANKED_MANIFEST.out.banked_manifest
    phase_bundle = WHATSHAP_SHAPEIT_PHASER.out.phase_bundle
}

workflow {
    def ys = new groovy.yaml.YamlSlurper()

    def stage3ManifestFile = file((params.input ?: params.samples).toString())
    def referencesFile = resolveStageConfigPath(readOptionalParam('ref_config'), params.references, 'references.yaml')
    def thresholdsFile = resolveStageConfigPath(readOptionalParam('thresh_config'), params.thresholds, 'thresholds.yaml')
    def infrastructureFile = resolveStageConfigPath(readOptionalParam('infra_config'), params.infrastructure, 'infrastructure.yaml')

    if (!stage3ManifestFile.exists()) {
        throw new IllegalArgumentException('STAGE4_PRECONDITION_FAILURE: missing Stage 3 banked manifest')
    }

    def stage3Parsed = ys.parse(stage3ManifestFile)
    def referenceInfo = loadResolvedReferences(referencesFile)
    def refsParsed = referenceInfo.refs
    def thresholdsParsed = ys.parse(thresholdsFile)
    def infrastructureParsed = ys.parse(infrastructureFile) ?: [:]
    def samples = stage3Parsed.samples

    if (!(samples instanceof List) || samples.isEmpty()) {
        throw new IllegalArgumentException('STAGE4_PRECONDITION_FAILURE: Stage 3 manifest contains no samples')
    }

    def samplesRoot = stage3ManifestFile.parent ? stage3ManifestFile.parent.toString() : projectDir.toString()
    def infrastructureRoot = infrastructureFile.parent ? infrastructureFile.parent.toString() : projectDir.toString()
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
    def refGenome = refsParsed.reference_genome ?: refsParsed.grch38_fasta
    def refFai = refsParsed.reference_fai ?: refsParsed.grch38_fai ?: (refGenome ? "${refGenome}.fai" : null)
    def refDict = refsParsed.reference_dict ?: refsParsed.grch38_dict
    def poppcaModels = refsParsed.models?.poppca_models ?: refsParsed.poppca_models
    def phasingPanel = refsParsed.onco_target_bed ?: refsParsed.capture_wes_bed

    def requiredRefMap = [
        reference_genome: refGenome,
        reference_fai: refFai,
        reference_dict: refDict,
        poppca_models: poppcaModels,
        phasing_panel: phasingPanel
    ]
    requiredRefMap.each { key, value ->
        if (!value) {
            writeStage4Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', key)
            throw new IllegalStateException("STAGE4_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}'")
        }
    }

    ['reference_genome', 'reference_fai', 'reference_dict'].each { key ->
        def p = requiredRefMap[key].toString()
        def hostFile = hostPathForReference(p, refDir)
        if (hostFile == null || !hostFile.exists()) {
            writeStage4Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', "${key}=${p}")
            throw new IllegalStateException("STAGE4_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}=${p}'")
        }
    }

    def hostPopPcaModels = hostPathForReference(poppcaModels.toString(), refDir)
    if (hostPopPcaModels == null || !hostPopPcaModels.exists()) {
        writeStage4Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', poppcaModels.toString())
        throw new IllegalStateException('STAGE4_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET poppca_models')
    }

    def hostPhasingPanel = hostPathForReference(phasingPanel.toString(), refDir)
    if (hostPhasingPanel == null || !hostPhasingPanel.exists()) {
        writeStage4Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', phasingPanel.toString())
        throw new IllegalStateException('STAGE4_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET phasing_panel')
    }

    samples.each { sample ->
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        def stage1AssetBase = [sample.stage1_asset_base_uri, sample.asset_base_uri].find { v -> v != null && v.toString().trim() }?.toString()
        def token = sample.validation_token?.toString()
        if (!token || !token.contains('VALID_PASS|VARIANTS_HARMONIZED')) {
            writeStage4Rejection(params.outdir.toString(), sid, 'INVALID_STAGE3_TOKEN', token ?: 'missing')
            throw new IllegalStateException("STAGE4_PRECONDITION_FAILURE: invalid Stage 3 validation token for sample '${sid}'")
        }

        ['normalized_vcf', 'normalized_vcf_tbi'].each { field ->
            def raw = sample[field]?.toString()
            if (!raw) {
                writeStage4Rejection(params.outdir.toString(), sid, 'MISSING_STAGE3_ASSET', field)
                throw new IllegalStateException("STAGE4_PRECONDITION_FAILURE: missing '${field}' for sample '${sid}'")
            }
            def resolved = resolvePath(raw, samplesRoot)
            if (!resolved.exists()) {
                writeStage4Rejection(params.outdir.toString(), sid, 'STAGE3_ASSET_NOT_FOUND', "${field}=${raw}")
                throw new IllegalStateException("STAGE4_PRECONDITION_FAILURE: stage 3 asset not found '${field}' for sample '${sid}'")
            }
        }

        [
            sorted_bam: [sample.sorted_bam, sample.sorted_bam_basename, sample.mapped_bam_basename, sample.mapped_bam],
            sorted_bai: [sample.sorted_bai, sample.sorted_bai_basename, sample.mapped_bai_basename, sample.mapped_bai]
        ].each { field, candidates ->
            def raw = candidates.find { v -> v != null && v.toString().trim() }?.toString()
            if (!raw) {
                writeStage4Rejection(params.outdir.toString(), sid, 'MISSING_STAGE3_ASSET', field)
                throw new IllegalStateException("STAGE4_PRECONDITION_FAILURE: missing '${field}' for sample '${sid}'")
            }
            def resolved = resolveAssetPath(raw, samplesRoot, stage1AssetBase)
            if (!resolved.exists()) {
                writeStage4Rejection(params.outdir.toString(), sid, 'STAGE3_ASSET_NOT_FOUND', "${field}=${raw}")
                throw new IllegalStateException("STAGE4_PRECONDITION_FAILURE: stage 3 asset not found '${field}' for sample '${sid}'")
            }
        }

        def normalizedVcf = resolvePath(sample.normalized_vcf.toString(), samplesRoot)
        def normalizedVcfShaExpected = sample.normalized_vcf_sha256?.toString()?.trim()
        if (!normalizedVcfShaExpected) {
            writeStage4Rejection(params.outdir.toString(), sid, 'MISSING_STAGE3_ASSET_HASH', 'normalized_vcf_sha256')
            throw new IllegalStateException("STAGE4_PRECONDITION_FAILURE: missing 'normalized_vcf_sha256' for sample '${sid}'")
        }
        def normalizedVcfShaObserved = sha256Hex(normalizedVcf)
        if (normalizedVcfShaObserved != normalizedVcfShaExpected.toLowerCase()) {
            writeStage4Rejection(
                params.outdir.toString(),
                sid,
                'STAGE3_VCF_SHA256_MISMATCH',
                "normalized_vcf_sha256=${normalizedVcfShaExpected}; observed=${normalizedVcfShaObserved}"
            )
            throw new IllegalStateException("STAGE4_PRECONDITION_FAILURE: normalized VCF SHA-256 mismatch for sample '${sid}'")
        }

        def normalizedVcfTbi = resolvePath(sample.normalized_vcf_tbi.toString(), samplesRoot)
        def normalizedVcfTbiShaExpected = sample.normalized_vcf_tbi_sha256?.toString()?.trim()
        if (!normalizedVcfTbiShaExpected) {
            writeStage4Rejection(params.outdir.toString(), sid, 'MISSING_STAGE3_ASSET_HASH', 'normalized_vcf_tbi_sha256')
            throw new IllegalStateException("STAGE4_PRECONDITION_FAILURE: missing 'normalized_vcf_tbi_sha256' for sample '${sid}'")
        }
        def normalizedVcfTbiShaObserved = sha256Hex(normalizedVcfTbi)
        if (normalizedVcfTbiShaObserved != normalizedVcfTbiShaExpected.toLowerCase()) {
            writeStage4Rejection(
                params.outdir.toString(),
                sid,
                'STAGE3_TBI_SHA256_MISMATCH',
                "normalized_vcf_tbi_sha256=${normalizedVcfTbiShaExpected}; observed=${normalizedVcfTbiShaObserved}"
            )
            throw new IllegalStateException("STAGE4_PRECONDITION_FAILURE: normalized VCF TBI SHA-256 mismatch for sample '${sid}'")
        }
    }

    def referenceMeta = [
        reference_genome: refGenome.toString(),
        reference_fai: refFai.toString(),
        reference_dict: refDict.toString(),
        poppca_models: poppcaModels.toString(),
        phasing_panel_bed: phasingPanel.toString(),
        clinvar_db: refsParsed.clinvar_db,
        thresholds_reference: thresholdsParsed
    ]

    def chStage4Inputs = channel.fromList(samples).map { sample ->
        def meta = buildMetaRow(sample as Map, params.outdir.toString())
        def stage1AssetBase = [sample.stage1_asset_base_uri, sample.asset_base_uri].find { v -> v != null && v.toString().trim() }?.toString()
        def normalizedVcf = resolvePath(sample.normalized_vcf.toString(), samplesRoot)
        def normalizedVcfTbi = resolvePath(sample.normalized_vcf_tbi.toString(), samplesRoot)
        def sortedBamRaw = [sample.sorted_bam, sample.sorted_bam_basename, sample.mapped_bam_basename, sample.mapped_bam].find { v -> v != null && v.toString().trim() }?.toString()
        def sortedBaiRaw = [sample.sorted_bai, sample.sorted_bai_basename, sample.mapped_bai_basename, sample.mapped_bai].find { v -> v != null && v.toString().trim() }?.toString()
        def sortedBam = resolveAssetPath(sortedBamRaw, samplesRoot, stage1AssetBase)
        def sortedBai = resolveAssetPath(sortedBaiRaw, samplesRoot, stage1AssetBase)
        tuple(
            meta,
            file(normalizedVcf, checkIfExists: true),
            file(normalizedVcfTbi, checkIfExists: true),
            file(sortedBam, checkIfExists: true),
            file(sortedBai, checkIfExists: true),
            referenceMeta,
            hostPopPcaModels.toString(),
            hostPhasingPanel.toString()
        )
    }

    STAGE4_ANCESTRY_PGX(chStage4Inputs)
}
