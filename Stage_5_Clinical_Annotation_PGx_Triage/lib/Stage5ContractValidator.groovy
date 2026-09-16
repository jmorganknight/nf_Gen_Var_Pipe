import groovy.json.JsonSlurper
import java.util.regex.Pattern

/**
 * Stage 5 to Stage 6 immutable data contract validator.
 *
 * Fail-closed behavior: any contract violation throws IllegalArgumentException.
 */
class Stage5ContractValidator {

    static final Set<String> ALLOWED_BRANCHES = ['germline', 'pgx', 'prs', 'sf', 'somatic'] as Set
    static final Set<String> ALLOWED_BRANCH_STATUS = ['COMPLETED', 'SKIPPED_BY_CLINICAL_DIRECTIVE'] as Set
    static final Set<String> ALLOWED_SOMATIC_TIERS = ['I', 'II', 'III', 'IV'] as Set
    static final Set<String> ALLOWED_SOMATIC_ORIGIN = ['SOMATIC', 'GERMLINE', 'UNDETERMINED'] as Set
    static final Set<String> ALLOWED_CALIBRATION_STATUS = ['CALIBRATED', 'UNCALIBRATED', 'NOT_APPLICABLE', 'FAILED_MARKER_QC'] as Set
    static final Pattern HEX_SHA256 = ~/^[a-fA-F0-9]{64}$/

    static Map<String, Object> stage5ClinicalBundleSchema() {
        return [
              (((char) 36) + 'schema'): 'https://json-schema.org/draft/2020-12/schema',
            title: 'Stage5ClinicalBundle',
            type: 'object',
            required: ['metadata', 'branches'],
            additionalProperties: false,
            properties: [
                metadata: [
                    type: 'object',
                    required: [
                        'sample_id',
                        'patient_id',
                        'case_id',
                        'intake_validation_token',
                        'git_commit_sha',
                        'container_digest',
                        'policy_version',
                        'timestamp_utc'
                    ],
                    additionalProperties: true,
                    properties: [
                        sample_id: [type: 'string', minLength: 1],
                        patient_id: [type: 'string', minLength: 1],
                        case_id: [type: 'string', minLength: 1],
                        intake_validation_token: [type: 'string', minLength: 1],
                        git_commit_sha: [type: 'string', minLength: 7],
                        container_digest: [type: 'string', minLength: 8],
                        policy_version: [type: 'string', minLength: 1],
                        timestamp_utc: [type: 'string', minLength: 1]
                    ]
                ],
                branches: [
                    type: 'object',
                    required: ['germline', 'pgx', 'prs', 'sf', 'somatic'],
                    additionalProperties: false,
                    properties: [
                        germline: [type: 'object', required: ['summary', 'reported_variants'], additionalProperties: false],
                        pgx: [type: 'object', required: ['summary', 'reported_calls'], additionalProperties: false],
                        prs: [type: 'object', required: ['summary', 'score_payload'], additionalProperties: false],
                        sf: [type: 'object', required: ['summary', 'reported_variants'], additionalProperties: false],
                        somatic: [type: 'object', required: ['summary', 'reported_variants'], additionalProperties: false]
                    ]
                ]
            ]
        ]
    }

    static Map<String, Object> branchSummarySchema() {
        return [
            type: 'object',
            required: [
                'status',
                'reason',
                'input_variant_count',
                'reported_variant_count',
                'ruleset_version',
                'content_sha256'
            ],
            additionalProperties: false,
            properties: [
                status: [type: 'string', enum: ALLOWED_BRANCH_STATUS as List],
                reason: [type: 'string', minLength: 1],
                input_variant_count: [type: 'integer', minimum: 0],
                reported_variant_count: [type: 'integer', minimum: 0],
                ruleset_version: [type: 'string', minLength: 1],
                content_sha256: [type: 'string', pattern: HEX_SHA256.pattern()]
            ]
        ]
    }

    static Map<String, Object> germlinePayloadSchema() {
        return [
            type: 'array',
            items: [
                type: 'object',
                required: [
                    'acmg_class',
                    'bayesian_posterior_probability',
                    'evidence_codes',
                    'transcript_hgvsc',
                    'transcript_hgvsp'
                ],
                additionalProperties: true,
                properties: [
                    acmg_class: [type: 'integer', minimum: 1, maximum: 5],
                    bayesian_posterior_probability: [type: 'number', minimum: 0, maximum: 1],
                    evidence_codes: [type: 'array', items: [type: 'string', minLength: 1]],
                    transcript_hgvsc: [type: 'string', minLength: 1],
                    transcript_hgvsp: [type: 'string', minLength: 1]
                ]
            ]
        ]
    }

