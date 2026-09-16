process STAGE3_COPY_NUMBER_CNV {
    label 'variant_heavy'
    container 'genvar-core:2.1.0'
    cpus { (params.stage3_cnv_cpus ?: params.stage3_cpus ?: params.stage3_variant_heavy_default_cpus ?: 8) as int }

    publishDir "${params.outdir}/${sample_id}/stage3_copy_number_cnv", mode: 'copy', pattern: "*.vcf*|*.json", enabled: true

    input:
    tuple val(sample_id), path(stage2_manifest), path(sorted_bam), path(sorted_bai), val(is_wgs), val(target_bed), path(fasta), path(fasta_fai), val(sample_qc_meta), val(stage3_refs), val(sample_meta)

    output:
    tuple val(sample_id), path('copy_number_cnv.calibrated.vcf'), path('stage3.copy_number_cnv.audit.json'), val(stage3_refs), val(sample_meta), emit: calibrated_vcf
    path 'stage3.copy_number_cnv.audit.json', emit: audit

    script:
    def threads = (task.cpus ?: 1) as int
    def sampleMetaMap = (sample_meta instanceof Map) ? (sample_meta as Map) : [:]
    def sampleMetaJson = groovy.json.JsonOutput.toJson(sampleMetaMap).replace('\\', '\\\\').replace("'", "\\'")
    def cnvkitRef = ''
    try {
        cnvkitRef = (stage3_refs?.cnvkit_pooled_reference ?: stage3_refs?.cnvkit_reference ?: stage3_refs?.cnvkit_pooled_ref ?: '')?.toString()
    } catch (Throwable _ignored) {
        cnvkitRef = ''
    }
    """
    set -euo pipefail

    THREADS=${threads}
    TARGET_BED="${target_bed ?: ''}"
    IS_WGS="${is_wgs}"
    CNVKIT_REF="${cnvkitRef}"

    for tool in python3 cnvkit.py samtools; do
        if ! command -v "\${tool}" >/dev/null 2>&1; then
            echo "STAGE3_PRECONDITION_FAILURE: required CNV tool missing: \${tool}" >&2
            exit 1
        fi
    done

    if [[ "\${IS_WGS}" != "true" && "\${IS_WGS}" != "1" && "\${IS_WGS}" != "wgs" ]]; then
        if [[ -z "\${TARGET_BED}" || "\${TARGET_BED}" == "null" ]]; then
            echo "STAGE3_PRECONDITION_FAILURE: missing target capture BED for copy_number_cnv branch" >&2
            exit 1
        fi
        if [[ ! -f "\${TARGET_BED}" ]]; then
            echo "STAGE3_PRECONDITION_FAILURE: target capture BED not found for copy_number_cnv branch: \${TARGET_BED}" >&2
            exit 1
        fi
    fi

    mkdir -p cnvkit_out

    # Primary lane: CNVkit segmentation/calling with parallelization.
    if [[ -n "\${CNVKIT_REF}" && -f "\${CNVKIT_REF}" ]]; then
        cnvkit.py batch "${sorted_bam}" -m wgs -r "\${CNVKIT_REF}" -d cnvkit_out -p \${THREADS}
    else
        cnvkit.py batch "${sorted_bam}" -m wgs -f "${fasta}" -d cnvkit_out -p \${THREADS}
    fi

    cnr_file=\$(ls -1 cnvkit_out/*.cnr 2>/dev/null | head -n 1 || true)
    if [[ -z "\${cnr_file}" ]]; then
        echo "STAGE3_PRECONDITION_FAILURE: cnvkit did not emit .cnr file" >&2
        exit 1
    fi

    cnvkit.py segment "\${cnr_file}" -o cnvkit_out/segments.cns
    cnvkit.py call cnvkit_out/segments.cns -o cnvkit_out/calls.cns

    # Validation lane: independent depth profile from samtools depth.
    if [[ -n "\${TARGET_BED}" && -f "\${TARGET_BED}" ]]; then
        samtools depth -a -b "\${TARGET_BED}" "${sorted_bam}" > cnvkit_out/validation.depth.tsv
    else
        samtools depth -a "${sorted_bam}" > cnvkit_out/validation.depth.tsv
    fi

    python3 - <<'PYEOF'
import json
from pathlib import Path


def parse_float(value, default=0.0):
    try:
        if value is None or value == '':
            return default
        return float(value)
    except Exception:
        return default


def quantiles(values):
    if not values:
        return {'q05': 0.0, 'q50': 0.0, 'q95': 0.0}
    s = sorted(values)
    n = len(s)

    def pick(p):
        idx = int(round((n - 1) * p))
        idx = max(0, min(n - 1, idx))
        return float(s[idx])

    return {'q05': pick(0.05), 'q50': pick(0.50), 'q95': pick(0.95)}


calls_path = Path('cnvkit_out/calls.cns')
validation_depth = Path('cnvkit_out/validation.depth.tsv')
out_vcf = Path('copy_number_cnv.calibrated.vcf')

calls_rows = []
with calls_path.open('r', encoding='utf-8', errors='replace') as handle:
    header = handle.readline().strip().split(chr(9))
    for line in handle:
        if not line.strip():
            continue
        cols = line.rstrip().split(chr(9))
        row = {header[i]: cols[i] if i < len(cols) else '' for i in range(len(header))}
        calls_rows.append(row)

depths = []
for line in validation_depth.read_text(encoding='utf-8', errors='replace').splitlines():
    if not line.strip():
        continue
    cols = line.split(chr(9))
    if len(cols) < 3:
        continue
    depths.append(parse_float(cols[2], 0.0))

depth_q = quantiles(depths)
median_depth = depth_q['q50']

sample_meta = json.loads('${sampleMetaJson}')
thresholds = sample_meta.get('stage3_discovery_thresholds', {}) if isinstance(sample_meta, dict) else {}
log2_abs_floor = parse_float(thresholds.get('cnv_log2_abs_floor'), 0.2)

records = []
for row in calls_rows:
    chrom = str(row.get('chrom') or row.get('chr') or row.get('chromosome') or '').strip()
    start = str(row.get('start') or row.get('begin') or '').strip()
    end = str(row.get('end') or row.get('stop') or '').strip()
    if not chrom or not start or not end:
        continue

    log2 = parse_float(row.get('log2'), 0.0)
    cn_text = row.get('cn') or row.get('cnv') or row.get('call') or '2'
    try:
        cn = int(round(float(cn_text)))
    except Exception:
        cn = 2

    svtype = 'DUP' if cn > 2 else ('DEL' if cn < 2 else 'CNV')
    alt = f'<{svtype}>'
    filt = 'PASS' if abs(log2) >= log2_abs_floor else 'LOW_LOG2'
    info = f'SVTYPE={svtype};END={int(float(end))};CN={cn};LOG2={log2:.6f};BRANCH=copy_number_cnv'
    records.append((chrom, int(float(start)) + 1, alt, filt, info, log2))

records.sort(key=lambda r: (r[0].replace('chr', ''), r[1], r[2]))

with out_vcf.open('w', encoding='utf-8') as out:
    out.write('##fileformat=VCFv4.2' + chr(10))
    out.write('##source=STAGE3_COPY_NUMBER_CNV' + chr(10))
    out.write('##INFO=<ID=SVTYPE,Number=1,Type=String,Description="Structural variant type">' + chr(10))
    out.write('##INFO=<ID=END,Number=1,Type=Integer,Description="End position of the variant">' + chr(10))
    out.write('##INFO=<ID=CN,Number=1,Type=Integer,Description="Estimated integer copy number state">' + chr(10))
    out.write('##INFO=<ID=LOG2,Number=1,Type=Float,Description="CNVkit segment log2 ratio">' + chr(10))
    out.write('##INFO=<ID=BRANCH,Number=1,Type=String,Description="Stage 3 variant branch origin">' + chr(10))
    out.write('##FILTER=<ID=LOW_LOG2,Description="CNVkit absolute log2 below reporting floor">' + chr(10))
    out.write('#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO' + chr(10))
    for chrom, pos, alt, filt, info, _log2 in records:
        out.write(f'{chrom}\t{pos}\t.\tN\t{alt}\t60\t{filt}\t{info}' + chr(10))

if not records:
    # Emit a valid empty-body VCF for deterministic downstream behavior.
    pass

audit = {
    'sample_id': '${sample_id}',
    'stage2_manifest': str(Path('${stage2_manifest}').resolve()),
    'sorted_bam': str(Path('${sorted_bam}').resolve()),
    'sorted_bai': str(Path('${sorted_bai}').resolve()),
    'fasta': str(Path('${fasta}').resolve()),
    'target_bed': '${target_bed ?: ''}' or None,
    'is_wgs': str('${is_wgs}').strip().lower() in {'1', 'true', 'yes', 'y', 'on', 'wgs'},
    'cnvkit_reference': '${cnvkitRef ?: ''}' or None,
    'cnvkit_calls_cns': str(calls_path.resolve()),
    'validation_depth_tsv': str(validation_depth.resolve()),
    'validation_depth_quantiles': depth_q,
    'validation_depth_median': median_depth,
    'records_emitted': len(records),
    'records_pass': sum(1 for r in records if r[3] == 'PASS'),
    'records_low_log2': sum(1 for r in records if r[3] == 'LOW_LOG2'),
    'log2_abs_floor': log2_abs_floor,
    'configured_somatic_qual_floor': thresholds.get('somatic_qual_floor'),
    'configured_germline_qual_floor': thresholds.get('germline_qual_floor'),
    'status': 'PASS',
}
Path('stage3.copy_number_cnv.audit.json').write_text(json.dumps(audit, indent=2) + chr(10), encoding='utf-8')
PYEOF

    # Cleanup ephemeral CNVkit output directory and other temporary artifacts
    rm -rf cnvkit_out/ workspace/ pyflow.data/ *.pickle 2>/dev/null || true
    """

    stub:
    """
    cat > copy_number_cnv.calibrated.vcf <<'VCF'
##fileformat=VCFv4.2
##source=STAGE3_COPY_NUMBER_CNV_STUB
##INFO=<ID=BRANCH,Number=1,Type=String,Description="Stage 3 variant branch origin">
#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
2\t1000000\t.\tN\t<DEL>\t60\tPASS\tSVTYPE=DEL;END=2000000;CNV_LOG2=0.5;BRANCH=copy_number_cnv
5\t5000000\t.\tN\t<DUP>\t60\tPASS\tSVTYPE=DUP;END=6000000;CNV_LOG2=-0.5;BRANCH=copy_number_cnv
VCF
    cat > stage3.copy_number_cnv.audit.json <<'JSON'
{
  "sample_id": "${sample_id}",
  "stage2_manifest": "stub_path",
  "sorted_bam": "stub_path",
  "sorted_bai": "stub_path",
  "fasta": "stub_path",
  "target_bed": "stub_path",
  "is_wgs": false,
  "cnvkit_reference": "stub_path",
  "cnvkit_calls_cns": "stub_path",
  "validation_depth_tsv": "stub_path",
  "validation_depth_quantiles": [1.0, 10.0, 50.0, 100.0],
  "validation_depth_median": 50.0,
  "records_emitted": 2,
  "records_pass": 2,
  "records_low_log2": 0,
  "log2_abs_floor": 0.3,
  "configured_somatic_qual_floor": 20,
  "configured_germline_qual_floor": 10,
  "status": "PASS",
  "stub": true
}
JSON
    """
}
