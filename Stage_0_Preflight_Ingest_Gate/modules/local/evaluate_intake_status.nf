/*
 * Stage 0.3 — EVALUATE_INTAKE_STATUS
 * Canonical intake route-classification audit node.
 */

process EVALUATE_INTAKE_STATUS {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    tag "${meta.sample_id}"

    publishDir { "${meta.save_dir}/${meta.sample_id}/audit_and_qc" }, mode: 'copy', overwrite: true

    input:
    tuple val(meta), path(fastq_1), path(fastq_2), path(intake_token), path(intake_report)

    output:
    tuple val(meta), path(fastq_1), path(fastq_2), path(intake_token), path(intake_report), emit: evaluated_payload
    path "${meta.sample_id}.intake_route_decision.json", emit: route_audit

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

sid = "${sid}"
token = Path("${intake_token}").read_text(encoding='utf-8').strip()
route_target = 'PLATFORM_INIT_ROUTER' if token.startswith('VALID_PASS|') else 'INGEST_FAIL_REJECT'

payload = {
    'node': 'EVALUATE_INTAKE_STATUS',
    'sample_id': sid,
    'patient_id': "${meta.patient_id ?: meta.sample_id}",
    'timestamp_utc': datetime.now(timezone.utc).isoformat(),
    'intake_validation_token': token,
    'consent_tokens': ${groovy.json.JsonOutput.toJson(meta.consent_tokens ?: [:])},
    'route_target': route_target,
    'token_sha256': hashlib.sha256(token.encode('utf-8')).hexdigest(),
}

with open(f"{sid}.intake_route_decision.json", 'w', encoding='utf-8') as handle:
    json.dump(payload, handle, indent=2)
PYEOF
    """

    stub:
    """
    printf '{"node":"EVALUATE_INTAKE_STATUS","sample_id":"%s","route_target":"PLATFORM_INIT_ROUTER","stub":true}' "${meta.sample_id}" > "${meta.sample_id}.intake_route_decision.json"
    """
}