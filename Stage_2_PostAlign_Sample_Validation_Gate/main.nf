nextflow.enable.dsl = 2

include { VALIDATE_STAGE1_PRECONDITION } from './modules/local/validate_stage1_precondition.nf'
include { VERIFYBAMID2 } from './modules/local/verify_bam_id2.nf'
include { VALIDATE_CHROMOSOMAL_SEX } from './modules/local/validate_chromosomal_sex.nf'
include { SPECIMEN_PARADIGM_PURITY_RESOLVER } from './modules/local/specimen_paradigm_purity_resolver.nf'
include { ASSAY_TARGET_ROUTER } from './modules/local/assay_target_router.nf'
include { BANK_STAGE2_CONTRACT } from './modules/local/bank_stage2_contract.nf'
include { ASSEMBLE_STAGE2_BANKED_MANIFEST } from './modules/local/assemble_stage2_banked_manifest.nf'

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
    if (candidate.isAbsolute()) {
        return candidate
    }

    def rooted = new File(rootDir, rawPath)
    if (rooted.exists()) {
        return rooted
    }

    def projectRelative = new File(projectDir.toString(), rawPath)
    if (projectRelative.exists()) {
        return projectRelative
    }

    def repoRelative = new File(projectDir.toString()).parentFile ? new File(new File(projectDir.toString()).parentFile, rawPath) : null
    if (repoRelative != null && repoRelative.exists()) {
        return repoRelative
    }

    return rooted
}

def resolveAssetPath(String rawPath, String rootDir, String baseUri = null) {
    if (!rawPath) {
        return null
    }
    def asGiven = resolvePath(rawPath, rootDir)
    if (asGiven.exists()) {
        return asGiven
    }
    if (baseUri) {
        def joined = resolvePath(new File(baseUri, rawPath).path, rootDir)
        if (joined.exists()) {
            return joined
        }
    }
    return asGiven
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

def normalizeSexToken(Object rawSex) {
    def sex = (rawSex ?: '').toString().trim().toUpperCase()
    if (['MALE', 'M', 'XY'].contains(sex)) {
        return 'XY'
    }
    if (['FEMALE', 'F', 'XX'].contains(sex)) {
        return 'XX'
    }
    return 'UNKNOWN'
}

def writeStage2Rejection(String outdir, String sampleId, String reason, String detail, Map extra = [:]) {
    def auditDir = new File("${outdir}/audit_and_qc/stage2")
    auditDir.mkdirs()
    def payload = [
        failure_code: 'STAGE2_PRECONDITION_FAILURE',
        sample_id: sampleId,
        reason: reason,
        detail: detail,
        timestamp_utc: new Date().format("yyyy-MM-dd'T'HH:mm:ssXXX")
    ] + extra
    new File(auditDir, "${sampleId}.stage2_rejection_audit.json").text = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(payload)) + '\n'
}

