nextflow.enable.dsl = 2

include { STAGE5_ISOLATED_BRANCH_ARCHITECTURE } from './workflows/stage5_isolated.nf'

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

    def primary = new File(projectDir.toString(), "conf/${fileName}")
    if (primary.exists()) {
        return file(primary.path)
    }

    def fallback = new File(projectDir.toString(), "../conf/${fileName}")
    if (fallback.exists()) {
        return file(fallback.path)
    }

    def launchRoot = workflow.hasProperty('launchDir') ? workflow.launchDir?.toString() : null
    if (launchRoot) {
        def launchFallback = new File(launchRoot, "conf/${fileName}")
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

def resolveStage5RefPath(Object rawValue, List<String> roots) {
    if (!(rawValue instanceof CharSequence)) {
        return rawValue
    }
    def text = rawValue.toString().trim()
    if (!text) {
        return text
    }
    return resolvePathWithBases(text, roots).toString()
}

workflow {
    def ys = new groovy.yaml.YamlSlurper()
    def stage5BranchNames = ['germline', 'pgx', 'sf', 'prs', 'somatic']

    def stage4InputPath = (params.input ?: params.samples)?.toString()
    if (!stage4InputPath) {
        throw new IllegalArgumentException('STAGE5_PRECONDITION_FAILURE: --input is required and must reference a Stage 4 banked manifest')
    }

    def stage4ManifestFile = file(stage4InputPath)
    if (!stage4ManifestFile.exists()) {
        throw new IllegalArgumentException('STAGE5_PRECONDITION_FAILURE: missing Stage 4 banked manifest')
    }
    if (!stage4ManifestFile.name.contains('banked_stage4')) {
        throw new IllegalArgumentException('STAGE5_PRECONDITION_FAILURE: input does not appear to be a Stage 4 banked manifest')
    }

    def referencesFile = resolveStageConfigPath(readOptionalParam('ref_config'), params.references, 'references.yaml')
    def thresholdsFile = resolveStageConfigPath(readOptionalParam('thresh_config'), params.thresholds, 'thresholds.yaml')
    def infrastructureFile = resolveStageConfigPath(readOptionalParam('infra_config'), params.infrastructure, 'infrastructure.yaml')

    def stage4Parsed = ys.parse(stage4ManifestFile)
    def samples = stage4Parsed.samples
    if (!(samples instanceof List) || samples.isEmpty()) {
        throw new IllegalArgumentException('STAGE5_PRECONDITION_FAILURE: Stage 4 manifest contains no samples')
    }

    def referenceInfo = loadResolvedReferences(referencesFile)
    def refsParsed = referenceInfo.refs + (params.refs instanceof Map ? params.refs : [:])
    def projectRoot = projectDir.toString()
    def thresholdRoot = thresholdsFile.parent ? thresholdsFile.parent.toString() : projectRoot
    def infrastructureParsed = infrastructureFile.exists() ? ys.parse(infrastructureFile) : [:]

    def referenceRoots = [
        projectRoot,
        thresholdRoot,
        stage4ManifestFile.parent?.toString(),
        referenceInfo.yamlRefDataRoot,
        params.ref_data_root?.toString(),
        params.ref_dir?.toString(),
        infrastructureParsed?.storage?.reference_host_root?.toString(),
        '/opt/reference'
    ].findAll { value -> value }

    def stage5BranchRefsRaw = [
        hotspot_exception_registry: refsParsed.hotspot_exception_registry ?: refsParsed.stage5?.hotspot_exception_registry ?: '',
        hgmd_db                  : refsParsed.hgmd_db ?: refsParsed.stage5?.hgmd_db ?: '',
        pgx_gene_panel           : refsParsed.pgx?.pgx_gene_panel ?: refsParsed.pgx_gene_panel ?: '',
        cpic_allele_table        : refsParsed.pgx?.cpic_allele_table ?: refsParsed.cpic_allele_table ?: '',
        prs_marker_registry      : refsParsed.prs?.marker_registry ?: refsParsed.prs_marker_registry ?: '',
        prs_markers              : refsParsed.prs?.markers ?: refsParsed.prs_markers ?: '',
        sf_gene_registry         : refsParsed.sf?.gene_registry ?: refsParsed.sf_gene_registry ?: '',
        sf_bed                   : refsParsed.sf?.sf_bed ?: refsParsed.sf_bed ?: ''
    ]

    def stage5BranchRefs = stage5BranchRefsRaw.collectEntries { key, value ->
        if (!(value instanceof CharSequence) || !value.toString().trim()) {
            return [(key): value]
        }
        [(key): resolveStage5RefPath(value, referenceRoots)]
    }

    def requiredRefs = [
        ['hgmd_db'],
        ['pgx_gene_panel', 'cpic_allele_table'],
        ['prs_marker_registry', 'prs_markers'],
        ['sf_gene_registry', 'sf_bed']
    ]
    requiredRefs.each { alternatives ->
        if (!alternatives.any { key -> stage5BranchRefs[key]?.toString()?.trim() }) {
            throw new IllegalStateException("STAGE5_REFERENCE_FAILURE: missing required Stage 5 reference from ${alternatives}")
        }
    }

    samples.each { sample ->
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        def token = sample.validation_token?.toString() ?: sample.intake_validation_token_value?.toString() ?: ''
        if (!token.contains('VALID_PASS|VARIANTS_HARMONIZED')) {
            throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: invalid Stage 4 validation token for sample '${sid}'")
        }

        ['phased_vcf', 'phased_vcf_tbi', 'ancestry_metrics_json', 'phasing_audit_json'].each { field ->
            def raw = sample[field]?.toString()
            if (!raw) {
                throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: missing '${field}' for sample '${sid}'")
            }
            def resolved = resolveStage4Asset(raw, stage4ManifestFile.parent?.toString() ?: projectRoot)
            if (!resolved.exists()) {
                throw new IllegalStateException("STAGE5_PRECONDITION_FAILURE: stage 4 asset not found '${field}' for sample '${sid}'")
            }
        }

        if (!(sample as Map).containsKey('requested_branches')) {
            throw new IllegalStateException(
                "STAGE5_CONTROL_PLANE_FAILURE: missing required 'requested_branches' for sample '${sid}'"
            )
        }
        if (!(sample.requested_branches instanceof List)) {
            throw new IllegalStateException(
                "STAGE5_CONTROL_PLANE_FAILURE: 'requested_branches' must be a list for sample '${sid}'"
            )
        }
        def requestedSeen = [] as Set
        (sample.requested_branches as List).each { rawBranch ->
            def normalized = rawBranch?.toString()?.trim()?.toLowerCase()
            if (!normalized) {
                throw new IllegalStateException(
                    "STAGE5_CONTROL_PLANE_FAILURE: blank branch identifier in 'requested_branches' for sample '${sid}'"
                )
            }
            if (!stage5BranchNames.contains(normalized)) {
                throw new IllegalStateException(
                    "STAGE5_CONTROL_PLANE_FAILURE: unrecognized branch identifier '${normalized}' in 'requested_branches' for sample '${sid}'. " +
                    "Allowed values: ${stage5BranchNames}"
                )
            }
            if (requestedSeen.contains(normalized)) {
                throw new IllegalStateException(
                    "STAGE5_CONTROL_PLANE_FAILURE: duplicate branch identifier '${normalized}' in 'requested_branches' for sample '${sid}'"
                )
            }
            requestedSeen << normalized
        }
    }

    def chStage5Inputs = channel.fromList(samples).map { sample ->
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        def phasedVcf = resolveStage4Asset(sample.phased_vcf.toString(), stage4ManifestFile.parent?.toString() ?: projectRoot)
        def phasedVcfTbi = resolveStage4Asset(sample.phased_vcf_tbi.toString(), stage4ManifestFile.parent?.toString() ?: projectRoot)
        def ancestryMetrics = resolveStage4Asset(sample.ancestry_metrics_json?.toString() ?: '', stage4ManifestFile.parent?.toString() ?: projectRoot)
        def phasingAudit = resolveStage4Asset(sample.phasing_audit_json?.toString() ?: '', stage4ManifestFile.parent?.toString() ?: projectRoot)
        def requestedRaw = sample.requested_branches as List
        def requestedNormalized = requestedRaw.collect { item ->
            item?.toString()?.trim()?.toLowerCase()
        }.findAll { item -> item && stage5BranchNames.contains(item) }.unique()
        def requestedBranches = requestedNormalized
        tuple(
            sid,
            file(phasedVcf, checkIfExists: true),
            file(phasedVcfTbi, checkIfExists: true),
            file(ancestryMetrics, checkIfExists: true),
            file(phasingAudit, checkIfExists: true),
            stage5BranchRefs,
            requestedBranches
        )
    }

    STAGE5_ISOLATED_BRANCH_ARCHITECTURE(chStage5Inputs)
}
