process STAGE1_ONT_LONGREAD_ALIGN {

    label 'process_high'
    container 'wes-onco-core:1.0.0'

    tag "${meta.sample_id}"

    publishDir { "${meta.save_dir}/${meta.sample_id}/aligned" }, mode: 'copy', overwrite: true, pattern: '*.{bam,bai,json}'

    input:
    tuple val(meta), path(r1), path(r2)
    val fasta

    output:
    tuple val(meta), path("${meta.sample_id}.ont.sorted.bam"), path("${meta.sample_id}.ont.sorted.bam.bai"), emit: bam_bai
    tuple val(meta), path("${meta.sample_id}.ont_metrics.json"), emit: json_metrics

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    minimap2 \
      -ax map-ont \
      -t "${task.cpus}" \
      "${fasta}" \
      "${r1}" \
      | samtools sort -@ "${task.cpus}" -o "${sid}.ont.sorted.bam"

    samtools index -@ "${task.cpus}" "${sid}.ont.sorted.bam"

    python3 - <<'PYEOF'
import json
from datetime import datetime, timezone

payload = {
    "sample_id": "${sid}",
    "stage": "alignment_and_markdup",
    "tool": "minimap2",
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "metrics": {
        "mode": "map-ont",
        "alignment_status": {
            "status": "PASS",
            "bam_present": True,
            "bai_present": True,
            "bam_file": "${sid}.ont.sorted.bam",
            "bai_file": "${sid}.ont.sorted.bam.bai"
        }
    }
}
with open("${sid}.ont_metrics.json", "w", encoding="utf-8") as out:
    json.dump(payload, out, indent=2)
PYEOF
    """

    stub:
    """
    : > "${meta.sample_id}.ont.sorted.bam"
    : > "${meta.sample_id}.ont.sorted.bam.bai"
    printf '{"sample_id":"%s","tool":"minimap2","mode":"map-ont","stub":true}' "${meta.sample_id}" > "${meta.sample_id}.ont_metrics.json"
    """
}
