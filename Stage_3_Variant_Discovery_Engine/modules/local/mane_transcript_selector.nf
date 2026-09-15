process MANE_TRANSCRIPT_SELECTOR {

    label 'process_low'
    container 'genvar-core:2.1.0'

    input:
    tuple val(sample_id), val(branch_name), path(input_vcf), path(calibration_audit), path(mane_transcripts_file), path(vcf_schema), val(stage3_refs), val(sample_meta)

    output:
    tuple val(sample_id), val(branch_name), path("${sample_id}_${branch_name}.mane_selected.vcf"), path("${sample_id}_${branch_name}.mane_transcript_selector.audit.json"), path(vcf_schema), val(stage3_refs), val(sample_meta), path(calibration_audit), emit: selected_vcf

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path

NL = chr(10)
TAB = chr(9)

mane_file = Path('${mane_transcripts_file}')
if not mane_file.exists():
    raise SystemExit(f'STAGE3_PRECONDITION_FAILURE: MANE transcript asset missing: {mane_file}')


def parse_mane_records(path: Path):
    records = []
    for raw in path.read_text(encoding='utf-8', errors='replace').splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        cols = line.split(TAB)
        if len(cols) < 3:
            continue
        chrom = cols[0].replace('chr', '')
        try:
            start = int(cols[1])
            end = int(cols[2])
        except ValueError:
            continue

        label = ''
        transcript = ''
        if len(cols) >= 4:
            transcript = cols[3]
            label = cols[3]
        if len(cols) >= 5:
            label = cols[4]

        upper = (label + ' ' + transcript).upper()
        normalized_label = upper.replace('_', ' ').replace('-', ' ')
        if 'MANE PLUS CLINICAL' in normalized_label:
            priority = 2
            priority_name = 'MANE_PLUS_CLINICAL'
        elif 'MANE SELECT' in normalized_label:
            priority = 1
            priority_name = 'MANE_SELECT'
        else:
            priority = 0
            priority_name = 'NONE'

        records.append((chrom, start, end, priority, priority_name, transcript or 'NA'))
    return records


mane_records = parse_mane_records(mane_file)

header = []
body = []
for line in Path('${input_vcf}').read_text(encoding='utf-8', errors='replace').splitlines():
    if line.startswith('#'):
        header.append(line)
    elif line.strip():
        body.append(line)

if not any(h.startswith('##INFO=<ID=MANE_PRIORITY') for h in header):
    header.insert(len([h for h in header if h.startswith('##')]), '##INFO=<ID=MANE_PRIORITY,Number=1,Type=String,Description="MANE transcript priority (MANE_PLUS_CLINICAL > MANE_SELECT > NONE)">')
if not any(h.startswith('##INFO=<ID=MANE_TRANSCRIPT') for h in header):
    header.insert(len([h for h in header if h.startswith('##')]), '##INFO=<ID=MANE_TRANSCRIPT,Number=1,Type=String,Description="Selected MANE transcript identifier">')

mane_plus = 0
mane_select = 0
none = 0

selected_out = Path('${sample_id}_${branch_name}.mane_selected.vcf')
with selected_out.open('w', encoding='utf-8') as out:
    out.write(NL.join(header) + NL)
    for rec in body:
        cols = rec.split(TAB)
        if len(cols) < 8:
            continue
        chrom = cols[0].replace('chr', '')
        try:
            pos0 = int(cols[1]) - 1
        except ValueError:
            pos0 = -1

        best = (0, 'NONE', 'NA')
        for r_chrom, r_start, r_end, r_prio, r_name, r_tx in mane_records:
            if r_chrom != chrom:
                continue
            if r_start <= pos0 < r_end and r_prio >= best[0]:
                best = (r_prio, r_name, r_tx)

        info = cols[7] if cols[7] and cols[7] != '.' else ''
        append = f"MANE_PRIORITY={best[1]};MANE_TRANSCRIPT={best[2]}"
        cols[7] = append if not info else f"{info};{append}"

        if best[1] == 'MANE_PLUS_CLINICAL':
            mane_plus += 1
        elif best[1] == 'MANE_SELECT':
            mane_select += 1
        else:
            none += 1

        out.write(TAB.join(cols) + NL)

audit_out = Path('${sample_id}_${branch_name}.mane_transcript_selector.audit.json')
audit_out.write_text(
    json.dumps(
        {
            'sample_id': '${sample_id}',
            'branch_name': '${branch_name}',
            'node': 'MANE_TRANSCRIPT_SELECTOR',
            'mane_asset': str(mane_file.resolve()),
            'mane_plus_clinical_records': mane_plus,
            'mane_select_records': mane_select,
            'none_records': none,
            'status': 'PASS',
        },
        indent=2,
    )
    + NL,
    encoding='utf-8',
)
PYEOF
    """

    stub:
    """
    cp "${input_vcf}" "${sample_id}_${branch_name}.mane_selected.vcf"
    cat > "${sample_id}_${branch_name}.mane_transcript_selector.audit.json" <<'JSON'
{
  "sample_id": "${sample_id}",
  "branch_name": "${branch_name}",
  "node": "MANE_TRANSCRIPT_SELECTOR",
  "status": "PASS",
  "stub": true
}
JSON
    """
}
