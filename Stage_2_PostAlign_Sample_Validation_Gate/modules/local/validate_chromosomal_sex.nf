process VALIDATE_CHROMOSOMAL_SEX {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    publishDir "${params.outdir}/audit_and_qc/stage2", mode: 'copy', overwrite: true, pattern: '*.purity_and_sex_validation_audit.json'

    input:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path(precondition_audit), path(contamination_audit)

    output:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path(precondition_audit), path(contamination_audit), path("${meta.sample_id}.purity_and_sex_validation_audit.json"), emit: validated

    script:
    def metaJson = groovy.json.JsonOutput.toJson(meta).replace('\\', '\\\\').replace("'", "\\'")
    def thresholdJson = groovy.json.JsonOutput.toJson(thresholds).replace('\\', '\\\\').replace("'", "\\'")
    """
    set -euo pipefail

    samtools idxstats "${bam}" > idxstats.tsv

    python3 - <<'PYEOF'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
import subprocess


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
    text = str(value).strip().lower()
    return text in {'1', 'true', 'yes', 'y', 'on'}


meta = json.loads('${metaJson}')
thresholds = json.loads('${thresholdJson}')
sid = meta['sample_id']
expected = str(meta.get('reported_sex') or 'UNKNOWN').upper()
ratio_cutoff = float(nested_get(thresholds, ['clinical', 'qc_thresholds', 'chromosome_y_depth_floor'], 0.15))
fail_closed = as_bool(nested_get(thresholds, ['stage2', 'sex_concordance_fail_closed'], False), False)

contig_names = set()
for line in Path('idxstats.tsv').read_text(encoding='utf-8', errors='replace').splitlines():
    cols = line.split('\t')
    if len(cols) >= 1 and cols[0] != '*':
        contig_names.add(cols[0])

if 'chrX' in contig_names and 'chrY' in contig_names:
    x_contig = 'chrX'
    y_contig = 'chrY'
elif 'X' in contig_names and 'Y' in contig_names:
    x_contig = 'X'
    y_contig = 'Y'
else:
    x_contig = 'chrX'
    y_contig = 'chrY'

# GRCh38 non-PAR intervals (1-based, inclusive): PAR1+PAR2 masked out.
x_region = f"{x_contig}:2781480-155701382"
y_region = f"{y_contig}:2781480-56887902"


def mean_depth(region: str):
    cmd = ['samtools', 'depth', '-aa', '-r', region, '${bam}']
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    total = 0
    n = 0
    assert proc.stdout is not None
    for raw in proc.stdout:
        parts = raw.split('\t')
        if len(parts) != 3:
            continue
        try:
            total += int(parts[2])
            n += 1
        except ValueError:
            continue
    stderr_text = proc.stderr.read() if proc.stderr else ''
    exit_code = proc.wait()
    if exit_code != 0:
        raise RuntimeError(f"samtools depth failed for {region}: {stderr_text.strip()}")
    return (float(total) / float(n)) if n > 0 else 0.0, total, n


try:
    x_mean_depth, x_depth_sum, x_nonpar_bases = mean_depth(x_region)
    y_mean_depth, y_depth_sum, y_nonpar_bases = mean_depth(y_region)
except Exception as exc:
    print('STAGE2_SEX_CONCORDANCE_FAILURE: ' + str(exc), file=sys.stderr)
    sys.exit(1)

ratio = float(y_mean_depth) / float(x_mean_depth if x_mean_depth > 0 else 1.0)
computed_sex = 'UNKNOWN'
if x_mean_depth > 0:
    computed_sex = 'XY' if ratio >= ratio_cutoff else 'XX'

discordant = False
if expected == 'XX' and ratio >= ratio_cutoff:
    discordant = True
elif expected == 'XY' and ratio < ratio_cutoff:
    discordant = True

audit = {
    'node': 'VALIDATE_CHROMOSOMAL_SEX',
    'sample_id': sid,
    'timestamp_utc': datetime.now(timezone.utc).isoformat(),
    'status': 'PASS',
    'sex_concordance': {
        'expected_sex': expected,
        'computed_sex': computed_sex,
        'sex_concordance_pass': not discordant,
        'x_nonpar_region': x_region,
        'y_nonpar_region': y_region,
        'x_nonpar_bases': x_nonpar_bases,
        'y_nonpar_bases': y_nonpar_bases,
        'x_nonpar_depth_sum': x_depth_sum,
        'y_nonpar_depth_sum': y_depth_sum,
        'x_nonpar_mean_depth': x_mean_depth,
        'y_nonpar_mean_depth': y_mean_depth,
        'chr_y_to_chr_x_nonpar_ratio': ratio,
        'ratio_cutoff': ratio_cutoff,
        'discordant': discordant,
        'fail_closed_enabled': fail_closed,
    },
    'purity_validation': {
        'status': 'PENDING',
        'note': 'Purity resolver updates this section in the next Stage 2 node.'
    },
    'precondition_audit': '${precondition_audit}',
    'contamination_audit': '${contamination_audit}'
}

if discordant and fail_closed:
    audit['status'] = 'FAIL'
    audit['failure_code'] = 'STAGE2_SEX_CONCORDANCE_FAILURE'

audit_path = Path(f"{sid}.purity_and_sex_validation_audit.json")
audit_path.write_text(json.dumps(audit, indent=2) + '\\n', encoding='utf-8')

if audit['status'] == 'FAIL':
    print(
        f"STAGE2_SEX_CONCORDANCE_FAILURE: expected={expected}; computed={computed_sex}; nonpar_ratio={ratio:.4f}; cutoff={ratio_cutoff}",
        file=sys.stderr,
    )
    sys.exit(1)
PYEOF
    """

        stub:
        """
        cat > "${meta.sample_id}.purity_and_sex_validation_audit.json" <<'JSON'
{
    "node": "VALIDATE_CHROMOSOMAL_SEX",
    "sample_id": "${meta.sample_id}",
    "status": "PASS",
    "sex_concordance": {
        "expected_sex": "${meta.reported_sex ?: 'UNKNOWN'}",
        "computed_sex": "XY",
        "sex_concordance_pass": true,
        "stub": true
    },
    "purity_validation": {
        "status": "PENDING",
        "stub": true
    },
    "precondition_audit": "${precondition_audit}",
    "contamination_audit": "${contamination_audit}"
}
JSON
        """
}
