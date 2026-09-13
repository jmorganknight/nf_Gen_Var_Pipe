process VERIFYBAMID2 {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    publishDir "${params.outdir}/audit_and_qc/stage2", mode: 'copy', overwrite: true, pattern: '*.contamination_audit.json'

    input:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path(precondition_audit)

    output:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path(precondition_audit), path("${meta.sample_id}.contamination_audit.json"), emit: validated

    script:
    def metaJson = groovy.json.JsonOutput.toJson(meta).replace('\\', '\\\\').replace("'", "\\'")
    def refsJson = groovy.json.JsonOutput.toJson(refs).replace('\\', '\\\\').replace("'", "\\'")
    def thresholdJson = groovy.json.JsonOutput.toJson(thresholds).replace('\\', '\\\\').replace("'", "\\'")
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def nested_get(payload, keys, default=None):
    cur = payload
    for key in keys:
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur


def as_bool(value, default=False):
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {'1', 'true', 'yes', 'y', 'on'}


meta = json.loads('${metaJson}')
refs = json.loads('${refsJson}')
thresholds = json.loads('${thresholdJson}')
sid = meta['sample_id']

limit = float(nested_get(thresholds, ['clinical', 'contamination', 'freemix_germline_limit'], 0.01))
fail_closed = as_bool(nested_get(thresholds, ['stage2', 'contamination_fail_closed'], True), True)

resources = {
    'verifybamid2_svd_prefix': refs.get('verifybamid2_svd_prefix') or refs.get('stage2_verifybamid2_svd_prefix'),
    'verifybamid2_ud_path': refs.get('verifybamid2_ud') or refs.get('verifybamid2_ud_path') or refs.get('stage2_verifybamid2_ud_path'),
    'verifybamid2_bed': refs.get('verifybamid2_bed') or refs.get('capture_wes_bed') or refs.get('onco_target_bed'),
}

required = ['verifybamid2_svd_prefix', 'verifybamid2_ud_path', 'verifybamid2_bed']
missing = []
for key in required:
    path_text = resources.get(key)
    if not path_text or not Path(path_text).exists():
        missing.append(f"{key}={path_text}")

sample_type = str(meta.get('sample_type') or 'germline').lower()
freemix = None
failure = None
status = 'PASS'
method = 'VerifyBamID2'
result_path = Path(f"{sid}.VerifyBamID2.selfSM")

if missing:
    failure = 'missing VerifyBamID2 reference assets: ' + ', '.join(missing)
else:
    cmd = [
        'VerifyBamID',
        '--NumThread', '2',
        '--BamFile', '${bam}',
        '--Reference', str(refs.get('reference_genome')),
        '--SVDPrefix', str(resources['verifybamid2_svd_prefix']),
        '--UDPath', str(resources['verifybamid2_ud_path']),
        '--BedPath', str(resources['verifybamid2_bed']),
        '--Output', sid,
    ]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        failure = f"VerifyBamID2 execution failed (exit={proc.returncode}): {proc.stderr.strip()}"
    elif not result_path.exists():
        failure = f"VerifyBamID2 completed but output missing: {result_path}"
    else:
        header = None
        values = None
        for line in result_path.read_text(encoding='utf-8', errors='replace').splitlines():
            striped = line.strip()
            if not striped:
                continue
            if striped.startswith('#SEQ_ID'):
                header = re.split(r'\s+', striped.lstrip('#'))
                continue
            if striped.startswith('#'):
                continue
            values = re.split(r'\s+', striped)
            break
        if not header or not values:
            failure = f"unable to parse VerifyBamID2 output: {result_path}"
        else:
            row = dict(zip(header, values))
            try:
                freemix = float(row.get('FREEMIX', 'nan'))
            except ValueError:
                freemix = None
                failure = f"invalid FREEMIX in VerifyBamID2 output: {row.get('FREEMIX')}"

if freemix is not None and freemix > limit:
    failure = f"contamination_rate {freemix:.6f} exceeds contamination limit {limit:.6f}"

if failure and fail_closed:
    status = 'FAIL'

payload = {
    'node': 'VERIFYBAMID2',
    'sample_id': sid,
    'timestamp_utc': datetime.now(timezone.utc).isoformat(),
    'status': status,
    'method': method,
    'sample_type': sample_type,
    'contamination_rate': freemix,
    'contamination_limit': limit,
    'fail_closed_enabled': fail_closed,
    'fail_closed_rule': f'STAGE2_CONTAMINATION_FAILURE when contamination_rate > {limit:.6f}',
    'verifybamid2_references': resources,
    'precondition_audit': '${precondition_audit}',
}

if failure and status == 'FAIL':
    payload['failure_code'] = 'STAGE2_CONTAMINATION_FAILURE'
    payload['failure_detail'] = failure
elif failure:
    payload['warning_detail'] = failure

Path(f"{sid}.contamination_audit.json").write_text(json.dumps(payload, indent=2) + '\\n', encoding='utf-8')

if payload['status'] == 'FAIL':
    print('STAGE2_CONTAMINATION_FAILURE: ' + failure, file=sys.stderr)
    sys.exit(1)
PYEOF
    """

    stub:
    """
    cat > "${meta.sample_id}.contamination_audit.json" <<'JSON'
{
    "node": "VERIFYBAMID2",
    "sample_id": "${meta.sample_id}",
    "status": "PASS",
    "method": "VerifyBamID2",
    "sample_type": "${meta.sample_type ?: 'germline'}",
    "contamination_rate": 0.0025,
    "contamination_limit": 0.01,
    "fail_closed_rule": "STAGE2_CONTAMINATION_FAILURE when contamination_rate > 0.01",
    "stub": true
}
JSON
    """
}