    static Map<String, Object> pgxPayloadSchema() {
        return [
            type: 'array',
            items: [
                type: 'object',
                required: ['gene', 'diplotype', 'phenotype_status', 'cpic_actionability_tier', 'recommendation_trace'],
                additionalProperties: true,
                properties: [
                    gene: [type: 'string', minLength: 1],
                    diplotype: [type: 'string', minLength: 1],
                    phenotype_status: [type: 'string', minLength: 1],
                    cpic_actionability_tier: [type: 'string', minLength: 1],
                    recommendation_trace: [type: 'string', minLength: 1]
                ]
            ]
        ]
    }

    static Map<String, Object> prsPayloadSchema() {
        return [
            type: 'object',
            required: [
                'raw_score',
                'ancestry_adjusted_percentile',
                'calibration_status',
                'score_confidence_interval',
                'no_call_flag'
            ],
            additionalProperties: true,
            properties: [
                raw_score: [type: 'number'],
                ancestry_adjusted_percentile: [type: 'number', minimum: 0, maximum: 100],
                calibration_status: [type: 'string', enum: ALLOWED_CALIBRATION_STATUS as List],
                score_confidence_interval: [
                    type: 'object',
                    required: ['lower', 'upper'],
                    additionalProperties: false,
                    properties: [
                        lower: [type: 'number'],
                        upper: [type: 'number']
                    ]
                ],
                no_call_flag: [type: 'boolean']
            ]
        ]
    }

    static Map<String, Object> sfPayloadSchema() {
        return [
            type: 'array',
            items: [
                type: 'object',
                required: ['gene', 'variant_pathogenicity', 'clinical_protocol_link'],
                additionalProperties: true,
                properties: [
                    gene: [type: 'string', minLength: 1],
                    variant_pathogenicity: [type: 'string', minLength: 1],
                    clinical_protocol_link: [type: 'string', minLength: 1]
                ]
            ]
        ]
    }

    static Map<String, Object> somaticPayloadSchema() {
        return [
            type: 'array',
            items: [
                type: 'object',
                required: ['amp_asco_cap_tier', 'vaf', 'origin_status'],
                additionalProperties: true,
                properties: [
                    amp_asco_cap_tier: [type: 'string', enum: ALLOWED_SOMATIC_TIERS as List],
                    vaf: [type: 'number', minimum: 0, maximum: 1],
                    origin_status: [type: 'string', enum: ALLOWED_SOMATIC_ORIGIN as List]
                ]
            ]
        ]
    }

    static Map<String, Object> fullContractSchema() {
        return [
            stage5_clinical_bundle: stage5ClinicalBundleSchema(),
            branch_summary: branchSummarySchema(),
            branch_payloads: [
                germline: germlinePayloadSchema(),
                pgx: pgxPayloadSchema(),
                prs: prsPayloadSchema(),
                sf: sfPayloadSchema(),
                somatic: somaticPayloadSchema()
            ]
        ]
    }

    static Map<String, Object> parseJsonText(String jsonText) {
        if (!(jsonText instanceof CharSequence) || !jsonText.toString().trim()) {
            throw new IllegalArgumentException('STAGE5_CONTRACT_FAILURE: empty JSON payload text')
        }
        def parsed = new JsonSlurper().parseText(jsonText.toString())
        if (!(parsed instanceof Map)) {
            throw new IllegalArgumentException('STAGE5_CONTRACT_FAILURE: top-level clinical bundle must be a JSON object')
        }
        return (Map<String, Object>) parsed
    }

    static void validateStage5ClinicalBundle(Object payloadInput) {
        Map payload
        if (payloadInput instanceof Map) {
            payload = (Map) payloadInput
        } else if (payloadInput instanceof CharSequence) {
            payload = parseJsonText(payloadInput.toString())
        } else {
            throw new IllegalArgumentException('STAGE5_CONTRACT_FAILURE: payload must be Map or JSON string')
        }

        validateMetadata(payload.metadata)
        validateBranches(payload.branches)
    }

    static void validateStage5ClinicalBundleFile(Object jsonFilePath) {
        if (!(jsonFilePath instanceof CharSequence) || !jsonFilePath.toString().trim()) {
            throw new IllegalArgumentException('STAGE5_CONTRACT_FAILURE: JSON file path is required')
        }
        File f = new File(jsonFilePath.toString())
        if (!f.exists() || !f.isFile()) {
            throw new IllegalArgumentException('STAGE5_CONTRACT_FAILURE: JSON file does not exist: ' + f.path)
        }
        validateStage5ClinicalBundle(f.getText('UTF-8'))
    }

