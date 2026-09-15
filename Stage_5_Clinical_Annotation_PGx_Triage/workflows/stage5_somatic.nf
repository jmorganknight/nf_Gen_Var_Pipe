nextflow.enable.dsl = 2

include { STAGE5_SOMATIC_BRANCH } from '../modules/local/stage5_simple_lanes.nf'

workflow STAGE5_SOMATIC {
    take:
    ch_stage5_inputs

    main:
    STAGE5_SOMATIC_BRANCH(
        ch_stage5_inputs.map { sid, phasedVcf, _phasedTbi, _ancestryJson, _phasingAuditJson, _refs ->
            tuple(sid, [:], phasedVcf)
        }
    )

    emit:
    branch_manifest = STAGE5_SOMATIC_BRANCH.out.branch_manifest
}
