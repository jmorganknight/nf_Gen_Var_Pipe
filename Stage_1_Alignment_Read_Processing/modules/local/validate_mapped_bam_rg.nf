process VALIDATE_MAPPED_BAM_RG {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage1", mode: 'copy', overwrite: true, pattern: 'stage1_rejection_audit.json'

    input:
    tuple val(meta), path(mapped_bam), path(mapped_bai)

    output:
    tuple val(meta), path(mapped_bam), path(mapped_bai), path('header_guard.token'), emit: guard_payload
    path 'stage1_rejection_audit.json', optional: true, emit: rejection_audit

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
import subprocess
from datetime import datetime, timezone

sid = "${sid}"
bam = "${mapped_bam}"

cmd = ["samtools", "view", "-H", bam]
res = subprocess.run(cmd, capture_output=True, text=True)
if res.returncode != 0:
    payload = {
        "failure_code": "STAGE1_PRECONDITION_FAILURE",
        "sample_id": sid,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "reason": "BAM_HEADER_UNREADABLE",
        "detail": res.stderr.strip(),
    }
    with open("stage1_rejection_audit.json", "w", encoding="utf-8") as out:
        json.dump(payload, out, indent=2)
    with open("header_guard.token", "w", encoding="utf-8") as out:
        out.write("INVALID\\n")
    raise SystemExit(0)

header = res.stdout.splitlines()
rg_lines = [line for line in header if line.startswith("@RG")]
required = ["ID:", "PL:", "PU:", "SM:", "LB:", "DS:"]
missing = []
if not rg_lines:
    missing.append("@RG")
else:
    first = rg_lines[0]
    for tag in required:
        if tag not in first:
            missing.append(tag)

if missing:
    payload = {
        "failure_code": "STAGE1_PRECONDITION_FAILURE",
        "sample_id": sid,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "reason": "MISSING_READ_GROUP_TAGS",
        "missing": missing,
    }
    with open("stage1_rejection_audit.json", "w", encoding="utf-8") as out:
        json.dump(payload, out, indent=2)
    with open("header_guard.token", "w", encoding="utf-8") as out:
        out.write("INVALID\\n")
else:
    with open("header_guard.token", "w", encoding="utf-8") as out:
        out.write("VALID\\n")
PYEOF
    """
}