    private static void validateMetadata(Object metadataObj) {
        Map metadata = requireMap(metadataObj, 'metadata')
        requireNonBlankString(metadata.sample_id, 'metadata.sample_id')
        requireNonBlankString(metadata.patient_id, 'metadata.patient_id')
        requireNonBlankString(metadata.case_id, 'metadata.case_id')
        requireNonBlankString(metadata.intake_validation_token, 'metadata.intake_validation_token')
        requireNonBlankString(metadata.git_commit_sha, 'metadata.git_commit_sha')
        requireNonBlankString(metadata.container_digest, 'metadata.container_digest')
        requireNonBlankString(metadata.policy_version, 'metadata.policy_version')
        requireNonBlankString(metadata.timestamp_utc, 'metadata.timestamp_utc')
    }

    private static void validateBranches(Object branchesObj) {
        Map branches = requireMap(branchesObj, 'branches')

        ALLOWED_BRANCHES.each { String branchName ->
            if (!branches.containsKey(branchName)) {
                throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: missing required branch '${branchName}'")
            }
        }

        validateGermlineBranch(requireMap(branches.germline, 'branches.germline'))
        validatePgxBranch(requireMap(branches.pgx, 'branches.pgx'))
        validatePrsBranch(requireMap(branches.prs, 'branches.prs'))
        validateSfBranch(requireMap(branches.sf, 'branches.sf'))
        validateSomaticBranch(requireMap(branches.somatic, 'branches.somatic'))
    }

    private static void validateGermlineBranch(Map branch) {
        validateBranchSummary(requireMap(branch.summary, 'branches.germline.summary'), 'branches.germline.summary')
        List variants = requireList(branch.reported_variants, 'branches.germline.reported_variants')
        variants.eachWithIndex { Object item, int idx ->
            String p = "branches.germline.reported_variants[${idx}]"
            Map row = requireMap(item, p)
            requireIntegerRange(row.acmg_class, 1, 5, "${p}.acmg_class")
            requireNumberRange(row.bayesian_posterior_probability, 0.0d, 1.0d, "${p}.bayesian_posterior_probability")
            requireStringList(row.evidence_codes, "${p}.evidence_codes")
            requireNonBlankString(row.transcript_hgvsc, "${p}.transcript_hgvsc")
            requireNonBlankString(row.transcript_hgvsp, "${p}.transcript_hgvsp")
        }
    }

    private static void validatePgxBranch(Map branch) {
        validateBranchSummary(requireMap(branch.summary, 'branches.pgx.summary'), 'branches.pgx.summary')
        List calls = requireList(branch.reported_calls, 'branches.pgx.reported_calls')
        calls.eachWithIndex { Object item, int idx ->
            String p = "branches.pgx.reported_calls[${idx}]"
            Map row = requireMap(item, p)
            requireNonBlankString(row.gene, "${p}.gene")
            requireNonBlankString(row.diplotype, "${p}.diplotype")
            requireNonBlankString(row.phenotype_status, "${p}.phenotype_status")
            requireNonBlankString(row.cpic_actionability_tier, "${p}.cpic_actionability_tier")
            requireNonBlankString(row.recommendation_trace, "${p}.recommendation_trace")
        }
    }

    private static void validatePrsBranch(Map branch) {
        validateBranchSummary(requireMap(branch.summary, 'branches.prs.summary'), 'branches.prs.summary')
        Map score = requireMap(branch.score_payload, 'branches.prs.score_payload')
        requireNumber(score.raw_score, 'branches.prs.score_payload.raw_score')
        requireNumberRange(score.ancestry_adjusted_percentile, 0.0d, 100.0d, 'branches.prs.score_payload.ancestry_adjusted_percentile')
        String calibration = requireNonBlankString(score.calibration_status, 'branches.prs.score_payload.calibration_status')
        if (!ALLOWED_CALIBRATION_STATUS.contains(calibration)) {
            throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: invalid calibration status '${calibration}'")
        }

        Map ci = requireMap(score.score_confidence_interval, 'branches.prs.score_payload.score_confidence_interval')
        Number lower = requireNumber(ci.lower, 'branches.prs.score_payload.score_confidence_interval.lower')
        Number upper = requireNumber(ci.upper, 'branches.prs.score_payload.score_confidence_interval.upper')
        if (lower.doubleValue() > upper.doubleValue()) {
            throw new IllegalArgumentException('STAGE5_CONTRACT_FAILURE: PRS confidence interval lower cannot exceed upper')
        }

        if (!(score.no_call_flag instanceof Boolean)) {
            throw new IllegalArgumentException('STAGE5_CONTRACT_FAILURE: branches.prs.score_payload.no_call_flag must be boolean')
        }
    }

    private static void validateSfBranch(Map branch) {
        validateBranchSummary(requireMap(branch.summary, 'branches.sf.summary'), 'branches.sf.summary')
        List variants = requireList(branch.reported_variants, 'branches.sf.reported_variants')
        variants.eachWithIndex { Object item, int idx ->
            String p = "branches.sf.reported_variants[${idx}]"
            Map row = requireMap(item, p)
            requireNonBlankString(row.gene, "${p}.gene")
            requireNonBlankString(row.variant_pathogenicity, "${p}.variant_pathogenicity")
            requireNonBlankString(row.clinical_protocol_link, "${p}.clinical_protocol_link")
        }
    }

