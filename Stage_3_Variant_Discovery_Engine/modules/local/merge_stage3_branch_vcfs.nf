def toSerializableValue(Object value) {
    if (value instanceof Map) {
        def copied = new LinkedHashMap()
        (value as Map).each { key, nested -> copied[key] = toSerializableValue(nested) }
        return copied
    }
    if (value instanceof List) {
        return (value as List).collect { nested -> toSerializableValue(nested) }
    }
    value
}

process MERGE_STAGE3_BRANCH_VCFS {

    label 'process_low'
    container 'genvar-core:2.1.0'

    input:
    tuple val(sample_id), val(branch_names), path(selected_vcfs), path(mane_audits), path(calibration_audits), path(vcf_schema), val(stage3_refs), val(sample_meta)

    output:
    tuple val(sample_id), path('stage3.merged.selected.vcf'), path('stage3.merged.mane_audit.json'), path(vcf_schema), val(stage3_refs), val(sample_meta), path('stage3.merged.calibration_audit.json'), emit: merged_vcf_bundle

    script:
    def safeSampleMetaMap = (sample_meta instanceof Map) ? (toSerializableValue(sample_meta) as Map) : [:]
    def sampleMetaJson = groovy.json.JsonOutput.toJson(safeSampleMetaMap).replace('\\', '\\\\').replace("'", "\\'")
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path

NL = chr(10)
TAB = chr(9)

sample_id = ${groovy.json.JsonOutput.toJson(sample_id)}
sample_meta = json.loads('${sampleMetaJson}')
branch_names = ${groovy.json.JsonOutput.toJson(branch_names)}

vcf_paths = sorted([Path(p) for p in ${groovy.json.JsonOutput.toJson(selected_vcfs.collect { pathObj -> pathObj.toString() })}])
mane_paths = sorted([Path(p) for p in ${groovy.json.JsonOutput.toJson(mane_audits.collect { pathObj -> pathObj.toString() })}])
calibration_paths = sorted([Path(p) for p in ${groovy.json.JsonOutput.toJson(calibration_audits.collect { pathObj -> pathObj.toString() })}])

if not vcf_paths:
    raise SystemExit('STAGE3_MERGE_FAILURE: no VCF inputs to merge')

branch_plan = sample_meta.get('stage3_branch_plan') or {}
expected_active_count = int(sample_meta.get('expected_active_branch_count') or 0)
if expected_active_count <= 0:
    expected_active_count = sum(1 for info in branch_plan.values() if bool((info or {}).get('requested')))

if len(vcf_paths) != expected_active_count:
    raise SystemExit(
        f"STAGE3_BRANCH_SYNCHRONIZATION_FAILURE: expected {expected_active_count} branch payloads but received {len(vcf_paths)} for sample {sample_id}"
    )


def chrom_rank(chrom: str):
    norm = chrom.strip()
    if norm.lower().startswith('chr'):
        norm = norm[3:]
    upper = norm.upper()
    if upper.isdigit():
        return (0, int(upper))
    if upper == 'X':
        return (1, 23)
    if upper == 'Y':
        return (1, 24)
    if upper in ('M', 'MT'):
        return (1, 25)
    return (2, upper)


fileformat_line = None
meta_headers = []
column_header_candidates = []
seen_headers = set()
observed_branches = set()
records = []

for src_index, vcf in enumerate(vcf_paths):
    lines = vcf.read_text(encoding='utf-8', errors='replace').splitlines()
    for line_index, line in enumerate(lines):
        if line.startswith('##fileformat='):
            if fileformat_line is None:
                fileformat_line = line
            continue
        if line.startswith('##'):
            if line not in seen_headers:
                seen_headers.add(line)
                meta_headers.append(line)
            continue
        if line.startswith('#CHROM'):
            column_header_candidates.append(line)
            continue
        if not line.strip():
            continue
        cols = line.split(TAB)
        if len(cols) < 8:
            continue
        info_map = {}
        for token in cols[7].split(';'):
            if '=' in token:
                k, v = token.split('=', 1)
                info_map[k] = v
        branch_name = info_map.get('BRANCH')
        if branch_name:
            observed_branches.add(branch_name)
        chrom = cols[0]
        try:
            pos = int(cols[1])
        except ValueError:
            pos = 0
        key = (chrom_rank(chrom), pos, cols[3], cols[4], src_index, line_index)
        records.append((key, cols))

if fileformat_line is None:
    fileformat_line = '##fileformat=VCFv4.2'
if not column_header_candidates:
    raise SystemExit('STAGE3_MERGE_FAILURE: merged VCF missing #CHROM header')

column_header = max(column_header_candidates, key=lambda line: len(line.split(TAB)))
selected_header_cols = column_header.split(TAB)
selected_col_count = len(selected_header_cols)
records_padded = 0
records_trimmed = 0

ordered_records = []
for _key, cols in sorted(records, key=lambda pair: pair[0]):
    out_cols = list(cols)
    if len(out_cols) < selected_col_count:
        if selected_col_count >= 10 and len(out_cols) == 8:
            out_cols.append('GT')
            out_cols.append('./.')
        while len(out_cols) < selected_col_count:
            out_cols.append('.')
        records_padded += 1
    elif len(out_cols) > selected_col_count:
        out_cols = out_cols[:selected_col_count]
        records_trimmed += 1
    ordered_records.append(TAB.join(out_cols))

out_vcf = Path('stage3.merged.selected.vcf')
out_vcf.write_text(NL.join([fileformat_line] + meta_headers + [column_header] + ordered_records) + NL, encoding='utf-8')

merge_mane_audit = {
    'sample_id': sample_id,
    'node': 'MERGE_STAGE3_BRANCH_VCFS',
    'source_mane_audits': [str(p.resolve()) for p in mane_paths],
    'source_vcfs': [str(p.resolve()) for p in vcf_paths],
    'expected_branches': sorted(branch_names),
    'expected_active_branch_count': expected_active_count,
    'received_branch_payload_count': len(vcf_paths),
    'observed_branches': sorted(observed_branches),
    'selected_header_columns': selected_col_count,
    'sample_columns_present': selected_col_count >= 10,
    'records_padded_to_header': records_padded,
    'records_trimmed_to_header': records_trimmed,
    'branch_tokens': {
        name: (
            'SKIPPED_BY_MANIFEST'
            if not bool((meta or {}).get('requested'))
            else ('COMPLETED_PAYLOAD_MERGED' if name in observed_branches else 'COMPLETED_NO_VARIANTS')
        )
        for name, meta in sorted(branch_plan.items())
    },
    'merged_record_count': len(ordered_records),
    'status': 'PASS'
}
Path('stage3.merged.mane_audit.json').write_text(json.dumps(merge_mane_audit, indent=2) + NL, encoding='utf-8')

merge_calibration_audit = {
    'sample_id': sample_id,
    'node': 'MERGE_STAGE3_BRANCH_VCFS',
    'source_calibration_audits': [str(p.resolve()) for p in calibration_paths],
    'status': 'PASS'
}
Path('stage3.merged.calibration_audit.json').write_text(json.dumps(merge_calibration_audit, indent=2) + NL, encoding='utf-8')
PYEOF
    """

    stub:
    """
    cp "${selected_vcfs[0]}" stage3.merged.selected.vcf
    cat > stage3.merged.mane_audit.json <<'JSON'
{
  "sample_id": "${sample_id}",
  "node": "MERGE_STAGE3_BRANCH_VCFS",
  "status": "PASS",
  "stub": true
}
JSON
    cat > stage3.merged.calibration_audit.json <<'JSON'
{
  "sample_id": "${sample_id}",
  "node": "MERGE_STAGE3_BRANCH_VCFS",
  "status": "PASS",
  "stub": true
}
JSON
    """
}
