process STAGE3_TRISOMY_ANEUPLOIDY {
    label 'process_medium'
    container 'genvar-core:2.1.0'
    cpus { (params.stage3_trisomy_cpus ?: params.stage3_cpus ?: params.stage3_process_medium_default_cpus ?: 4) as int }

    input:
    tuple val(sample_id), path(stage2_manifest), path(sorted_bam), path(sorted_bai), val(is_wgs), val(target_bed), path(fasta), path(fasta_fai), val(sample_qc_meta), val(stage3_refs), val(sample_meta)

    output:
    tuple val(sample_id), path('trisomy_aneuploidy.calibrated.vcf'), path('stage3.trisomy_aneuploidy.audit.json'), val(stage3_refs), val(sample_meta), emit: calibrated_vcf
    path 'stage3.trisomy_aneuploidy.audit.json', emit: audit

    script:
    def sampleMetaJson = groovy.json.JsonOutput.toJson(sample_meta).replace('\\', '\\\\').replace("'", "\\'")
    """
    set -euo pipefail

    if ! command -v samtools >/dev/null 2>&1; then
        echo "STAGE3_PRECONDITION_FAILURE: samtools missing for trisomy_aneuploidy branch" >&2
        exit 1
    fi

    samtools idxstats "${sorted_bam}" > trisomy.idxstats.tsv

    python3 - <<'PYEOF'
import json
import statistics
from pathlib import Path

idxstats = Path('trisomy.idxstats.tsv')
out_vcf = Path('trisomy_aneuploidy.calibrated.vcf')
sample_meta = json.loads('${sampleMetaJson}')
thresholds = sample_meta.get('stage3_discovery_thresholds', {}) if isinstance(sample_meta, dict) else {}
ratio_threshold = float(thresholds.get('trisomy_ratio_threshold', 1.35))
z_threshold = float(thresholds.get('trisomy_z_threshold', 3.0))

rows = []
for line in idxstats.read_text(encoding='utf-8', errors='replace').splitlines():
    cols = line.split(chr(9))
    if len(cols) < 4:
        continue
    chrom = cols[0]
    if chrom == '*':
        continue
    try:
        mapped = int(cols[2])
    except Exception:
        mapped = 0
    rows.append((chrom, mapped))

coverage_by_chr = {chrom: mapped for chrom, mapped in rows}
autosomes = [coverage_by_chr.get(f'chr{i}', coverage_by_chr.get(str(i), 0)) for i in range(1, 23)]
autosome_nonzero = [x for x in autosomes if x > 0]

if not autosome_nonzero:
    raise SystemExit('STAGE3_PRECONDITION_FAILURE: idxstats had zero mapped reads across autosomes')

median_auto = statistics.median(autosome_nonzero)
mean_auto = statistics.mean(autosome_nonzero)
stdev_auto = statistics.pstdev(autosome_nonzero) if len(autosome_nonzero) > 1 else 0.0

candidates = []
for chrom in ['chr13', 'chr18', 'chr21', '13', '18', '21']:
    if chrom not in coverage_by_chr:
        continue
    mapped = coverage_by_chr[chrom]
    ratio = float(mapped) / float(median_auto) if median_auto > 0 else 0.0
    z = (mapped - mean_auto) / stdev_auto if stdev_auto > 0 else 0.0
    canonical = chrom if chrom.startswith('chr') else f'chr{chrom}'
    candidates.append((canonical, mapped, ratio, z))

calls = [entry for entry in candidates if entry[2] >= ratio_threshold and entry[3] >= z_threshold]

with out_vcf.open('w', encoding='utf-8') as out:
    out.write('##fileformat=VCFv4.2' + chr(10))
    out.write('##source=STAGE3_TRISOMY_ANEUPLOIDY' + chr(10))
    out.write('##INFO=<ID=BRANCH,Number=1,Type=String,Description="Stage 3 variant branch origin">' + chr(10))
    out.write('##INFO=<ID=ANEUPLOIDY,Number=1,Type=String,Description="Detected aneuploidy class">' + chr(10))
    out.write('##INFO=<ID=CHR_COV_RATIO,Number=1,Type=Float,Description="Chromosome mapped-read ratio vs autosome median">' + chr(10))
    out.write('##INFO=<ID=CHR_COV_Z,Number=1,Type=Float,Description="Chromosome mapped-read z-score vs autosomes">' + chr(10))
    out.write('#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO' + chr(10))
    for chrom, mapped, ratio, z in calls:
        info = f'ANEUPLOIDY=TRISOMY;CHR_COV_RATIO={ratio:.6f};CHR_COV_Z={z:.6f};MAPPED={mapped};BRANCH=trisomy_aneuploidy'
        out.write(f'{chrom}\t1\t.\tN\t<TRISOMY>\t60\tPASS\t{info}' + chr(10))

audit = {
    'sample_id': '${sample_id}',
    'stage2_manifest': str(Path('${stage2_manifest}').resolve()),
    'sorted_bam': str(Path('${sorted_bam}').resolve()),
    'sorted_bai': str(Path('${sorted_bai}').resolve()),
    'idxstats_tsv': str(idxstats.resolve()),
    'autosome_median_mapped': median_auto,
    'autosome_mean_mapped': mean_auto,
    'autosome_stdev_mapped': stdev_auto,
    'trisomy_ratio_threshold': ratio_threshold,
    'trisomy_z_threshold': z_threshold,
    'candidates': [
        {'chrom': chrom, 'mapped': mapped, 'ratio': ratio, 'zscore': z}
        for chrom, mapped, ratio, z in candidates
    ],
    'calls': [
        {'chrom': chrom, 'mapped': mapped, 'ratio': ratio, 'zscore': z}
        for chrom, mapped, ratio, z in calls
    ],
    'records_emitted': len(calls),
    'status': 'PASS',
}
Path('stage3.trisomy_aneuploidy.audit.json').write_text(json.dumps(audit, indent=2) + chr(10), encoding='utf-8')
PYEOF
    """

    stub:
    """
    cat > trisomy_aneuploidy.calibrated.vcf <<'VCF'
##fileformat=VCFv4.2
##source=STAGE3_TRISOMY_ANEUPLOIDY_STUB
##INFO=<ID=BRANCH,Number=1,Type=String,Description="Stage 3 variant branch origin">
#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
21\t1000000\t.\tN\t<TRISOMY>\t60\tPASS\tSVTYPE=ANEUPLOIDY;CHROM=21;ZSCORE=3.5;BRANCH=trisomy_aneuploidy
VCF
    cat > stage3.trisomy_aneuploidy.audit.json <<'JSON'
{
  "sample_id": "${sample_id}",
  "stage2_manifest": "stub_path",
  "sorted_bam": "stub_path",
  "sorted_bai": "stub_path",
  "idxstats_tsv": "stub_path",
  "autosome_median_mapped": 50000000,
  "autosome_mean_mapped": 50000000,
  "autosome_stdev_mapped": 5000000,
  "trisomy_ratio_threshold": 1.3,
  "trisomy_z_threshold": 2.5,
  "candidates": [{"chrom": "21", "mapped": 75000000, "ratio": 1.5, "zscore": 3.5}],
  "calls": [{"chrom": "21", "mapped": 75000000, "ratio": 1.5, "zscore": 3.5}],
  "records_emitted": 1,
  "status": "PASS",
  "stub": true
}
JSON
    """
}
