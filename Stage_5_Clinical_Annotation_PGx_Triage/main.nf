nextflow.enable.dsl = 2

include { VALIDATE_STAGE0_TOKEN } from './modules/local/validate_stage0_token.nf'
include { VALIDATE_STAGE5_REFERENCES } from './modules/local/validate_stage5_references.nf'
include { VALIDATE_STAGE5_CONTRACT } from './modules/local/validate_stage5_contract.nf'
include { ASSEMBLE_CLINICAL_BUNDLE } from './modules/local/assemble_clinical_bundle.nf'
include { SIGN_OFF_CLINICAL_BUNDLE } from './modules/local/sign_off_clinical_bundle.nf'
include { GERMLINE_BRANCH_ENGINE } from './subworkflows/local/germline_branch_engine.nf'
include { PGX_BRANCH_ENGINE } from './subworkflows/local/pgx_branch_engine.nf'
include { PRS_BRANCH_ENGINE } from './subworkflows/local/prs_branch_engine.nf'
include { SF_BRANCH_ENGINE } from './subworkflows/local/sf_branch_engine.nf'
include { SOMATIC_BRANCH_ENGINE } from './subworkflows/local/somatic_branch_engine.nf'

/*
 * Phase 2 skeleton: canonical Stage 5 DAG entrypoint with explicit branch routing.
 *
 * Contract assumption:
 * - ch_intake_payload yields tuple val(meta), path(vcf)
 * - meta.variant_branches contains boolean flags for:
 *   snv_indel, pgx, prs, sf, somatic
 */

boolean branchEnabled(Map meta, String branchName) {
    def raw = (meta?.variant_branches instanceof Map) ? meta.variant_branches[branchName] : null
    if (raw instanceof Boolean) {
        return raw
    }
    if (raw instanceof Number) {
        return raw.intValue() != 0
    }
    if (raw instanceof CharSequence) {
        def text = raw.toString().trim().toLowerCase()
        return ['1', 'true', 't', 'yes', 'y'].contains(text)
    }
    return false
}

Set<String> allowedStage5Branches() {
    ['germline', 'pgx', 'prs', 'sf', 'somatic'] as Set
}

Map mapOrEmpty(Object value) {
    value instanceof Map ? (value as Map) : [:]
}

File resolvePath(String rawPath, String rootDir) {
    def candidate = new File(rawPath)
    if (candidate.isAbsolute() || candidate.exists()) {
        return candidate.absoluteFile
    }

    def primary = new File(rootDir, rawPath)
    if (primary.exists()) {
        return primary.absoluteFile
    }

    def projectRelative = new File(projectDir.toString(), rawPath)
    if (projectRelative.exists()) {
        return projectRelative.absoluteFile
    }

    def repoRelative = new File(new File(projectDir.toString()).parentFile, rawPath)
    if (repoRelative.exists()) {
        return repoRelative.absoluteFile
    }

    def launchRoot = workflow.hasProperty('launchDir') ? workflow.launchDir?.toString() : null
    if (launchRoot) {
        def launchRelative = new File(launchRoot, rawPath)
        if (launchRelative.exists()) {
            return launchRelative.absoluteFile
        }
    }

    return primary.absoluteFile
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

    def primary = new File(projectDir.toString(), "../control_plane/${fileName}")
    if (primary.exists()) {
        return file(primary.path)
    }

    def launchRoot = workflow.hasProperty('launchDir') ? workflow.launchDir?.toString() : null
    if (launchRoot) {
        def launchFallback = new File(launchRoot, "control_plane/${fileName}")
        if (launchFallback.exists()) {
            return file(launchFallback.path)
        }
    }

    return configuredText ? file(configuredText) : file(primary.path)
}

String resolveGitCommitSha() {
    def explicit = params.git_commit_sha?.toString()?.trim()
    if (explicit) {
        return explicit
    }

    try {
        def repoRoot = new File(projectDir.toString()).parentFile
        def proc = ['git', '-C', repoRoot.toString(), 'rev-parse', '--short', 'HEAD'].execute()
        proc.waitFor()
        if (proc.exitValue() == 0) {
            def resolved = proc.in.text.trim()
            if (resolved) {
                return resolved
            }
        }
    } catch (Exception _ignored) {
    }

    throw new IllegalStateException('STAGE5_PRECONDITION_FAILURE: unable to resolve git_commit_sha; provide --git_commit_sha')
}

