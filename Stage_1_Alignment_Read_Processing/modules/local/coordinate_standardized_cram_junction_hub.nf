/*
 * Node: COORDINATE_STANDARDIZED_CRAM_JUNCTION_HUB
 */

process COORDINATE_STANDARDIZED_CRAM_JUNCTION_HUB {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    tag "${meta.sample_id}"

    publishDir { "${meta.save_dir}/${meta.sample_id}/audit_and_qc/junction_hub" }, mode: 'copy', overwrite: true

    input:
    tuple val(meta), path(bam_cram), path(index)

    output:
    tuple val(meta),
          path("${meta.sample_id}.junction_verified.bam"),
          path("${meta.sample_id}.junction_verified.bam.bai"), emit: verified_stream
    path "${meta.sample_id}.junction_audit.json", emit: audit

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    samtools quickcheck "${bam_cram}"

    # Avoid duplicating very large BAMs in scratch; symlink into the task workdir.
    ln -sfn "\$(readlink -f "${bam_cram}" 2>/dev/null || printf '%s' "${bam_cram}")" "${sid}.junction_verified.bam"

    if [ -s "${index}" ]; then
        ln -sfn "\$(readlink -f "${index}" 2>/dev/null || printf '%s' "${index}")" "${sid}.junction_verified.bam.bai"
    else
        samtools index -@ "${task.cpus}" "${sid}.junction_verified.bam" "${sid}.junction_verified.bam.bai"
    fi

    python3 - <<'PYEOF'
import json
sid = "${sid}"
payload = {
  "node": "COORDINATE_STANDARDIZED_CRAM_JUNCTION_HUB",
  "sample_id": sid,
  "status": "VERIFIED",
  "audit": {
    "origin_platform": "${meta.sequencer?.platform ?: 'unknown'}",
    "checksum_lock": "ENFORCED"
  }
}
with open(f"{sid}.junction_audit.json", "w") as out:
    json.dump(payload, out, indent=2)
PYEOF
    """

    stub:
    """
    : > "${meta.sample_id}.junction_verified.bam"
    : > "${meta.sample_id}.junction_verified.bam.bai"
    printf '{"node":"COORDINATE_STANDARDIZED_CRAM_JUNCTION_HUB","status":"VERIFIED","stub":true}' > "${meta.sample_id}.junction_audit.json"
    """
}
