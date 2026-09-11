process VALIDATE_CHROMOSOMAL_SEX {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    publishDir "${params.outdir}/audit_and_qc/stage2", mode: 'copy', overwrite: true, pattern: '*.purity_and_sex_validation_audit.json'

    input:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path(precondition_audit)

    output:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path(precondition_audit), path("${meta.sample_id}.purity_and_sex_validation_audit.json"), emit: validated

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

x_reads = 0
y_reads = 0
for line in Path('idxstats.tsv').read_text(encoding='utf-8', errors='replace').splitlines():
    cols = line.split('\t')
    if len(cols) < 3:
        continue
    chrom = cols[0].strip().lower()
    mapped = int(cols[2])
    if chrom in {'x', 'chrx'}:
        x_reads += mapped
    elif chrom in {'y', 'chry'}:
        y_reads += mapped

ratio = float(y_reads) / float(x_reads if x_reads > 0 else 1)
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
        'chr_x_mapped_reads': x_reads,
        'chr_y_mapped_reads': y_reads,
        'chr_y_to_chr_x_ratio': ratio,
        'ratio_cutoff': ratio_cutoff,
        'discordant': discordant,
        'fail_closed_enabled': fail_closed,
    },
    'purity_validation': {
        'status': 'PENDING',
        'note': 'Purity resolver updates this section in the next Stage 2 node.'
    },
    'precondition_audit': '${precondition_audit}'
}

if discordant and fail_closed:
    audit['status'] = 'FAIL'
    audit['failure_code'] = 'STAGE2_SEX_CONCORDANCE_FAILURE'

audit_path = Path(f"{sid}.purity_and_sex_validation_audit.json")
audit_path.write_text(json.dumps(audit, indent=2) + '\\n', encoding='utf-8')

if audit['status'] == 'FAIL':
    print(
        f"STAGE2_SEX_CONCORDANCE_FAILURE: expected={expected}; ratio={ratio:.4f}; cutoff={ratio_cutoff}",
        file=sys.stderr,
    )
    sys.exit(1)
PYEOF
    """
}
