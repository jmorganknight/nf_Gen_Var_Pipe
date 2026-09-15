nextflow.enable.dsl = 2

include { STAGE5_PGX_BRANCH } from '../modules/local/stage5_simple_lanes.nf'

workflow STAGE5_PGX {
    take:
    ch_stage5_inputs

    main:
    STAGE5_PGX_BRANCH(
        ch_stage5_inputs.map { sid, phasedVcf, _phasedTbi, _ancestryJson, _phasingAuditJson, refs ->
            tuple(sid, [:], phasedVcf, refs.pgx_gene_panel ?: refs.cpic_allele_table ?: '')
        }
    )

    emit:
    branch_manifest = STAGE5_PGX_BRANCH.out.branch_manifest
}