String sha256FileHex(File fileObj) {
    def digest = java.security.MessageDigest.getInstance('SHA-256')
    digest.update(fileObj.bytes)
    digest.digest().collect { byteValue -> String.format('%02x', byteValue) }.join()
}

String sha256Hex(String text) {
    def digest = java.security.MessageDigest.getInstance('SHA-256')
    byte[] bytes = digest.digest((text ?: '').getBytes('UTF-8'))
    bytes.collect { byteValue -> String.format('%02x', byteValue) }.join()
}

String skipTimestampUtc(Map meta) {
    def t = meta?.timestamp_utc?.toString()?.trim()
    if (t) {
        return t
    }
    return java.time.Instant.now().toString()
}

String skippedBranchPayload(Map _meta, String branchName) {
    def reportedContent
    if (branchName == 'germline') {
        reportedContent = [reported_variants: []]
    } else if (branchName == 'pgx') {
        reportedContent = [reported_calls: []]
    } else if (branchName == 'prs') {
        reportedContent = [score_payload: [
            raw_score: 0.0d,
            ancestry_adjusted_percentile: 0.0d,
            calibration_status: 'NOT_APPLICABLE',
            score_confidence_interval: [lower: 0.0d, upper: 0.0d],
            no_call_flag: true
        ]]
    } else if (branchName == 'sf') {
        reportedContent = [reported_variants: []]
    } else if (branchName == 'somatic') {
        reportedContent = [reported_variants: []]
    } else {
        throw new IllegalArgumentException("STAGE5_ROUTING_FAILURE: unsupported branch '${branchName}'")
    }

    def contentJson = groovy.json.JsonOutput.toJson(reportedContent)
    def payload = [
        summary: [
            status: 'SKIPPED_BY_CLINICAL_DIRECTIVE',
            reason: 'BRANCH_NOT_REQUESTED_IN_VARIANT_DIRECTIVE',
            input_variant_count: 0,
            reported_variant_count: 0,
            ruleset_version: 'skip-policy-v1',
            content_sha256: sha256Hex(contentJson)
        ]
    ] + reportedContent

    groovy.json.JsonOutput.toJson(payload)
}

List<String> normalizeRequestedBranches(Object rawBranches, String sampleId) {
    if (!(rawBranches instanceof List)) {
        throw new IllegalStateException("STAGE5_CONTROL_PLANE_FAILURE: requested_branches must be a list for sample '${sampleId}'")
    }

    def normalized = [] as List<String>
    def seen = [] as Set<String>
    (rawBranches as List).each { rawBranch ->
        def branchName = rawBranch?.toString()?.trim()?.toLowerCase()
        if (!branchName) {
            throw new IllegalStateException("STAGE5_CONTROL_PLANE_FAILURE: blank branch identifier in requested_branches for sample '${sampleId}'")
        }
        if (!allowedStage5Branches().contains(branchName)) {
            throw new IllegalStateException("STAGE5_CONTROL_PLANE_FAILURE: unrecognized branch identifier '${branchName}' for sample '${sampleId}'")
        }
        if (seen.contains(branchName)) {
            throw new IllegalStateException("STAGE5_CONTROL_PLANE_FAILURE: duplicate branch identifier '${branchName}' for sample '${sampleId}'")
        }
        seen << branchName
        normalized << branchName
    }

    normalized
}

Map buildBranchDirectiveFlags(List<String> requestedBranches) {
    [
        snv_indel: requestedBranches.contains('germline'),
        pgx: requestedBranches.contains('pgx'),
        prs: requestedBranches.contains('prs'),
        sf: requestedBranches.contains('sf'),
        somatic: requestedBranches.contains('somatic')
    ]
}

