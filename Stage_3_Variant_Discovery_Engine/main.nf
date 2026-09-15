nextflow.enable.dsl = 2
// Revision marker: Stage 3 scalar-metadata dynamic calibration + schema governance wiring.

include { STAGE3_SNV_INDEL } from './modules/local/stage3_snv_indel.nf'
include { STAGE3_SNV_INDEL_DEEPVARIANT } from './modules/local/stage3_snv_indel_deepvariant.nf'
include { STAGE3_STRUCTURAL_VARIANTS } from './modules/local/stage3_structural_variants.nf'
include { STAGE3_COPY_NUMBER_CNV } from './modules/local/stage3_copy_number_cnv.nf'
include { STAGE3_STR_EXPANSIONS } from './modules/local/stage3_str_expansions.nf'
include { STAGE3_TRISOMY_ANEUPLOIDY } from './modules/local/stage3_trisomy_aneuploidy.nf'
include { STAGE3_HOMOLOGOUS_PSEUDOGENES } from './modules/local/stage3_homologous_pseudogenes.nf'
include { MANE_TRANSCRIPT_SELECTOR } from './modules/local/mane_transcript_selector.nf'
include { MERGE_STAGE3_BRANCH_VCFS } from './modules/local/merge_stage3_branch_vcfs.nf'
include { MASTER_HARMONIZED_VCF_PAYLOAD } from './modules/local/master_harmonized_vcf_payload.nf'
include { STAGE3_ZERO_LOSS_GATE_MANIFEST } from './modules/local/stage3_zero_loss_gate_manifest.nf'

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

def resolveHostPath(def rawPath, String refDir) {
    if (!rawPath) {
        return null
    }
    def p = rawPath.toString()
    if (p.startsWith('/opt/reference') && refDir) {
        def suffix = p.replaceFirst('^/opt/reference/?', '')
        return suffix ? new File(refDir, suffix).toString() : new File(refDir).toString()
    }
    if (p.startsWith('/')) {
        return p
    }
    def direct = new File(p)
    if (direct.exists()) {
        return direct.toString()
    }
    def projectRelative = new File(projectDir.toString(), p)
    if (projectRelative.exists()) {
        return projectRelative.toString()
    }
    def baseName = new File(p).name
    def stageLocalCandidates = [
        new File(projectDir.toString(), "tests/schemas/${baseName}"),
        new File(projectDir.toString(), "tests/${baseName}"),
        new File(projectDir.toString(), "../Stage_3_Variant_Discovery_Engine/tests/schemas/${baseName}"),
        new File(projectDir.toString(), "../Stage_3_Variant_Discovery_Engine/tests/${baseName}"),
    ]
    def recovered = stageLocalCandidates.find { candidate -> candidate.exists() }
    if (recovered != null) {
        return recovered.toString()
    }
    if (refDir) {
        return new File(refDir, p).toString()
    }
    return p
}

