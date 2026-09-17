nextflow.enable.dsl = 2

include { STAGE4_ANCESTRY_PCA } from '../subworkflows/local/stage4_ancestry_pca.nf'
include { STAGE4_PHASING } from '../subworkflows/local/stage4_phasing.nf'
include { STAGE4_CONTRACT } from '../modules/local/bank_stage4_contract.nf'
include { ASSEMBLE_STAGE4_MANIFEST } from '../modules/local/assemble_stage4_banked_manifest.nf'

workflow STAGE4_ANCESTRY_PGX {
    take:
    ch_stage4_inputs

    main:
    ch_ancestry = STAGE4_ANCESTRY_PCA(ch_stage4_inputs)
    // Stage 4 contract: two-layer PopPCA projection must complete before phasing starts.
    ch_phasing = STAGE4_PHASING(ch_ancestry.ancestry_ready)

    STAGE4_CONTRACT(ch_phasing.contract_bundle)
    ASSEMBLE_STAGE4_MANIFEST(STAGE4_CONTRACT.out.manifest_fragment.collect())

    emit:
    ancestry_projection = ch_ancestry.ancestry_ready
    phased_bundle = ch_phasing.phase_bundle
    stage4_manifest = ASSEMBLE_STAGE4_MANIFEST.out.stage4_manifest
}