Map buildStage5Meta(Map sample, File manifestDir, def thresholdsFile, def referencesFile) {
    def sampleId = sample.sample_id?.toString()?.trim()
    if (!sampleId) {
        throw new IllegalStateException('STAGE5_PRECONDITION_FAILURE: sample_id is required for every Stage 4 manifest entry')
    }

    def thresholdsConfigFile = new File(thresholdsFile.toString())
    def referencesConfigFile = new File(referencesFile.toString())

    def phasedVcf = resolvePath(sample.phased_vcf?.toString(), manifestDir.toString())
    def phasedTbi = resolvePath(sample.phased_vcf_tbi?.toString(), manifestDir.toString())
    def ancestryMetrics = resolvePath(sample.ancestry_metrics_json?.toString(), manifestDir.toString())
    def phasingAudit = resolvePath(sample.phasing_audit_json?.toString(), manifestDir.toString())
    [phasedVcf, phasedTbi, ancestryMetrics, phasingAudit].each { asset ->
        if (!asset.exists()) {
            throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: missing required Stage 4 asset for sample '${sampleId}': ${asset}")
        }
    }

    def intakeTokenRaw = sample.intake_validation_token?.toString()?.trim()
    if (!intakeTokenRaw) {
        throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: missing intake_validation_token for sample '${sampleId}'")
    }
    def intakeTokenPath = resolvePath(intakeTokenRaw, manifestDir.toString())
    def intakeToken = intakeTokenPath.exists() ? intakeTokenPath.toString() : intakeTokenRaw

    def requestedBranches = normalizeRequestedBranches(sample.requested_branches, sampleId)
    def containerDigest = sample.container_digest?.toString()?.trim() ?: params.container_digest?.toString()?.trim()
    if (!containerDigest) {
        throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: container_digest is required for sample '${sampleId}' or via --container_digest")
    }

    def policyVersion = sample.policy_version?.toString()?.trim()
    if (!policyVersion) {
        policyVersion = "thresholds:${sha256FileHex(thresholdsConfigFile).substring(0, 12)}|references:${sha256FileHex(referencesConfigFile).substring(0, 12)}"
    }

    def timestampUtc = sample.timestamp_utc?.toString()?.trim() ?: java.time.Instant.now().toString()

    return new LinkedHashMap(sample) + [
        sample_id: sampleId,
        patient_id: sample.patient_id?.toString()?.trim() ?: sampleId,
        case_id: sample.case_id?.toString()?.trim() ?: (sample.patient_id?.toString()?.trim() ?: sampleId),
        phased_vcf: phasedVcf.toString(),
        phased_vcf_tbi: phasedTbi.toString(),
        ancestry_metrics_json: ancestryMetrics.toString(),
        phasing_audit_json: phasingAudit.toString(),
        intake_validation_token: intakeToken,
        requested_branches: requestedBranches,
        variant_branches: buildBranchDirectiveFlags(requestedBranches),
        git_commit_sha: sample.git_commit_sha?.toString()?.trim() ?: resolveGitCommitSha(),
        container_digest: containerDigest,
        policy_version: policyVersion,
        timestamp_utc: timestampUtc
    ]
}

