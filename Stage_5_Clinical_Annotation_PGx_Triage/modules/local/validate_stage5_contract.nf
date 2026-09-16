nextflow.enable.dsl = 2

def validateStage5BundleOnController(stage5BundleJson, String validatorScript) {
    File validatorFile = new File(validatorScript)
    if (!validatorFile.exists() || !validatorFile.isFile()) {
        throw new IllegalStateException("STAGE5_CONTRACT_FAILURE: validator script not found: ${validatorScript}")
    }

    File bundleFile = new File(stage5BundleJson.toString())
    if (!bundleFile.exists() || !bundleFile.isFile()) {
        throw new IllegalStateException("STAGE5_CONTRACT_FAILURE: bundle file not found: ${bundleFile}")
    }

    def loader = new GroovyClassLoader(ClassLoader.getSystemClassLoader())
    def validatorClass = loader.parseClass(validatorFile)
    def validationResult
    if (validatorClass.metaClass.respondsTo(validatorClass, 'validateStage5ClinicalBundleFile', Object)) {
        validationResult = validatorClass.validateStage5ClinicalBundleFile(bundleFile.toString())
    } else {
        validationResult = validatorClass.validateStage5ClinicalBundle(bundleFile.getText('UTF-8'))
    }

    if (validationResult instanceof Boolean && !validationResult) {
        throw new IllegalStateException("STAGE5_CONTRACT_FAILURE: validator returned false for bundle: ${bundleFile}")
    }
}

workflow VALIDATE_STAGE5_CONTRACT {
    take:
    ch_stage5_bundle_json

    main:
    def validatorScript = params.stage5_contract_validator_path?.toString()?.trim()
    if (!validatorScript) {
        validatorScript = new File(workflow.projectDir.toString(), 'lib/Stage5ContractValidator.groovy').toString()
    }

    def chValidatedBundle = ch_stage5_bundle_json.map { meta, stage5_bundle_json ->
        validateStage5BundleOnController(stage5_bundle_json, validatorScript)
        tuple(meta, stage5_bundle_json)
    }

    emit:
    validated_bundle = chValidatedBundle
}
