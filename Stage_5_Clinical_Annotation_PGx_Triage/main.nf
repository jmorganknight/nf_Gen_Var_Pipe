nextflow.enable.dsl = 2

params.outdir = java.nio.file.Paths.get((params.outdir ?: 'tests/stage5').toString()).toAbsolutePath().normalize().toString()
params.stage5_outdir = java.nio.file.Paths.get((params.stage5_outdir ?: "${params.outdir}/Stage_5").toString()).toAbsolutePath().normalize().toString()

include { VALIDATE_STAGE0_TOKEN } from './modules/local/validate_stage0_token.nf'
include { VALIDATE_STAGE5_REFERENCES } from './modules/local/validate_stage5_references.nf'
include { VALIDATE_STAGE5_CONTRACT } from './modules/local/validate_stage5_contract.nf'
include { ASSEMBLE_CLINICAL_BUNDLE } from './modules/local/assemble_clinical_bundle.nf'
include { SIGN_OFF_CLINICAL_BUNDLE } from './modules/local/sign_off_clinical_bundle.nf'
include { ASSEMBLE_STAGE5_MANIFEST_FROM_RELEASE } from './modules/local/assemble_stage5_manifest_from_release.nf'
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

boolean asBool(Object rawValue, boolean defaultValue = false) {
    if (rawValue == null) {
        return defaultValue
    }
    if (rawValue instanceof Boolean) {
        return rawValue as boolean
    }
    if (rawValue instanceof Number) {
        return rawValue.intValue() != 0
    }
    def text = rawValue.toString().trim().toLowerCase()
    if (!text) {
        return defaultValue
    }
    if (['1', 'true', 't', 'yes', 'y', 'on'].contains(text)) {
        return true
    }
    if (['0', 'false', 'f', 'no', 'n', 'off'].contains(text)) {
        return false
    }
    return defaultValue
}

Set<String> allowedStage5Branches() {
    ['germline', 'pgx', 'prs', 'sf', 'somatic'] as Set
}

Map mapOrEmpty(Object value) {
    value instanceof Map ? (value as Map) : [:]
}