workflow STAGE5_CLINICAL_TRIAGE {
    take:
    ch_intake_payload
    ch_thresholds_yaml
    ch_references_yaml
    ch_references_validated

    main:
    VALIDATE_STAGE0_TOKEN(ch_intake_payload)

    def chValidatedIntake = VALIDATE_STAGE0_TOKEN.out.validated_intake

    def ch_snv_indel = chValidatedIntake.filter { meta, _vcf -> branchEnabled(meta as Map, 'snv_indel') }
    def ch_pgx = chValidatedIntake.filter { meta, _vcf -> branchEnabled(meta as Map, 'pgx') }
    def ch_prs = chValidatedIntake.filter { meta, _vcf -> branchEnabled(meta as Map, 'prs') }
    def ch_sf = chValidatedIntake.filter { meta, _vcf -> branchEnabled(meta as Map, 'sf') }
    def ch_somatic = chValidatedIntake.filter { meta, _vcf -> branchEnabled(meta as Map, 'somatic') }

    def ch_skipped_snv_indel = chValidatedIntake
        .filter { meta, _vcf -> !branchEnabled(meta as Map, 'snv_indel') }
        .map { meta, _vcf ->
        def normalizedMeta = meta as Map
        tuple(normalizedMeta, 'SKIPPED_BY_CLINICAL_DIRECTIVE', skippedBranchPayload(normalizedMeta, 'germline'))
    }
    def ch_skipped_pgx = chValidatedIntake
        .filter { meta, _vcf -> !branchEnabled(meta as Map, 'pgx') }
        .map { meta, _vcf ->
        def normalizedMeta = meta as Map
        tuple(normalizedMeta, 'SKIPPED_BY_CLINICAL_DIRECTIVE', skippedBranchPayload(normalizedMeta, 'pgx'))
    }
    def ch_skipped_prs = chValidatedIntake
        .filter { meta, _vcf -> !branchEnabled(meta as Map, 'prs') }
        .map { meta, _vcf ->
        def normalizedMeta = meta as Map
        tuple(normalizedMeta, 'SKIPPED_BY_CLINICAL_DIRECTIVE', skippedBranchPayload(normalizedMeta, 'prs'))
    }
    def ch_skipped_sf = chValidatedIntake
        .filter { meta, _vcf -> !branchEnabled(meta as Map, 'sf') }
        .map { meta, _vcf ->
        def normalizedMeta = meta as Map
        tuple(normalizedMeta, 'SKIPPED_BY_CLINICAL_DIRECTIVE', skippedBranchPayload(normalizedMeta, 'sf'))
    }
    def ch_skipped_somatic = chValidatedIntake
        .filter { meta, _vcf -> !branchEnabled(meta as Map, 'somatic') }
        .map { meta, _vcf ->
        def normalizedMeta = meta as Map
        tuple(normalizedMeta, 'SKIPPED_BY_CLINICAL_DIRECTIVE', skippedBranchPayload(normalizedMeta, 'somatic'))
    }

    GERMLINE_BRANCH_ENGINE(ch_snv_indel, ch_thresholds_yaml, ch_references_yaml)
    PGX_BRANCH_ENGINE(ch_pgx, ch_thresholds_yaml, ch_references_yaml)
    PRS_BRANCH_ENGINE(ch_prs, ch_thresholds_yaml, ch_references_yaml, ch_references_validated)
    SF_BRANCH_ENGINE(ch_sf, ch_thresholds_yaml, ch_references_yaml, ch_references_validated)
    SOMATIC_BRANCH_ENGINE(ch_somatic, ch_thresholds_yaml, ch_references_yaml, ch_references_validated)

    def ch_germline_all = GERMLINE_BRANCH_ENGINE.out.branch_output.mix(ch_skipped_snv_indel)
    def ch_pgx_all = PGX_BRANCH_ENGINE.out.branch_output.mix(ch_skipped_pgx)
    def ch_prs_all = PRS_BRANCH_ENGINE.out.branch_output.mix(ch_skipped_prs)
    def ch_sf_all = SF_BRANCH_ENGINE.out.branch_output.mix(ch_skipped_sf)
    def ch_somatic_all = SOMATIC_BRANCH_ENGINE.out.branch_output.mix(ch_skipped_somatic)

    def ch_germline_keyed = ch_germline_all.map { meta, _status, payload -> tuple(meta.sample_id.toString(), meta, payload) }
    def ch_pgx_keyed = ch_pgx_all.map { meta, _status, payload -> tuple(meta.sample_id.toString(), meta, payload) }
    def ch_prs_keyed = ch_prs_all.map { meta, _status, payload -> tuple(meta.sample_id.toString(), meta, payload) }
    def ch_sf_keyed = ch_sf_all.map { meta, _status, payload -> tuple(meta.sample_id.toString(), meta, payload) }
    def ch_somatic_keyed = ch_somatic_all.map { meta, _status, payload -> tuple(meta.sample_id.toString(), meta, payload) }

    def chJoinedGermlinePgx = ch_germline_keyed
        .join(ch_pgx_keyed)
        .map { sampleId, meta1, germlinePayload, meta2, pgxPayload ->
            if (meta1.sample_id.toString() != meta2.sample_id.toString()) {
                throw new IllegalStateException("STAGE5_ROUTING_FAILURE: germline/pgx sample_id mismatch for key '${sampleId}'")
            }
            tuple(sampleId, meta1, germlinePayload, pgxPayload)
        }

    def chJoinedPrs = chJoinedGermlinePgx
        .join(ch_prs_keyed)
        .map { sampleId, meta1, germlinePayload, pgxPayload, metaPrs, prsPayload ->
            if (meta1.sample_id.toString() != metaPrs.sample_id.toString()) {
                throw new IllegalStateException("STAGE5_ROUTING_FAILURE: prs sample_id mismatch for key '${sampleId}'")
            }
            tuple(sampleId, meta1, germlinePayload, pgxPayload, prsPayload)
        }

    def chJoinedSf = chJoinedPrs
        .join(ch_sf_keyed)
        .map { sampleId, meta1, germlinePayload, pgxPayload, prsPayload, metaSf, sfPayload ->
            if (meta1.sample_id.toString() != metaSf.sample_id.toString()) {
                throw new IllegalStateException("STAGE5_ROUTING_FAILURE: sf sample_id mismatch for key '${sampleId}'")
            }
            tuple(sampleId, meta1, germlinePayload, pgxPayload, prsPayload, sfPayload)
        }

    def chBundleInput = chJoinedSf
        .join(ch_somatic_keyed)
        .map { sampleId, meta1, germlinePayload, pgxPayload, prsPayload, sfPayload, metaSomatic, somaticPayload ->
            if (meta1.sample_id.toString() != metaSomatic.sample_id.toString()) {
                throw new IllegalStateException("STAGE5_ROUTING_FAILURE: somatic sample_id mismatch for key '${sampleId}'")
            }
            tuple(meta1, germlinePayload, pgxPayload, prsPayload, sfPayload, somaticPayload)
        }

    ASSEMBLE_CLINICAL_BUNDLE(chBundleInput)

    def releaseGitCommitSha = resolveGitCommitSha()
    def releaseContainerDigest = params.container_digest?.toString()?.trim()
    if (!releaseContainerDigest) {
        throw new IllegalStateException('STAGE5_PRECONDITION_FAILURE: --container_digest is required for release sign-off')
    }

    def chSignOffInput = ASSEMBLE_CLINICAL_BUNDLE.out.clinical_bundle.map { meta, bundleJson ->
        tuple(meta.sample_id.toString(), bundleJson)
    }

    SIGN_OFF_CLINICAL_BUNDLE(chSignOffInput, channel.value(releaseGitCommitSha), channel.value(releaseContainerDigest))

    VALIDATE_STAGE5_CONTRACT(ASSEMBLE_CLINICAL_BUNDLE.out.clinical_bundle)

    emit:
    validated_bundle = VALIDATE_STAGE5_CONTRACT.out.validated_bundle
    production_release = SIGN_OFF_CLINICAL_BUNDLE.out.production_release
}

