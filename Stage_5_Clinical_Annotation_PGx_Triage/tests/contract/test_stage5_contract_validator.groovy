import groovy.json.JsonOutput
import groovy.json.JsonSlurper

File validatorFile = new File('Stage_5_Clinical_Annotation_PGx_Triage/lib/Stage5ContractValidator.groovy')
if (!validatorFile.exists()) {
    throw new IllegalStateException('Missing validator file: ' + validatorFile.path)
}

GroovyClassLoader loader = new GroovyClassLoader(this.class.classLoader)
Class validatorClass = loader.parseClass(validatorFile)

def validate = { Object payload ->
    validatorClass.validateStage5ClinicalBundle(payload)
}

def deepCopy = { Map payload ->
    return (Map) new JsonSlurper().parseText(JsonOutput.toJson(payload))
}

def expectFailure = { Object payload, String expectedFragment ->
    try {
        validate(payload)
        assert false: 'Expected validation failure containing: ' + expectedFragment
    } catch (IllegalArgumentException ex) {
        assert ex.message.contains(expectedFragment): 'Unexpected failure message: ' + ex.message
    }
}

String sha = 'a' * 64
Map summaryCompleted = [
    status: 'COMPLETED',
    reason: 'EXECUTED_PER_CLINICAL_DIRECTIVE',
    input_variant_count: 10,
    reported_variant_count: 2,
    ruleset_version: 'policy-2026.09',
    content_sha256: sha
]
Map summarySkipped = [
    status: 'SKIPPED_BY_CLINICAL_DIRECTIVE',
    reason: 'BRANCH_NOT_REQUESTED',
    input_variant_count: 10,
    reported_variant_count: 0,
    ruleset_version: 'policy-2026.09',
    content_sha256: sha
]

Map validPayload = [
    metadata: [
        sample_id: 'HG002',
        patient_id: 'P001',
        case_id: 'C001',
        intake_validation_token: 'VALID_PASS|VARIANTS_HARMONIZED|INTAKE_OK',
        git_commit_sha: '52c245b',
        container_digest: 'sha256:1234abcd',
        policy_version: 'control-plane-2026.09',
        timestamp_utc: '2026-09-16T22:45:00Z'
    ],
    branches: [
        germline: [
            summary: summaryCompleted,
            reported_variants: [[
                acmg_class: 4,
                bayesian_posterior_probability: 0.97,
                evidence_codes: ['PVS1_STRONG', 'PP3', 'PM2'],
                transcript_hgvsc: 'NM_000000.1:c.123A>T',
                transcript_hgvsp: 'NP_000000.1:p.Lys41Asn'
            ]]
        ],
        pgx: [
            summary: summaryCompleted,
            reported_calls: [[
                gene: 'CYP2C19',
                diplotype: '*1/*2',
                phenotype_status: 'Intermediate Metabolizer',
                cpic_actionability_tier: 'A',
                recommendation_trace: 'CPIC guideline v2026.1 rule CYP2C19-IM'
            ]]
        ],
        prs: [
            summary: summaryCompleted,
            score_payload: [
                raw_score: 1.83,
                ancestry_adjusted_percentile: 82.4,
                calibration_status: 'CALIBRATED',
                score_confidence_interval: [lower: 1.55, upper: 2.06],
                no_call_flag: false
            ]
        ],
        sf: [
            summary: summarySkipped,
            reported_variants: []
        ],
        somatic: [
            summary: summaryCompleted,
            reported_variants: [[
                amp_asco_cap_tier: 'II',
                vaf: 0.31,
                origin_status: 'SOMATIC'
            ]]
        ]
    ]
]

validate(validPayload)
validate(JsonOutput.toJson(validPayload))

File tmpJson = File.createTempFile('stage5_bundle_', '.json')
tmpJson.text = JsonOutput.prettyPrint(JsonOutput.toJson(validPayload))
validatorClass.validateStage5ClinicalBundleFile(tmpJson.path)
tmpJson.delete()

Map missingMetadataField = deepCopy(validPayload)
missingMetadataField.metadata.remove('intake_validation_token')
expectFailure(missingMetadataField, 'metadata.intake_validation_token')

Map invalidStatus = deepCopy(validPayload)
invalidStatus.branches.germline.summary.status = 'DONE'
expectFailure(invalidStatus, 'invalid status')

Map skippedWithReportedVariants = deepCopy(validPayload)
skippedWithReportedVariants.branches.sf.summary.reported_variant_count = 1
expectFailure(skippedWithReportedVariants, 'skipped branch cannot report variants')

Map invalidSomaticTier = deepCopy(validPayload)
invalidSomaticTier.branches.somatic.reported_variants[0].amp_asco_cap_tier = 'V'
expectFailure(invalidSomaticTier, 'invalid AMP/ASCO/CAP tier')

Map invalidPrsCI = deepCopy(validPayload)
invalidPrsCI.branches.prs.score_payload.score_confidence_interval = [lower: 2.0, upper: 1.0]
expectFailure(invalidPrsCI, 'PRS confidence interval lower cannot exceed upper')

println 'PASS: Stage5ContractValidator contract tests completed'