def resolveStageAssetPath(String rawPath, String rootDir, String baseUri = null) {
    if (!rawPath) {
        return null
    }
    def direct = new File(rawPath)
    if (direct.isAbsolute() || direct.exists()) {
        return direct.toString()
    }
    if (baseUri) {
        def joined = new File(baseUri, rawPath)
        if (joined.exists()) {
            return joined.toString()
        }
    }
    def rooted = new File(rootDir, rawPath)
    if (rooted.exists()) {
        return rooted.toString()
    }
    def projectRelative = new File(projectDir.toString(), rawPath)
    if (projectRelative.exists()) {
        return projectRelative.toString()
    }
    return rooted.toString()
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

def asBool(Object value) {
    if (value == null) {
        return false
    }
    def norm = value.toString().trim().toLowerCase()
    return ['1', 'true', 'yes', 'y', 'on'].contains(norm)
}

def toIntSafe(Object value, int fallback) {
    try {
        return value == null ? fallback : Integer.parseInt(value.toString())
    } catch (Exception _ignored) {
        return fallback
    }
}

def coerceIntOrFallback(Object rawValue, int fallback) {
    try {
        if (rawValue == null) {
            return fallback
        }
        if (rawValue instanceof Closure) {
            return fallback
        }
        return Integer.parseInt(rawValue.toString())
    } catch (Exception _ignored) {
        return fallback
    }
}

def resolveStage3InfrastructurePolicy(Map infrastructureParsed) {
    def fallback = [
        selected_profile: 'medium',
        available_cpus: 8,
        available_memory_gb: 32,
        variant_heavy_cpus: 8,
        process_medium_cpus: 4,
        variant_heavy_memory_gb: 32,
        process_medium_memory_gb: 24,
        max_parallel_branches: 4,
    ]

    def stage3 = mapOrEmpty(infrastructureParsed?.stage3_variant_discovery)
    def pipelineExecution = mapOrEmpty(infrastructureParsed?.pipeline_execution)
    def local = mapOrEmpty(stage3.local_system)
    if (local.isEmpty()) {
        local = mapOrEmpty(pipelineExecution.local_system)
    }
    def profiles = mapOrEmpty(stage3.profiles)
    def thresholds = mapOrEmpty(stage3.auto_thresholds)

    if (profiles.isEmpty()) {
        return fallback
    }

    def detectedCpus = Runtime.runtime.availableProcessors()
    def totalCpus = toIntSafe(local.total_cpus, detectedCpus)
    def reserveCpus = toIntSafe(local.reserve_cpus, 0)
    def totalMemGb = toIntSafe(local.total_memory_gb, 64)
    def reserveMemGb = toIntSafe(local.reserve_memory_gb, 8)

    def availableCpus = Math.max(1, totalCpus - reserveCpus)
    def availableMemGb = Math.max(4, totalMemGb - reserveMemGb)

    def mode = (stage3.profile_selection_mode ?: 'auto').toString().trim().toLowerCase()
    def forcedProfile = params.infrastructure_profile?.toString()?.trim()
    def selectedProfile = null

    if (forcedProfile) {
        if (!profiles.containsKey(forcedProfile)) {
            throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: invalid infrastructure_profile '${forcedProfile}'. Valid profiles: ${profiles.keySet().sort().join(', ')}")
        }
        selectedProfile = forcedProfile
    } else if (mode == 'manual') {
        selectedProfile = (stage3.active_profile ?: 'medium').toString().trim()
    } else {
        def smallMax = toIntSafe(thresholds.small_max_available_cpus, 12)
        def mediumMax = toIntSafe(thresholds.medium_max_available_cpus, 24)
        if (availableCpus <= smallMax) {
            selectedProfile = 'small'
        } else if (availableCpus <= mediumMax) {
            selectedProfile = 'medium'
        } else {
            selectedProfile = 'large'
        }
    }

    if (!profiles.containsKey(selectedProfile)) {
        throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: resolved profile '${selectedProfile}' is not defined under stage3_variant_discovery.profiles")
    }

    def selected = mapOrEmpty(profiles[selectedProfile])
    def heavyCpus = Math.max(1, toIntSafe(selected.variant_heavy_cpus, fallback.variant_heavy_cpus))
    def mediumCpus = Math.max(1, toIntSafe(selected.process_medium_cpus, fallback.process_medium_cpus))
    def heavyMemGb = Math.max(4, toIntSafe(selected.variant_heavy_memory_gb, fallback.variant_heavy_memory_gb))
    def mediumMemGb = Math.max(4, toIntSafe(selected.process_medium_memory_gb, fallback.process_medium_memory_gb))
    def maxParallel = Math.max(1, toIntSafe(selected.max_parallel_branches, fallback.max_parallel_branches))

    if (heavyCpus > availableCpus) {
        heavyCpus = availableCpus
    }
    if (mediumCpus > availableCpus) {
        mediumCpus = availableCpus
    }
    if (maxParallel > 6) {
        maxParallel = 6
    }

    return [
        selected_profile: selectedProfile,
        available_cpus: availableCpus,
        available_memory_gb: availableMemGb,
        variant_heavy_cpus: heavyCpus,
        process_medium_cpus: mediumCpus,
        variant_heavy_memory_gb: heavyMemGb,
        process_medium_memory_gb: mediumMemGb,
        max_parallel_branches: maxParallel,
    ]
}

def applyStage3InfrastructurePolicy(Map infrastructureParsed) {
    def resolved = resolveStage3InfrastructurePolicy(infrastructureParsed)

    params.infrastructure_profile = params.infrastructure_profile ?: resolved.selected_profile
    params.stage3_variant_heavy_default_cpus = coerceIntOrFallback(params.stage3_variant_heavy_default_cpus, resolved.variant_heavy_cpus as int)
    params.stage3_process_medium_default_cpus = coerceIntOrFallback(params.stage3_process_medium_default_cpus, resolved.process_medium_cpus as int)
    params.stage3_variant_heavy_memory_gb = coerceIntOrFallback(params.stage3_variant_heavy_memory_gb, resolved.variant_heavy_memory_gb as int)
    params.stage3_process_medium_memory_gb = coerceIntOrFallback(params.stage3_process_medium_memory_gb, resolved.process_medium_memory_gb as int)
    params.stage3_max_parallel_branches = coerceIntOrFallback(params.stage3_max_parallel_branches, resolved.max_parallel_branches as int)

    log.info("STAGE3_INFRA: profile=${params.infrastructure_profile}; available_cpus=${resolved.available_cpus}; available_memory_gb=${resolved.available_memory_gb}; variant_heavy_cpus=${params.stage3_variant_heavy_default_cpus}; process_medium_cpus=${params.stage3_process_medium_default_cpus}; max_parallel_branches=${params.stage3_max_parallel_branches}")
}

workflow STAGE3_VARIANT_DISCOVERY_ENGINE {
    take:
    ch_snv_indel_inputs
    ch_structural_variant_inputs
    ch_copy_number_cnv_inputs
    ch_str_expansion_inputs
    ch_trisomy_aneuploidy_inputs
    ch_homologous_pseudogene_inputs

    main:
    def snvCaller = (params.stage3_snv_caller ?: 'deepvariant').toString().trim().toLowerCase()
    if (!['deepvariant', 'bcftools'].contains(snvCaller)) {
        throw new IllegalArgumentException("STAGE3_PRECONDITION_FAILURE: unsupported stage3_snv_caller '${snvCaller}'. Allowed: deepvariant, bcftools")
    }

    def ch_snv_outputs = channel.empty()
    if (snvCaller == 'deepvariant') {
        STAGE3_SNV_INDEL_DEEPVARIANT(ch_snv_indel_inputs)
        ch_snv_outputs = STAGE3_SNV_INDEL_DEEPVARIANT.out.calibrated_vcf
    } else {
        STAGE3_SNV_INDEL(ch_snv_indel_inputs)
        ch_snv_outputs = STAGE3_SNV_INDEL.out.calibrated_vcf
    }

    STAGE3_STRUCTURAL_VARIANTS(ch_structural_variant_inputs)
    STAGE3_COPY_NUMBER_CNV(ch_copy_number_cnv_inputs)
    STAGE3_STR_EXPANSIONS(ch_str_expansion_inputs)
    STAGE3_TRISOMY_ANEUPLOIDY(ch_trisomy_aneuploidy_inputs)
    STAGE3_HOMOLOGOUS_PSEUDOGENES(ch_homologous_pseudogene_inputs)

    def ch_discovery_outputs = ch_snv_outputs
        .map { sid, vcf, calibrationAudit, refs, meta -> tuple(sid, 'snv_indel', vcf, calibrationAudit, refs, meta) }
        .mix(STAGE3_STRUCTURAL_VARIANTS.out.calibrated_vcf.map { sid, vcf, calibrationAudit, refs, meta -> tuple(sid, 'structural_variants', vcf, calibrationAudit, refs, meta) })
        .mix(STAGE3_COPY_NUMBER_CNV.out.calibrated_vcf.map { sid, vcf, calibrationAudit, refs, meta -> tuple(sid, 'copy_number_cnv', vcf, calibrationAudit, refs, meta) })
        .mix(STAGE3_STR_EXPANSIONS.out.calibrated_vcf.map { sid, vcf, calibrationAudit, refs, meta -> tuple(sid, 'str_expansions', vcf, calibrationAudit, refs, meta) })
        .mix(STAGE3_TRISOMY_ANEUPLOIDY.out.calibrated_vcf.map { sid, vcf, calibrationAudit, refs, meta -> tuple(sid, 'trisomy_aneuploidy', vcf, calibrationAudit, refs, meta) })
        .mix(STAGE3_HOMOLOGOUS_PSEUDOGENES.out.calibrated_vcf.map { sid, vcf, calibrationAudit, refs, meta -> tuple(sid, 'homologous_pseudogenes', vcf, calibrationAudit, refs, meta) })

    def ch_mane_inputs = ch_discovery_outputs.map { sid, branchName, vcf, calibrationAudit, refs, meta ->
        tuple(sid, branchName, vcf, calibrationAudit, file(refs.mane_transcripts.toString()), file(refs.stage3_vcf_schema.toString()), refs, meta)
    }
    MANE_TRANSCRIPT_SELECTOR(ch_mane_inputs)

    def ch_merge_inputs = MANE_TRANSCRIPT_SELECTOR.out.selected_vcf
        .map { sid, branchName, selectedVcf, maneAudit, vcfSchema, refs, meta, calibrationAudit ->
            tuple(sid, branchName, vcfSchema, refs, meta, selectedVcf, maneAudit, calibrationAudit)
        }
        .groupTuple()
        .map { sid, branchNames, schemas, refsList, metas, selectedVcfs, maneAudits, calibrationAudits ->
            def schemaPath = schemas[0]
            def refsValue = refsList[0]
            def metaValue = metas[0]
            tuple(sid, branchNames, selectedVcfs, maneAudits, calibrationAudits, schemaPath, refsValue, metaValue)
        }

    MERGE_STAGE3_BRANCH_VCFS(ch_merge_inputs)
    MASTER_HARMONIZED_VCF_PAYLOAD(MERGE_STAGE3_BRANCH_VCFS.out.merged_vcf_bundle)

    def ch_branch_matrix = ch_merge_inputs.map { sid, branchNames, selectedVcfs, _maneAudits, _calibrationAudits, _schemaPath, _refsValue, _metaValue ->
        tuple(sid, branchNames, selectedVcfs)
    }

    def ch_merge_payload = MERGE_STAGE3_BRANCH_VCFS.out.merged_vcf_bundle
        .map { sid, mergedVcf, _mergedManeAudit, _vcfSchema, _refsValue, _metaValue, _mergedCalibrationAudit ->
            tuple(sid, mergedVcf)
        }

    def ch_master_payload = MASTER_HARMONIZED_VCF_PAYLOAD.out.harmonized
        .map { sid, normalizedVcf, harmonizationAudit, fragment ->
            tuple(sid, normalizedVcf, harmonizationAudit, fragment)
        }

    def ch_master_tbi = MASTER_HARMONIZED_VCF_PAYLOAD.out.normalized_tbi

    def ch_zero_loss_inputs = ch_branch_matrix
        .join(ch_merge_payload)
        .join(ch_master_payload)
        .join(ch_master_tbi)
        .map { sid, branchNames, selectedVcfs, mergedVcf, normalizedVcf, harmonizationAudit, fragment, normalizedTbi ->
            tuple(sid, branchNames, selectedVcfs, mergedVcf, normalizedVcf, normalizedTbi, harmonizationAudit, fragment)
        }

    STAGE3_ZERO_LOSS_GATE_MANIFEST(ch_zero_loss_inputs)

    emit:
    snv_indel_vcf = MASTER_HARMONIZED_VCF_PAYLOAD.out.harmonized.map { sid, vcf, _audit, _fragment -> tuple(sid, vcf) }
    snv_indel_audit = MASTER_HARMONIZED_VCF_PAYLOAD.out.harmonized.map { sid, _vcf, audit, _fragment -> tuple(sid, audit) }
    stage3_manifest = STAGE3_ZERO_LOSS_GATE_MANIFEST.out.banked_manifest
}

workflow STAGE3_VARIANT_DISCOVERY {
    main:
    def ys = new groovy.yaml.YamlSlurper()
    def stage2Manifest = file((params.input ?: params.samples).toString())
    if (!stage2Manifest.exists()) {
        throw new IllegalArgumentException('STAGE3_PRECONDITION_FAILURE: missing Stage 2 banked manifest')
    }
    def referencesFile = resolveStageConfigPath(readOptionalParam('ref_config'), params.references, 'references.yaml')
    def thresholdsFile = resolveStageConfigPath(readOptionalParam('thresh_config'), params.thresholds, 'thresholds.yaml')
    def infrastructureFile = resolveStageConfigPath(readOptionalParam('infra_config'), params.infrastructure, 'infrastructure.yaml')
    def referenceInfo = loadResolvedReferences(referencesFile)
    def refsParsed = referenceInfo.refs
    def refsFromParams = mapOrEmpty(params.refs)
    def refsCombined = refsFromParams + refsParsed
    def thresholdsParsed = mapOrEmpty(ys.parse(thresholdsFile))
    def clinicalThresholds = mapOrEmpty(thresholdsParsed.clinical)
    def discoveryThresholds = mapOrEmpty(clinicalThresholds.discovery)
    def infrastructureParsed = ys.parse(infrastructureFile) ?: [:]
    applyStage3InfrastructurePolicy(mapOrEmpty(infrastructureParsed))
    def infrastructureRoot = infrastructureFile.parent ? infrastructureFile.parent.toString() : projectDir.toString()
    def refDir = null
    [params.ref_data_root, params.ref_dir, infrastructureParsed?.storage?.reference_host_root, referenceInfo.yamlRefDataRoot, '/opt/reference'].find { candidate ->
        def text = candidate?.toString()?.trim()
        if (!text) {
            return false
        }
        def resolved = resolveHostPath(text, infrastructureRoot)
        refDir = resolved.toString()
        new File(resolved.toString()).exists()
    }

    def stage3Refs = [
        reference_genome  : refsCombined.reference_genome ?: refsCombined.grch38_fasta ?: refsCombined.fasta,
        capture_wes_bed   : refsCombined.capture_wes_bed ?: refsCombined.onco_target_bed ?: refsCombined.target_bed_onco,
        onco_target_bed   : refsCombined.onco_target_bed ?: refsCombined.capture_wes_bed ?: refsCombined.target_bed_onco,
        mane_transcripts  : refsCombined.mane_transcripts ?: refsCombined.clinical?.mane_transcripts ?: refsCombined.mane_db ?: refsCombined.target_bed_mane,
        stage3_vcf_schema : refsCombined.stage3_vcf_schema ?: refsCombined.stage3?.stage3_vcf_schema,
        cnvkit_pooled_reference: refsCombined.cnvkit_pooled_reference ?: refsCombined.cnvkit_wgs_flat_ref ?: refsCombined.stage3?.cnvkit_pooled_reference,
        expansionhunter_catalog: refsCombined.expansionhunter_catalog ?: refsCombined.expansionhunter_variant_catalog ?: refsCombined.stage3?.expansionhunter_catalog ?: refsCombined.stage3?.expansionhunter_variant_catalog,
        pseudogene_mask        : refsCombined.pseudogene_mask ?: refsCombined.cyp2d6_paralog_mask_bed ?: refsCombined.paralog_safe_regions ?: refsCombined.stage3?.pseudogene_mask,
    ]

    ['reference_genome', 'mane_transcripts', 'stage3_vcf_schema'].each { key ->
        def value = stage3Refs[key]
        if (!value) {
            throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}'")
        }
        def resolved = resolveHostPath(value, refDir)
        if (!new File(resolved).exists()) {
            throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}=${value}'")
        }
        stage3Refs[key] = resolved
    }

    ['capture_wes_bed', 'onco_target_bed'].each { key ->
        def value = stage3Refs[key]
        if (value) {
            stage3Refs[key] = resolveHostPath(value, refDir)
        }
    }

    def stage2Parsed = ys.parse(stage2Manifest)
    def records = stage2Parsed?.samples
    if (!(records instanceof List) || records.isEmpty()) {
        throw new IllegalStateException('STAGE3_PRECONDITION_FAILURE: Stage 2 banked manifest contains no samples')
    }
    def stage3TestMode = asBool(params.stage3_test_mode)

    def ch_samples = channel
        .from(records)
        .map { rec ->
            def sample = rec as Map
            def sampleId = (sample.sample_id ?: 'UNKNOWN').toString()
            def stage1AssetBase = [sample.stage1_asset_base_uri, sample.asset_base_uri].find { v -> v != null && v.toString().trim() }?.toString()
            def sortedBamRaw = [sample.sorted_bam, sample.sorted_bam_basename, sample.mapped_bam_basename, sample.mapped_bam].find { v -> v != null && v.toString().trim() }?.toString()
            def sortedBam = sortedBamRaw ? resolveStageAssetPath(sortedBamRaw, stage2Manifest.parent?.toString() ?: projectDir.toString(), stage1AssetBase) : null
            if (!sortedBam) {
                throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: sorted_bam missing for sample '${sampleId}'")
            }
            def sortedBaiRaw = [sample.sorted_bai, sample.sorted_bai_basename, sample.mapped_bai_basename, sample.mapped_bai, "${sortedBamRaw}.bai"].find { v -> v != null && v.toString().trim() }?.toString()
            def sortedBai = resolveStageAssetPath(sortedBaiRaw, stage2Manifest.parent?.toString() ?: projectDir.toString(), stage1AssetBase)
            def sequencingType = (([sample.sequencing_type, sample.seq_type, 'WES'].find { v -> v != null && v.toString().trim() }) ?: 'WES').toString().trim().toUpperCase()
            def isWgs = sequencingType == 'WGS'
            def sampleType = (sample.sample_type ?: 'germline').toString().toLowerCase()

            def sampleQcMeta = mapOrEmpty(sample.sample_qc_meta)
            sampleQcMeta = [
                estimated_in_silico_purity: sampleQcMeta.estimated_in_silico_purity ?: sample.estimated_in_silico_purity,
                contamination_rate        : sampleQcMeta.contamination_rate ?: sample.contamination_rate,
                computed_sex              : sampleQcMeta.computed_sex ?: sample.computed_sex ?: 'UNKNOWN',
                sex_concordance_pass      : sampleQcMeta.sex_concordance_pass ?: sample.sex_concordance_pass,
                purity_concordance_pass   : sampleQcMeta.purity_concordance_pass ?: sample.purity_concordance_pass,
            ]

            def refBuild = (sample.reference_build instanceof Map) ? (sample.reference_build as Map) : [:]
            def rawFasta = [refBuild.fasta, refBuild.reference_genome, refBuild.grch38_fasta, stage3Refs.reference_genome].find { v -> v != null && v.toString().trim() }
            if (!rawFasta) {
                throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET 'fasta' for sample '${sampleId}'")
            }
            def fastaHostPath = resolveHostPath(rawFasta, refDir)
            if (!new File(fastaHostPath).exists()) {
                throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET 'fasta=${rawFasta}' for sample '${sampleId}'")
            }
            def rawFastaFai = [refBuild.reference_fai, refBuild.fasta_fai, stage3Refs.reference_fai].find { v -> v != null && v.toString().trim() }
            if (!rawFastaFai) {
                throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET 'reference_fai' for sample '${sampleId}'")
            }
            def fastaFaiHostPath = resolveHostPath(rawFastaFai, refDir)
            if (!new File(fastaFaiHostPath).exists()) {
                throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET 'reference_fai=${rawFastaFai}' for sample '${sampleId}'")
            }

            def rawTargetBed = [sample.snv_mask_bed, sample.cnv_target_bed, refBuild.target_bed_onco, refBuild.onco_target_bed, refBuild.capture_wes_bed, stage3Refs.onco_target_bed, stage3Refs.capture_wes_bed].find { v -> v != null && v.toString().trim() }
            def targetBed = rawTargetBed ? rawTargetBed.toString() : null
            if (targetBed) {
                targetBed = resolveHostPath(targetBed, refDir)
            }

            def rawVariantBranches = (sample.variant_branches instanceof Map) ? (sample.variant_branches as Map) : [:]
            def supportedBranches = [
                'snv_indel',
                'structural_variants',
                'copy_number_cnv',
                'str_expansions',
                'trisomy_aneuploidy',
                'homologous_pseudogenes'
            ]
            def variantBranches = supportedBranches.collectEntries { branch ->
                [(branch): (rawVariantBranches[branch] ? true : false)]
            }
            def activeBranches = supportedBranches.findAll { branch -> variantBranches[branch] as boolean }
            if (activeBranches.isEmpty()) {
                throw new IllegalStateException("STAGE3_BRANCH_DISABLED: no active Stage 3 branches enabled for sample '${sampleId}'")
            }
            def unsupportedBranches = rawVariantBranches.keySet().findAll { branch -> !supportedBranches.contains(branch.toString()) }
            if (!unsupportedBranches.isEmpty()) {
                throw new IllegalStateException("STAGE3_BRANCH_NOT_IMPLEMENTED: sample '${sampleId}' requested unsupported branches ${unsupportedBranches}; currently supported branches: ${supportedBranches}")
            }
            def stage3BranchPlan = supportedBranches.collectEntries { branch ->
                def enabled = variantBranches[branch] as boolean
                [(branch): [
                    requested: enabled,
                    dispatch_token: enabled ? 'DISPATCH_REQUIRED' : 'SKIPPED_BY_MANIFEST'
                ]]
            }
            def requestedFaults = ((sample.stage3_faults instanceof Map) ? (sample.stage3_faults as Map) : [:])
            if (!stage3TestMode && !requestedFaults.isEmpty()) {
                throw new IllegalStateException("STAGE3_POLICY_VIOLATION: stage3_faults provided for sample '${sampleId}' while stage3_test_mode=false")
            }
            def effectiveFaults = stage3TestMode ? requestedFaults : [:]

            def upstreamToken = (sample.validation_token ?: sample.intake_validation_token_value ?: '').toString()
            if (!upstreamToken || !upstreamToken.contains('VALID_PASS')) {
                throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: invalid Stage 2 validation token for sample '${sampleId}'")
            }

            def preserved = new LinkedHashMap(sample)
            def sampleMeta = preserved + [
                sample_id       : sampleId,
                sample_type     : sampleType,
                sequencing_type : sequencingType,
                run_mode        : (sample.run_mode ?: 'production').toString(),
                validation_token: upstreamToken,
                stage2_contamination_status: (sample.stage2_contamination_status ?: '').toString(),
                stage2_contamination_policy_action: (sample.stage2_contamination_policy_action ?: '').toString(),
                stage3_discovery_thresholds: [
                    somatic_qual_floor      : discoveryThresholds.somatic_qual_floor,
                    germline_qual_floor     : discoveryThresholds.germline_qual_floor,
                    manta_min_rescue_score  : discoveryThresholds.manta_min_rescue_score,
                    large_indel_min_size_bp : discoveryThresholds.large_indel_min_size_bp,
                    cnv_log2_abs_floor      : discoveryThresholds.cnv_log2_abs_floor,
                    trisomy_ratio_threshold : discoveryThresholds.trisomy_ratio_threshold,
                    trisomy_z_threshold     : discoveryThresholds.trisomy_z_threshold,
                ],
                sorted_bam      : sortedBam,
                sorted_bai      : sortedBai,
                sorted_bam_basename: sample.sorted_bam_basename ?: new File(sortedBam).name,
                sorted_bai_basename: sample.sorted_bai_basename ?: new File(sortedBai).name,
                stage1_asset_base_uri: stage1AssetBase,
                asset_base_uri: stage1AssetBase,
                variant_branches: variantBranches,
                stage3_branch_plan: stage3BranchPlan,
                expected_active_branch_count: activeBranches.size(),
                reference_build : refBuild,
                stage3_faults   : effectiveFaults,
                stage3_test_mode: stage3TestMode,
            ]

            tuple(
                sampleId,
                stage2Manifest,
                file(sortedBam),
                file(sortedBai),
                isWgs,
                targetBed,
                file(fastaHostPath),
                file(fastaFaiHostPath),
                sampleQcMeta,
                stage3Refs,
                sampleMeta,
                variantBranches
            )
        }

    def ch_snv_indel_inputs = ch_samples
        .filter { row ->
            def branches = row[11] as Map
            return (branches?.snv_indel ?: false) as boolean
        }
        .map { row -> tuple(row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[9], row[10]) }

    def ch_structural_variant_inputs = ch_samples
        .filter { row ->
            def branches = row[11] as Map
            return (branches?.structural_variants ?: false) as boolean
        }
        .map { row -> tuple(row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[9], row[10]) }

    def ch_copy_number_cnv_inputs = ch_samples
        .filter { row ->
            def branches = row[11] as Map
            return (branches?.copy_number_cnv ?: false) as boolean
        }
        .map { row -> tuple(row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[9], row[10]) }

    def ch_str_expansion_inputs = ch_samples
        .filter { row ->
            def branches = row[11] as Map
            return (branches?.str_expansions ?: false) as boolean
        }
        .map { row -> tuple(row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[9], row[10]) }

    def ch_trisomy_aneuploidy_inputs = ch_samples
        .filter { row ->
            def branches = row[11] as Map
            return (branches?.trisomy_aneuploidy ?: false) as boolean
        }
        .map { row -> tuple(row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[9], row[10]) }

    def ch_homologous_pseudogene_inputs = ch_samples
        .filter { row ->
            def branches = row[11] as Map
            return (branches?.homologous_pseudogenes ?: false) as boolean
        }
        .map { row -> tuple(row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[9], row[10]) }

    STAGE3_VARIANT_DISCOVERY_ENGINE(
        ch_snv_indel_inputs,
        ch_structural_variant_inputs,
        ch_copy_number_cnv_inputs,
        ch_str_expansion_inputs,
        ch_trisomy_aneuploidy_inputs,
        ch_homologous_pseudogene_inputs
    )

    emit:
    stage3_manifest = STAGE3_VARIANT_DISCOVERY_ENGINE.out.stage3_manifest
}

workflow {
    STAGE3_VARIANT_DISCOVERY()
}