workflow {
    main:
    def inputPath = params.input?.toString()?.trim()
    if (!inputPath) {
        throw new IllegalStateException('STAGE5_PRECONDITION_FAILURE: --input is required and must reference a Stage 4 banked manifest')
    }

    def stage4ManifestFile = file(inputPath)
    if (!stage4ManifestFile.exists()) {
        throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: Stage 4 manifest not found: ${stage4ManifestFile}")
    }

    def thresholdsFile = resolveStageConfigPath(params.thresh_config, params.thresholds, 'thresholds.yaml')
    if (!thresholdsFile.exists()) {
        throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: thresholds config not found: ${thresholdsFile}")
    }

    def referencesFile = resolveStageConfigPath(params.ref_config, params.references, 'references.yaml')
    if (!referencesFile.exists()) {
        throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: references config not found: ${referencesFile}")
    }

    VALIDATE_STAGE5_REFERENCES(channel.value(referencesFile))
    def chReferencesValidated = VALIDATE_STAGE5_REFERENCES.out.validated_signal

    def manifest = mapOrEmpty(new groovy.yaml.YamlSlurper().parse(stage4ManifestFile))
    def samples = manifest.samples
    if (!(samples instanceof List) || samples.isEmpty()) {
        throw new IllegalStateException('STAGE5_PRECONDITION_FAILURE: Stage 4 manifest contains no samples')
    }

    def manifestDir = new File(stage4ManifestFile.toString()).parentFile ?: new File(projectDir.toString())
    def chIntakePayload = channel.fromList(samples).map { sample ->
        def meta = buildStage5Meta(sample as Map, manifestDir, thresholdsFile, referencesFile)
        tuple(meta, file(meta.phased_vcf.toString(), checkIfExists: true))
    }

    STAGE5_CLINICAL_TRIAGE(chIntakePayload, channel.value(thresholdsFile), channel.value(referencesFile), chReferencesValidated)
}
