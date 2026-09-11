process STAGE1_BWA_FINALIZE {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    tag "${meta.sample_id}"

    publishDir { "${meta.save_dir}/${meta.sample_id}/aligned" }, mode: 'copy', overwrite: true, pattern: '*.{bai,json}'

    input:
    tuple val(meta), path(aligned_bam)

    output:
    tuple val(meta), path("${meta.sample_id}.aligned.bam"), path("${meta.sample_id}.aligned.bam.bai"), emit: bam_bai
    tuple val(meta), path("${meta.sample_id}.bwa_metrics.json"), emit: json_metrics

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    cp -L "${aligned_bam}" "${sid}.aligned.bam"
    samtools index -@ "${task.cpus}" "${sid}.aligned.bam"

    python3 - <<'PYEOF'
import json
from datetime import datetime, timezone

payload = {
    "sample_id": "${sid}",
    "stage": "alignment_and_markdup",
    "tool": "bwa-mem2",
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "metrics": {
        "alignment_status": {
            "status": "PASS",
            "bam_present": True,
            "bai_present": True,
            "bam_file": "${sid}.aligned.bam",
            "bai_file": "${sid}.aligned.bam.bai"
        }
    }
}
with open("${sid}.bwa_metrics.json", "w", encoding="utf-8") as out:
    json.dump(payload, out, indent=2)
PYEOF
    """
}