def readOptionalParam(String paramName) {
    params.containsKey(paramName) ? params[paramName] : null
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

String requireNestedString(Map root, List<String> pathParts, String failurePrefix) {
    def current = root
    pathParts.each { key ->
        if (!(current instanceof Map) || !current.containsKey(key)) {
            throw new IllegalStateException("${failurePrefix}: missing required governance key ${pathParts.join('.')}")
        }
        current = current[key]
    }
    def text = current?.toString()?.trim()
    if (!text) {
        throw new IllegalStateException("${failurePrefix}: governance key ${pathParts.join('.')} must be a non-empty string")
    }
    return text
}

File resolveGovernedAssetPath(String rawPath, File anchorFile = null) {
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

Map resolveStage5SignerPolicy(File thresholdsFile) {
    def thresholdsDoc = mapOrEmpty(new groovy.yaml.YamlSlurper().parse(thresholdsFile))
    def reporting = mapOrEmpty(mapOrEmpty(thresholdsDoc.clinical).reporting)

    def rawKeyPath = readOptionalParam('signer_key_path')?.toString()?.trim() ?: reporting.pki_key_path?.toString()?.trim()
    def rawPubPath = readOptionalParam('signer_pub_path')?.toString()?.trim() ?: reporting.pki_pub_key_path?.toString()?.trim()
    if (!rawKeyPath) {
        throw new IllegalStateException('STAGE5_PRECONDITION_FAILURE: missing governed signer private-key path (reporting.pki_key_path or --signer_key_path)')
    }
    if (!rawPubPath) {
        throw new IllegalStateException('STAGE5_PRECONDITION_FAILURE: missing governed signer public-key path (reporting.pki_pub_key_path or --signer_pub_path)')
    }

    def keyFile = resolveGovernedAssetPath(rawKeyPath, thresholdsFile)
    def pubFile = resolveGovernedAssetPath(rawPubPath, thresholdsFile)
    if (!keyFile.exists() || !keyFile.isFile()) {
        throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: signer private key not found: ${keyFile}")
    }
    if (!pubFile.exists() || !pubFile.isFile()) {
        throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: signer public key not found: ${pubFile}")
    }

    def signerScope = readOptionalParam('signer_scope')?.toString()?.trim() ?: reporting.pki_signer_scope?.toString()?.trim() ?: 'bootstrap'
    def signerId = readOptionalParam('signer_id')?.toString()?.trim() ?: reporting.pki_signer_id?.toString()?.trim() ?: "${signerScope}-signer"
    def allowBootstrapRaw = readOptionalParam('allow_bootstrap_for_production_run')
    def allowBootstrap = allowBootstrapRaw != null
        ? asBool(allowBootstrapRaw, false)
        : asBool(reporting.allow_bootstrap_for_production_run, false)

    [
        key_file: keyFile.absoluteFile,
        pub_file: pubFile.absoluteFile,
        signer_scope: signerScope,
        signer_id: signerId,
        allow_bootstrap_for_production_run: allowBootstrap,
    ]
}

File resolveReferenceAssetPath(String rawPath, String refDataRoot, File referencesFile) {
    def candidate = new File(rawPath)
    if (candidate.isAbsolute()) {
        return candidate.absoluteFile
    }
    if (candidate.exists()) {
        return candidate.absoluteFile
    }

    def roots = [] as List<File>
    if (refDataRoot?.trim()) {
        roots << new File(refDataRoot)
    }
    if (referencesFile?.parentFile != null) {
        roots << referencesFile.parentFile
    }
    roots << new File(projectDir.toString())
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
    return refDataRoot?.trim() ? new File(refDataRoot, rawPath).absoluteFile : candidate.absoluteFile
}

List<File> collectStage5ReferenceAssets(File referencesFile) {
    def refsDoc = mapOrEmpty(new groovy.yaml.YamlSlurper().parse(referencesFile))
    def refDataRoot = refsDoc.ref_data_root?.toString()?.trim() ?: ''
    def requiredRawPaths = [
        requireNestedString(refsDoc, ['references', 'sf', 'acmg_registry_json'], 'STAGE5_PRECONDITION_FAILURE'),
        requireNestedString(refsDoc, ['references', 'somatic', 'hotspots_bed'], 'STAGE5_PRECONDITION_FAILURE'),
        requireNestedString(refsDoc, ['references', 'prs', 'marker_weights_tsv'], 'STAGE5_PRECONDITION_FAILURE'),
        requireNestedString(refsDoc, ['references', 'stage3', 'stage3_vcf_schema'], 'STAGE5_PRECONDITION_FAILURE')
    ]

    requiredRawPaths.collect { rawPath ->
        def resolved = resolveReferenceAssetPath(rawPath, refDataRoot, referencesFile)
        if (!resolved.exists() || !resolved.isFile()) {
            throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: required reference asset not found: ${resolved}")
        }
        resolved
    }.unique { fileObj -> fileObj.absolutePath }
}

String resolveGitCommitSha() {
    def explicit = readOptionalParam('git_commit_sha')?.toString()?.trim()
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

String skippedBranchPayload(Map _meta, String branchName, String skipReason = 'BRANCH_NOT_REQUESTED_IN_VARIANT_DIRECTIVE') {
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
            reason: skipReason,
            input_variant_count: 0,
            reported_variant_count: 0,
            ruleset_version: 'skip-policy-v1',
            content_sha256: sha256Hex(contentJson)
        ]
    ] + reportedContent

    groovy.json.JsonOutput.toJson(payload)
}

Map resolveConsentMap(Map sample) {
    def candidates = [
        mapOrEmpty(sample.consent),
        mapOrEmpty(sample.stage0_consent_tokens),
        mapOrEmpty(sample.consent_tokens)
    ]
    def selected = candidates.find { cand -> !cand.isEmpty() } ?: [:]
    selected as Map
}

Map deriveBranchTogglePolicy(Map consent) {
    def runGermline = asBool(consent.run_germline, true)
    def runPgx = asBool(consent.run_pgx, true)
    def runPrsRequested = asBool(consent.run_prs, true)
    def runSfRequested = asBool(consent.run_secondary_findings, true)
    def runSomatic = asBool(consent.run_somatic, false)

    def prsOptIn = asBool(consent.prs_opt_in, false)
    def sfOptIn = asBool(consent.sf_opt_in, false)

    def runPrs = runPrsRequested && prsOptIn
    def runSf = runSfRequested && sfOptIn

    def requestedBranches = [] as List<String>
    if (runGermline) requestedBranches << 'germline'
    if (runPgx) requestedBranches << 'pgx'
    if (runPrsRequested) requestedBranches << 'prs'
    if (runSfRequested) requestedBranches << 'sf'
    if (runSomatic) requestedBranches << 'somatic'

    def effectiveBranches = [] as List<String>
    if (runGermline) effectiveBranches << 'germline'
    if (runPgx) effectiveBranches << 'pgx'
    if (runPrs) effectiveBranches << 'prs'
    if (runSf) effectiveBranches << 'sf'
    if (runSomatic) effectiveBranches << 'somatic'

    def skipReasons = [
        germline: runGermline ? '' : 'RUN_GERMLINE_DISABLED_BY_CONSENT_TOGGLE',
        pgx     : runPgx ? '' : 'RUN_PGX_DISABLED_BY_CONSENT_TOGGLE',
        prs     : runPrs ? '' : (runPrsRequested ? 'RUN_PRS_BLOCKED_BY_OPT_IN_POLICY' : 'RUN_PRS_DISABLED_BY_CONSENT_TOGGLE'),
        sf      : runSf ? '' : (runSfRequested ? 'RUN_SECONDARY_FINDINGS_BLOCKED_BY_OPT_IN_POLICY' : 'RUN_SECONDARY_FINDINGS_DISABLED_BY_CONSENT_TOGGLE'),
        somatic : runSomatic ? '' : 'RUN_SOMATIC_DISABLED_BY_CONSENT_TOGGLE'
    ]

    [
        requested_branches: requestedBranches,
        effective_branches: effectiveBranches,
        skip_reasons: skipReasons,
        prs_opt_in: prsOptIn,
        sf_opt_in: sfOptIn
    ]
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

Map buildStage5Meta(Map sample, File manifestDir, def thresholdsFile, def referencesFile, def infrastructureFile) {
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

    def consent = resolveConsentMap(sample)
    def branchPolicy = deriveBranchTogglePolicy(consent)
    def requestedBranches = branchPolicy.requested_branches as List<String>
    def effectiveBranches = branchPolicy.effective_branches as List<String>
    def containerDigest = sample.container_digest?.toString()?.trim() ?: readOptionalParam('container_digest')?.toString()?.trim()
    if (!containerDigest && infrastructureFile != null) {
        def infraFile = infrastructureFile instanceof File ? infrastructureFile : new File(infrastructureFile.toString())
        if (infraFile.exists()) {
            def infraDoc = mapOrEmpty(new groovy.yaml.YamlSlurper().parse(infraFile))
            def containers = mapOrEmpty(infraDoc.containers)
            containerDigest = containers?.annotation?.digest?.toString()?.trim() ?: containers?.reporting?.digest?.toString()?.trim()
        }
    }
    if (!containerDigest) {
        throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: container_digest is required for sample '${sampleId}', via --container_digest, or from control_plane/infrastructure.yaml")
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
        consent: consent,
        consent_tokens: consent,
        stage0_consent_tokens: consent,
        requested_branches: requestedBranches,
        effective_requested_branches: effectiveBranches,
        branch_skip_reasons: branchPolicy.skip_reasons,
        variant_branches: buildBranchDirectiveFlags(effectiveBranches),
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
    ch_reference_assets
    ch_references_validated
    ch_signer_private_key
    ch_signer_public_key
    ch_signer_policy
    _ch_infrastructure_yaml
    _ch_container_digest

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
        def reason = mapOrEmpty(normalizedMeta.branch_skip_reasons).germline?.toString() ?: 'BRANCH_NOT_REQUESTED_IN_VARIANT_DIRECTIVE'
        tuple(normalizedMeta, 'SKIPPED_BY_CLINICAL_DIRECTIVE', skippedBranchPayload(normalizedMeta, 'germline', reason))
    }
    def ch_skipped_pgx = chValidatedIntake
        .filter { meta, _vcf -> !branchEnabled(meta as Map, 'pgx') }
        .map { meta, _vcf ->
        def normalizedMeta = meta as Map
        def reason = mapOrEmpty(normalizedMeta.branch_skip_reasons).pgx?.toString() ?: 'BRANCH_NOT_REQUESTED_IN_VARIANT_DIRECTIVE'
        tuple(normalizedMeta, 'SKIPPED_BY_CLINICAL_DIRECTIVE', skippedBranchPayload(normalizedMeta, 'pgx', reason))
    }
    def ch_skipped_prs = chValidatedIntake
        .filter { meta, _vcf -> !branchEnabled(meta as Map, 'prs') }
        .map { meta, _vcf ->
        def normalizedMeta = meta as Map
        def reason = mapOrEmpty(normalizedMeta.branch_skip_reasons).prs?.toString() ?: 'BRANCH_NOT_REQUESTED_IN_VARIANT_DIRECTIVE'
        tuple(normalizedMeta, 'SKIPPED_BY_CLINICAL_DIRECTIVE', skippedBranchPayload(normalizedMeta, 'prs', reason))
    }
    def ch_skipped_sf = chValidatedIntake
        .filter { meta, _vcf -> !branchEnabled(meta as Map, 'sf') }
        .map { meta, _vcf ->
        def normalizedMeta = meta as Map
        def reason = mapOrEmpty(normalizedMeta.branch_skip_reasons).sf?.toString() ?: 'BRANCH_NOT_REQUESTED_IN_VARIANT_DIRECTIVE'
        tuple(normalizedMeta, 'SKIPPED_BY_CLINICAL_DIRECTIVE', skippedBranchPayload(normalizedMeta, 'sf', reason))
    }
    def ch_skipped_somatic = chValidatedIntake
        .filter { meta, _vcf -> !branchEnabled(meta as Map, 'somatic') }
        .map { meta, _vcf ->
        def normalizedMeta = meta as Map
        def reason = mapOrEmpty(normalizedMeta.branch_skip_reasons).somatic?.toString() ?: 'BRANCH_NOT_REQUESTED_IN_VARIANT_DIRECTIVE'
        tuple(normalizedMeta, 'SKIPPED_BY_CLINICAL_DIRECTIVE', skippedBranchPayload(normalizedMeta, 'somatic', reason))
    }

    GERMLINE_BRANCH_ENGINE(ch_snv_indel, ch_thresholds_yaml, ch_references_yaml)
    PGX_BRANCH_ENGINE(ch_pgx, ch_thresholds_yaml, ch_references_yaml)
    PRS_BRANCH_ENGINE(ch_prs, ch_thresholds_yaml, ch_references_yaml, ch_reference_assets, ch_references_validated)
    SF_BRANCH_ENGINE(ch_sf, ch_thresholds_yaml, ch_references_yaml, ch_reference_assets, ch_references_validated)
    SOMATIC_BRANCH_ENGINE(ch_somatic, ch_thresholds_yaml, ch_references_yaml, ch_reference_assets, ch_references_validated)

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

    def chSignOffMeta = ASSEMBLE_CLINICAL_BUNDLE.out.clinical_bundle.map { meta, _bundleJson -> meta }
    def chSignOffSampleId = ASSEMBLE_CLINICAL_BUNDLE.out.clinical_bundle.map { meta, _bundleJson -> meta.sample_id.toString() }
    def chSignOffBundleJson = ASSEMBLE_CLINICAL_BUNDLE.out.clinical_bundle.map { _meta, bundleJson -> bundleJson }

    SIGN_OFF_CLINICAL_BUNDLE(chSignOffMeta, chSignOffSampleId, chSignOffBundleJson, ch_signer_private_key, ch_signer_public_key, ch_signer_policy)

    VALIDATE_STAGE5_CONTRACT(ASSEMBLE_CLINICAL_BUNDLE.out.clinical_bundle)

    def chManifestInput = SIGN_OFF_CLINICAL_BUNDLE.out.production_release.map { meta, releaseJson, _sha256, _bundleTarGz, _provenanceJson ->
        tuple(meta.sample_id.toString(), releaseJson)
    }

    ASSEMBLE_STAGE5_MANIFEST_FROM_RELEASE(chManifestInput)
    def chStage5Manifest = ASSEMBLE_STAGE5_MANIFEST_FROM_RELEASE.out.stage5_manifest

    emit:
    validated_bundle = VALIDATE_STAGE5_CONTRACT.out.validated_bundle
    production_release = SIGN_OFF_CLINICAL_BUNDLE.out.production_release
    stage5_manifest = chStage5Manifest
}

workflow {
    main:
    def inputPath = params.input?.toString()?.trim()
    if (!inputPath) {
        throw new IllegalStateException('STAGE5_PRECONDITION_FAILURE: --input is required and must reference a Stage 4 manifest')
    }

    def stage4ManifestFile = file(inputPath)
    if (!stage4ManifestFile.exists()) {
        throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: Stage 4 manifest not found: ${stage4ManifestFile}")
    }

    def thresholdsFile = resolveStageConfigPath(readOptionalParam('thresh_config'), params.thresholds, 'thresholds.yaml')
    if (!thresholdsFile.exists()) {
        throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: thresholds config not found: ${thresholdsFile}")
    }
    def signerPolicy = resolveStage5SignerPolicy(new File(thresholdsFile.toString()))

    def referencesFile = resolveStageConfigPath(readOptionalParam('ref_config'), params.references, 'references.yaml')
    if (!referencesFile.exists()) {
        throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: references config not found: ${referencesFile}")
    }
    def stage5ReferenceAssets = collectStage5ReferenceAssets(new File(referencesFile.toString())).collect { asset ->
        file(asset.toString())
    }

    def infrastructureFile = resolveStageConfigPath(readOptionalParam('infra_config'), params.infrastructure, 'infrastructure.yaml')
    def governedContainerDigest = null
    if (infrastructureFile != null && infrastructureFile.exists()) {
        def infraDoc = mapOrEmpty(new groovy.yaml.YamlSlurper().parse(infrastructureFile))
        def containers = mapOrEmpty(infraDoc.containers)
        governedContainerDigest = containers?.annotation?.digest?.toString()?.trim() ?: containers?.reporting?.digest?.toString()?.trim()
    }

    VALIDATE_STAGE5_REFERENCES(channel.value(referencesFile), channel.value(stage5ReferenceAssets))
    def chReferencesValidated = VALIDATE_STAGE5_REFERENCES.out.validated_signal

    def manifest = mapOrEmpty(new groovy.yaml.YamlSlurper().parse(stage4ManifestFile))
    def samples = manifest.samples
    if (!(samples instanceof List) || samples.isEmpty()) {
        throw new IllegalStateException('STAGE5_PRECONDITION_FAILURE: Stage 4 manifest contains no samples')
    }

    def manifestDir = new File(stage4ManifestFile.toString()).parentFile ?: new File(projectDir.toString())
    def chIntakePayload = channel.fromList(samples).map { sample ->
        def meta = buildStage5Meta(sample as Map, manifestDir, thresholdsFile, referencesFile, infrastructureFile)
        tuple(meta, file(meta.phased_vcf.toString(), checkIfExists: true))
    }

    STAGE5_CLINICAL_TRIAGE(
        chIntakePayload,
        channel.value(thresholdsFile),
        channel.value(referencesFile),
        channel.value(stage5ReferenceAssets),
        chReferencesValidated,
        channel.value(file(signerPolicy.key_file.toString(), checkIfExists: true)),
        channel.value(file(signerPolicy.pub_file.toString(), checkIfExists: true)),
        channel.value(signerPolicy),
        channel.value(infrastructureFile),
        channel.value(governedContainerDigest)
    )
}
