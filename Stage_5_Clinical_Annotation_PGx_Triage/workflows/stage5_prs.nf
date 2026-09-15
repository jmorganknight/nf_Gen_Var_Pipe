nextflow.enable.dsl = 2

include { STAGE5_PRS_BRANCH } from '../modules/local/stage5_simple_lanes.nf'

workflow STAGE5_PRS {
    take:
    ch_stage5_inputs

    main:
    STAGE5_PRS_BRANCH(
        ch_stage5_inputs.map { sid, phasedVcf, _phasedTbi, _ancestryJson, _phasingAuditJson, refs ->
            tuple(sid, [:], phasedVcf, refs.prs_marker_registry ?: refs.prs_markers ?: '')
        }
    )

    emit:
    branch_manifest = STAGE5_PRS_BRANCH.out.branch_manifest
}
