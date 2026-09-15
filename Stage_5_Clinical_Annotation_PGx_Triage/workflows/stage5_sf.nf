nextflow.enable.dsl = 2

include { STAGE5_SF_BRANCH } from '../modules/local/stage5_simple_lanes.nf'

workflow STAGE5_SF {
    take:
    ch_stage5_inputs

    main:
    STAGE5_SF_BRANCH(
        ch_stage5_inputs.map { sid, phasedVcf, _phasedTbi, _ancestryJson, _phasingAuditJson, refs ->
            tuple(sid, [:], phasedVcf, refs.sf_gene_registry ?: refs.sf_bed ?: '')
        }
    )

    emit:
    branch_manifest = STAGE5_SF_BRANCH.out.branch_manifest
}
