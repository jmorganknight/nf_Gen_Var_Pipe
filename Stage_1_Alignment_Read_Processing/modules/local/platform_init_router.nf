/*
 * Stage 0.4 — PLATFORM_INIT_ROUTER
 * Emits routing proof that a valid intake payload was assigned to the correct
 * instrument channel. Actual fan-out is performed in the workflow branch to
 * preserve tuple structure for downstream subworkflows.
 */

process PLATFORM_INIT_ROUTER {

    label 'process_low'
    container 'genvar-core:2.1.0'

    tag "${meta.sample_id}"

    publishDir "${params.stage1_outdir}/audit_and_qc", mode: 'copy', overwrite: true, pattern: '*.platform_init_route.json'

    input:
    tuple val(meta), path(fastq_1), path(fastq_2), path(intake_token, stageAs: 'intake_token/*'), path(intake_report, stageAs: 'intake_report/*')

    output:
    tuple val(meta), path(fastq_1), path(fastq_2), path(intake_token), path(intake_report), emit: routed_payload
    path "${meta.sample_id}.platform_init_route.json", emit: route_audit

    script:
    def sid = meta.sample_id
    def platform = (meta.sequencer?.platform ?: 'illumina').toString().toLowerCase()
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

sid = "${sid}"
platform = "${platform}"
token = Path("${intake_token}").read_text(encoding='utf-8').strip()
route_map = {
    'illumina': 'illumina_channel',
    'ultima': 'ultima_channel',
    'element': 'element_channel',
    'complete': 'complete_channel',
}
payload = {
    'node': 'PLATFORM_INIT_ROUTER',
    'sample_id': sid,
    'timestamp_utc': datetime.now(timezone.utc).isoformat(),
    'platform': platform,
    'intake_validation_token': token,
    'route_channel': route_map.get(platform, 'unsupported_platform'),
    'token_sha256': hashlib.sha256(token.encode('utf-8')).hexdigest(),
}

with open(f"{sid}.platform_init_route.json", 'w', encoding='utf-8') as handle:
    json.dump(payload, handle, indent=2)
PYEOF
    """

    stub:
    """
    printf '{"node":"PLATFORM_INIT_ROUTER","sample_id":"%s","route_channel":"illumina_channel","stub":true}' "${meta.sample_id}" > "${meta.sample_id}.platform_init_route.json"
    """
}