def buildStage2InputChannel() {
    def ys = new groovy.yaml.YamlSlurper()

    def samplesFilePath = (params.input ?: params.samples)?.toString()
    if (!samplesFilePath) {
        throw new IllegalArgumentException('STAGE2_PRECONDITION_FAILURE: missing --input Stage 1 banked manifest')
    }
    def samplesFile = file(samplesFilePath)
    if (!samplesFile.exists()) {
        throw new IllegalArgumentException("STAGE2_PRECONDITION_FAILURE: input manifest does not exist: ${samplesFilePath}")
    }

    def referencesFile = resolveStageConfigPath(readOptionalParam('ref_config'), params.references, 'references.yaml')
    def thresholdsFile = resolveStageConfigPath(readOptionalParam('thresh_config'), params.thresholds, 'thresholds.yaml')
    def infrastructureFile = resolveStageConfigPath(readOptionalParam('infra_config'), params.infrastructure, 'infrastructure.yaml')

    def samplesParsed = ys.parse(samplesFile).samples
    def referenceInfo = loadResolvedReferences(referencesFile)
    def refsParsed = referenceInfo.refs
    def thresholdsParsed = ys.parse(thresholdsFile)
    def infrastructureParsed = ys.parse(infrastructureFile) ?: [:]

    if (!(samplesParsed instanceof List) || samplesParsed.isEmpty()) {
        throw new IllegalArgumentException('STAGE2_PRECONDITION_FAILURE: samples manifest contains no samples')
    }

    // Contract-first merge: stage-local params.refs acts only as optional fallback
    // and must not override governed reference mappings from references.yaml.
    def refsFromParams = mapOrEmpty(params.refs)
    def refsCombined = refsFromParams + refsParsed
    def refsNormalized = mapOrEmpty(refsCombined) + [
        reference_genome: (refsCombined.reference_genome ?: refsCombined.grch38_fasta),
        reference_fai   : (refsCombined.reference_fai ?: refsCombined.grch38_fai),
        reference_dict  : (refsCombined.reference_dict ?: refsCombined.grch38_dict),
        capture_wes_bed : refsCombined.capture_wes_bed ?: refsCombined.onco_target_bed,
        onco_target_bed : refsCombined.onco_target_bed ?: refsCombined.capture_wes_bed,
        sf_bed          : refsCombined.sf_bed,
        reference_host_root: (referenceInfo.yamlRefDataRoot ?: ''),
        verifybamid2_svd_prefix: refsCombined.verifybamid2_svd_prefix,
        verifybamid2_ud_path: refsCombined.verifybamid2_ud_path,
        verifybamid2_bed: refsCombined.verifybamid2_bed
    ]

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
    [
        reference_genome: refsNormalized.reference_genome,
        reference_fai   : refsNormalized.reference_fai,
        reference_dict  : refsNormalized.reference_dict,
        onco_target_bed : refsNormalized.onco_target_bed,
        capture_wes_bed : refsNormalized.capture_wes_bed,
        sf_bed          : refsNormalized.sf_bed
    ].each { key, value ->
        if (!value) {
            writeStage2Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', key)
            throw new IllegalStateException("STAGE2_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}'")
        }
        def resolved = hostPathForReference(value.toString(), refDir)
        if (resolved == null || !resolved.exists()) {
            writeStage2Rejection(params.outdir.toString(), 'GLOBAL', 'MISSING_REFERENCE_ASSET', "${key}=${value}")
            throw new IllegalStateException("STAGE2_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}=${value}'")
        }
    }

    def samplesRoot = samplesFile.parent ? samplesFile.parent.toString() : projectDir.toString()
    def validTokenMarkers = ['VALID_PASS|INTAKE_VALIDATED', 'VALID_PASS|ALIGNMENT_COMPLETED']

    def sampleRows = samplesParsed.collect { sample ->
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        def stage1AssetBase = (sample.stage1_asset_base_uri ?: sample.asset_base_uri)?.toString()
        def mappedBamBasename = (sample.mapped_bam_basename ?: sample.mapped_bam)?.toString()
        def mappedBaiBasename = (sample.mapped_bai_basename ?: sample.mapped_bai)?.toString()
        def sortedBamRaw = (sample.sorted_bam ?: mappedBamBasename)?.toString()
        if (!sortedBamRaw) {
            writeStage2Rejection(params.outdir.toString(), sid, 'MISSING_SORTED_BAM', 'sample did not declare sorted_bam or mapped_bam')
            throw new IllegalStateException("STAGE2_PRECONDITION_FAILURE: sorted_bam/mapped_bam missing for sample '${sid}'")
        }
        def sortedBam = resolveAssetPath(sortedBamRaw, samplesRoot, stage1AssetBase)
        def sortedBaiRaw = (sample.sorted_bai ?: mappedBaiBasename ?: "${sortedBamRaw}.bai")?.toString()
        def sortedBai = resolveAssetPath(sortedBaiRaw, samplesRoot, stage1AssetBase)

        if (!sortedBam.exists() || !sortedBai.exists()) {
            writeStage2Rejection(params.outdir.toString(), sid, 'SORTED_BAM_OR_BAI_MISSING', "bam=${sortedBam}; bai=${sortedBai}")
            throw new IllegalStateException("STAGE2_PRECONDITION_FAILURE: sorted BAM/BAI missing for sample '${sid}'")
        }

        def tokenField = (sample.intake_validation_token ?: sample.validation_token)?.toString()
        if (!tokenField) {
            writeStage2Rejection(params.outdir.toString(), sid, 'MISSING_INTAKE_VALIDATION_TOKEN', 'intake_validation_token/validation_token missing from Stage 1 contract')
            throw new IllegalStateException("STAGE2_PRECONDITION_FAILURE: intake_validation_token missing for sample '${sid}'")
        }

        def tokenPath = resolvePath(tokenField, samplesRoot)
        def token = tokenPath.exists() ? tokenPath.text.trim() : tokenField.trim()
        if (!validTokenMarkers.any { marker -> token.contains(marker) }) {
            writeStage2Rejection(params.outdir.toString(), sid, 'INVALID_STAGE1_PRECONDITION_TOKEN', token)
            throw new IllegalStateException("STAGE2_PRECONDITION_FAILURE: invalid intake token for sample '${sid}' -> '${token}'")
        }

        def branchBranches = mapOrEmpty(sample.variant_branches)
        def branchCatalogRequired = (branchBranches.snv_indel ?: false) || (branchBranches.str_expansions ?: false)
        def targetCatalog = (sample.branch_target_catalog ?: refsNormalized.capture_wes_bed ?: refsNormalized.onco_target_bed)?.toString()
        def targetCatalogResolved = targetCatalog ? hostPathForReference(targetCatalog, refDir) : null
        if (branchCatalogRequired && (!targetCatalogResolved || !targetCatalogResolved.exists())) {
            writeStage2Rejection(params.outdir.toString(), sid, 'REJECT_MISSING_BRANCH_CATALOG', targetCatalog ?: 'missing')
            throw new IllegalStateException("STAGE2_PRECONDITION_FAILURE: REJECT_MISSING_BRANCH_CATALOG for sample '${sid}' -> ${targetCatalog ?: 'missing'}")
        }

        def baseMeta = buildMetaRow(sample as Map, params.outdir.toString()) + [
            intake_validation_token: sample.intake_validation_token ?: sample.validation_token,
            intake_validation_token_value: token,
            run_mode: (sample.run_mode ?: 'production').toString(),
            validation_token: 'VALID_PASS|SAMPLE_VALIDATED',
            stage1_asset_base_uri: stage1AssetBase,
            asset_base_uri: stage1AssetBase ?: sample.asset_base_uri,
            mapped_bam_basename: mappedBamBasename ? new File(mappedBamBasename).name : null,
            mapped_bai_basename: mappedBaiBasename ? new File(mappedBaiBasename).name : null,
            sorted_bam_basename: sortedBam ? sortedBam.name : null,
            sorted_bai_basename: sortedBai ? sortedBai.name : null
        ]

        tuple(
            baseMeta,
            file(sortedBam.toString()),
            file(sortedBai.toString()),
            refsNormalized,
            thresholdsParsed
        )
    }

    return channel.fromList(sampleRows)
}