    private static void validateSomaticBranch(Map branch) {
        validateBranchSummary(requireMap(branch.summary, 'branches.somatic.summary'), 'branches.somatic.summary')
        List variants = requireList(branch.reported_variants, 'branches.somatic.reported_variants')
        variants.eachWithIndex { Object item, int idx ->
            String p = "branches.somatic.reported_variants[${idx}]"
            Map row = requireMap(item, p)
            String tier = requireNonBlankString(row.amp_asco_cap_tier, "${p}.amp_asco_cap_tier")
            if (!ALLOWED_SOMATIC_TIERS.contains(tier)) {
                throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: invalid AMP/ASCO/CAP tier '${tier}' at ${p}")
            }
            requireNumberRange(row.vaf, 0.0d, 1.0d, "${p}.vaf")
            String origin = requireNonBlankString(row.origin_status, "${p}.origin_status")
            if (!ALLOWED_SOMATIC_ORIGIN.contains(origin)) {
                throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: invalid origin_status '${origin}' at ${p}")
            }
        }
    }

    private static void validateBranchSummary(Map summary, String fieldPath) {
        String status = requireNonBlankString(summary.status, "${fieldPath}.status")
        if (!ALLOWED_BRANCH_STATUS.contains(status)) {
            throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: invalid status '${status}' at ${fieldPath}")
        }

        requireNonBlankString(summary.reason, "${fieldPath}.reason")
        int inputCount = requireNonNegativeInteger(summary.input_variant_count, "${fieldPath}.input_variant_count")
        int reportedCount = requireNonNegativeInteger(summary.reported_variant_count, "${fieldPath}.reported_variant_count")
        requireNonBlankString(summary.ruleset_version, "${fieldPath}.ruleset_version")

        String sha = requireNonBlankString(summary.content_sha256, "${fieldPath}.content_sha256")
        if (!(sha ==~ HEX_SHA256)) {
            throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: invalid SHA256 at ${fieldPath}.content_sha256")
        }

        if (status == 'SKIPPED_BY_CLINICAL_DIRECTIVE' && reportedCount != 0) {
            throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: skipped branch cannot report variants at ${fieldPath}")
        }
        if (reportedCount > inputCount) {
            throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: reported_variant_count exceeds input_variant_count at ${fieldPath}")
        }
    }

    private static Map requireMap(Object value, String fieldPath) {
        if (!(value instanceof Map)) {
            throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: ${fieldPath} must be an object")
        }
        return (Map) value
    }

    private static List requireList(Object value, String fieldPath) {
        if (!(value instanceof List)) {
            throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: ${fieldPath} must be an array")
        }
        return (List) value
    }

    private static String requireNonBlankString(Object value, String fieldPath) {
        if (!(value instanceof CharSequence) || !value.toString().trim()) {
            throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: ${fieldPath} must be a non-empty string")
        }
        return value.toString().trim()
    }

    private static Number requireNumber(Object value, String fieldPath) {
        if (!(value instanceof Number)) {
            throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: ${fieldPath} must be numeric")
        }
        return (Number) value
    }

    private static Number requireNumberRange(Object value, double minValue, double maxValue, String fieldPath) {
        Number number = requireNumber(value, fieldPath)
        double v = number.doubleValue()
        if (v < minValue || v > maxValue) {
            throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: ${fieldPath} out of range [${minValue}, ${maxValue}]")
        }
        return number
    }

    private static int requireNonNegativeInteger(Object value, String fieldPath) {
        if (!(value instanceof Number)) {
            throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: ${fieldPath} must be an integer")
        }
        double v = ((Number) value).doubleValue()
        if (v != Math.floor(v) || v < 0) {
            throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: ${fieldPath} must be a non-negative integer")
        }
        return ((Number) value).intValue()
    }

    private static int requireIntegerRange(Object value, int minValue, int maxValue, String fieldPath) {
        int n = requireNonNegativeInteger(value, fieldPath)
        if (n < minValue || n > maxValue) {
            throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: ${fieldPath} out of range [${minValue}, ${maxValue}]")
        }
        return n
    }

    private static void requireStringList(Object value, String fieldPath) {
        List list = requireList(value, fieldPath)
        if (list.isEmpty()) {
            throw new IllegalArgumentException("STAGE5_CONTRACT_FAILURE: ${fieldPath} cannot be empty")
        }
        list.eachWithIndex { Object item, int idx ->
            requireNonBlankString(item, "${fieldPath}[${idx}]")
        }
    }
}