def buildMetaRow(Map sample, String outdir) {
    def stage1AssetBase = sample.stage1_asset_base_uri ?: sample.asset_base_uri
    def sortedBam = sample.sorted_bam ?: sample.mapped_bam_basename ?: sample.mapped_bam
    def sortedBai = sample.sorted_bai ?: sample.mapped_bai_basename ?: sample.mapped_bai ?: (sortedBam ? "${sortedBam}.bai" : null)
    def preserved = new LinkedHashMap(sample)
    preserved + [
        sample_id: sample.sample_id,
        patient_id: sample.patient_id ?: sample.sample_id,
        case_id: sample.case_id ?: sample.patient_id ?: sample.sample_id,
        accession_id: sample.accession_id,
        encounter_id: sample.encounter_id,
        specimen_id: sample.specimen_id,
        analysis_batch_id: sample.analysis_batch_id,
        sample_type: sample.sample_type ?: 'germline',
        sequencing_type: (sample.sequencing_type ?: sample.assay_type ?: 'WES').toString().toUpperCase(),
        virtual_panel_bed: sample.virtual_panel_bed,
        pathologist_tumor_burden: sample.pathologist_tumor_burden ?: 0.0,
        physician_tumor_purity: sample.physician_tumor_purity ?: sample.pathologist_tumor_burden ?: 0.0,
        gender: sample.gender,
        reported_sex: normalizeSexToken(sample.reported_sex ?: sample.biological_context?.declared_sex ?: sample.gender),
        run_mode: (sample.run_mode ?: 'production').toString(),
        consent: mapOrEmpty(sample.consent),
        consent_tokens: mapOrEmpty(sample.consent_tokens),
        variant_branches: mapOrEmpty(sample.variant_branches),
        biological_context: mapOrEmpty(sample.biological_context),
        diagnosis: mapOrEmpty(sample.diagnosis),
        specimen: mapOrEmpty(sample.specimen),
        clinical_context: mapOrEmpty(sample.clinical_context),
        sequencer: mapOrEmpty(sample.sequencer),
        intake_validation_token: sample.intake_validation_token,
        intake_validation_report: sample.intake_validation_report,
        intake_route_decision: sample.intake_route_decision,
        stage0_audit_bundle: sample.stage0_audit_bundle,
        identity_audit: sample.identity_audit,
        mapped_bam: sample.mapped_bam,
        mapped_bai: sample.mapped_bai,
        mapped_bam_basename: sample.mapped_bam_basename ?: (sample.mapped_bam ? new File(sample.mapped_bam.toString()).name : null),
        mapped_bai_basename: sample.mapped_bai_basename ?: (sample.mapped_bai ? new File(sample.mapped_bai.toString()).name : null),
        stage1_asset_base_uri: stage1AssetBase,
        asset_base_uri: stage1AssetBase ?: sample.asset_base_uri,
        sorted_bam: sortedBam,
        sorted_bai: sortedBai,
        sorted_bam_basename: sample.sorted_bam_basename ?: (sortedBam ? new File(sortedBam.toString()).name : null),
        sorted_bai_basename: sample.sorted_bai_basename ?: (sortedBai ? new File(sortedBai.toString()).name : null),
        save_dir: outdir
    ]
}

workflow STAGE2_SAMPLE_VALIDATION {

    take:
    ch_stage2_input

    main:
    VALIDATE_STAGE1_PRECONDITION(ch_stage2_input)
    VERIFYBAMID2(VALIDATE_STAGE1_PRECONDITION.out.validated)
    VALIDATE_CHROMOSOMAL_SEX(VERIFYBAMID2.out.validated)
    SPECIMEN_PARADIGM_PURITY_RESOLVER(VALIDATE_CHROMOSOMAL_SEX.out.validated)
    ASSAY_TARGET_ROUTER(SPECIMEN_PARADIGM_PURITY_RESOLVER.out.validated)

    def ch_stage2_for_bank = ASSAY_TARGET_ROUTER.out.validated.map { meta, bam, bai, refs, thresholds, preAudit, contaminationAudit, purityAudit, routingJson, routerAudit ->
        def routePayload = new groovy.json.JsonSlurper().parseText(routingJson.text) as Map
        def enriched = meta + [
            snv_mask_bed: routePayload.snv_mask_bed,
            cnv_target_bed: routePayload.cnv_target_bed,
            sv_calling_enabled: routePayload.sv_calling_enabled,
            stage2_router_token: routePayload.stage2_router_token,
            variant_branches: routePayload.variant_branches ?: meta.variant_branches,
            stage2_precondition_audit: preAudit.toString(),
            contamination_audit: contaminationAudit.toString(),
            purity_and_sex_validation_audit: purityAudit.toString(),
            assay_target_router_audit: routerAudit.toString()
        ]
        tuple(enriched, bam, bai, refs, thresholds, preAudit, contaminationAudit, purityAudit, routerAudit)
    }

    BANK_STAGE2_CONTRACT(ch_stage2_for_bank)
    ASSEMBLE_STAGE2_BANKED_MANIFEST(BANK_STAGE2_CONTRACT.out.manifest_fragment.collect())

    emit:
    stage2_contract = ASSEMBLE_STAGE2_BANKED_MANIFEST.out.banked_manifest
}

workflow STAGE2_POSTALIGN_VALIDATION {
    main:
    STAGE2_SAMPLE_VALIDATION(buildStage2InputChannel())

    emit:
    stage2_contract = STAGE2_SAMPLE_VALIDATION.out.stage2_contract
}

workflow {
    STAGE2_POSTALIGN_VALIDATION()
}
