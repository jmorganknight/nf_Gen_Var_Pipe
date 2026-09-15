process STAGE3_STRUCTURAL_VARIANTS {
    label 'variant_heavy'
    container 'genvar-core:2.1.0'
    cpus { (params.stage3_structural_variants_cpus ?: params.stage3_sv_cpus ?: params.stage3_cpus ?: params.stage3_variant_heavy_default_cpus ?: 8) as int }

    input:
    tuple val(sample_id), path(stage2_manifest), path(sorted_bam), path(sorted_bai), val(is_wgs), val(target_bed), path(fasta), path(fasta_fai), val(sample_qc_meta), val(stage3_refs), val(sample_meta)

    output:
    tuple val(sample_id), path('structural_variants.calibrated.vcf'), path('stage3.structural_variants.audit.json'), val(stage3_refs), val(sample_meta), emit: calibrated_vcf
    path 'stage3.structural_variants.audit.json', emit: audit

    publishDir "${params.outdir}/${sample_id}/stage3_structural_variants", mode: 'copy', pattern: "*.vcf*|*.json", enabled: true

    script:
    def threads = (task.cpus ?: 1) as int
    def sampleMetaJson = groovy.json.JsonOutput.toJson(sample_meta).replace('\\', '\\\\').replace("'", "\\'")
    """
    set -euo pipefail

    THREADS=${threads}
    IS_WGS="${is_wgs}"
    TARGET_BED="${target_bed ?: ''}"
    FASTA_FAI="${fasta_fai}"

    for tool in python3 bcftools tabix bgzip samtools configManta.py python2; do
        if ! command -v "\${tool}" >/dev/null 2>&1; then
            echo "STAGE3_PRECONDITION_FAILURE: required tool missing for structural_variants branch: \${tool}" >&2
            exit 1
        fi
    done

    manta_cli="\$(command -v configManta.py)"
    manta_script="\$(readlink -f "\${manta_cli}" || echo "\${manta_cli}")"

    if [[ ! -f "\${FASTA_FAI}" ]]; then
        echo "STAGE3_PRECONDITION_FAILURE: staged FASTA index input missing for structural_variants branch: \${FASTA_FAI}" >&2
        exit 1
    fi
    if [[ ! -f "${fasta}.fai" ]]; then
        cp -f "\${FASTA_FAI}" "${fasta}.fai"
    fi

    interval_args=()
    manta_mode_args=()
    shopt -s nocasematch
    if [[ "\${IS_WGS}" == "true" || "\${IS_WGS}" == "1" || "\${IS_WGS}" == "wgs" ]]; then
        use_intervals=false
    else
        use_intervals=true
        manta_mode_args+=(--exome)
        if [[ -z "\${TARGET_BED}" || "\${TARGET_BED}" == "null" ]]; then
            echo "STAGE3_PRECONDITION_FAILURE: missing target capture BED for non-WGS sample '${sample_id}'" >&2
            exit 1
        fi
        if [[ ! -f "\${TARGET_BED}" ]]; then
            echo "STAGE3_PRECONDITION_FAILURE: target capture BED not found for sample '${sample_id}': \${TARGET_BED}" >&2
            exit 1
        fi
        interval_args=(-R "\${TARGET_BED}")
    fi
    shopt -u nocasematch

        python2 "\${manta_script}" \
      --bam "${sorted_bam}" \
      --referenceFasta "${fasta}" \
      --runDir manta_run \
      "\${manta_mode_args[@]}"

    python2 manta_run/runWorkflow.py -m local -j "\${THREADS}"

    if [[ -s manta_run/results/variants/diploidSV.vcf.gz ]]; then
        if ! bcftools view -Ov manta_run/results/variants/diploidSV.vcf.gz > structural_variants.raw.vcf 2>/dev/null; then
            python3 - <<'PYEOF'
import gzip
from pathlib import Path

src = Path('manta_run/results/variants/diploidSV.vcf.gz')
dst = Path('structural_variants.raw.vcf')
with gzip.open(src, 'rt', encoding='utf-8', errors='replace') as inp, dst.open('w', encoding='utf-8') as out:
    out.write(inp.read())
PYEOF
        fi
    elif [[ -s manta_run/results/variants/diploidSV.vcf ]]; then
        bcftools view -Ov manta_run/results/variants/diploidSV.vcf > structural_variants.raw.vcf
    else
        echo "STAGE3_PRECONDITION_FAILURE: Manta did not emit diploidSV output for sample '${sample_id}'" >&2
        exit 1
    fi

    if [[ "\${use_intervals}" == "true" ]]; then
        bgzip -c structural_variants.raw.vcf > structural_variants.raw.vcf.gz
        tabix -f -p vcf structural_variants.raw.vcf.gz
        bcftools view "\${interval_args[@]}" -Ov -o structural_variants.onco_filtered.vcf structural_variants.raw.vcf.gz
    else
        cp structural_variants.raw.vcf structural_variants.onco_filtered.vcf
    fi

    python3 - <<'PYEOF'
import json
from pathlib import Path


def parse_qual(value):
    if value in (None, '', '.'):
        return None
    try:
        return float(value)
    except Exception:
        return None


def is_symbolic_alt(alt_token):
    alt_text = (alt_token or '').strip()
    return alt_text.startswith('<') and alt_text.endswith('>')


def is_structural_or_large_indel(ref, alt, min_size):
    if is_symbolic_alt(alt):
        return True
    if not ref or not alt or ref == '.' or alt == '.':
        return False
    return abs(len(ref) - len(alt)) >= min_size


sample_meta = json.loads('${sampleMetaJson}')
thresholds = sample_meta.get('stage3_discovery_thresholds', {}) if isinstance(sample_meta, dict) else {}
sample_type = str(sample_meta.get('sample_type') or 'germline').lower()
if sample_type in {'somatic', 'tumor', 'liquid_biopsy'}:
    qual_floor = float(thresholds.get('somatic_qual_floor', 20))
else:
    qual_floor = float(thresholds.get('germline_qual_floor', 10))
min_large_indel_bp = int(float(thresholds.get('large_indel_min_size_bp', 50)))

raw_vcf = Path('structural_variants.raw.vcf')
onco_vcf = Path('structural_variants.onco_filtered.vcf')
out_vcf = Path('structural_variants.calibrated.vcf')

raw_lines = raw_vcf.read_text(encoding='utf-8', errors='replace').splitlines()
onco_lines = onco_vcf.read_text(encoding='utf-8', errors='replace').splitlines()

header = []
records = []
for line in onco_lines:
    if line.startswith('#'):
        header.append(line)
    elif line.strip():
        records.append(line)

# Enforce Stage 3 schema's required VCF version for downstream harmonization.
fileformat_idx = next((i for i, h in enumerate(header) if h.startswith('##fileformat=')), None)
if fileformat_idx is None:
    header.insert(0, '##fileformat=VCFv4.2')
else:
    header[fileformat_idx] = '##fileformat=VCFv4.2'

if not any(h.startswith('##INFO=<ID=BRANCH') for h in header):
    header.insert(len([h for h in header if h.startswith('##')]), '##INFO=<ID=BRANCH,Number=1,Type=String,Description="Stage 3 variant branch origin">')

structural_candidates = 0
low_qual_filtered = 0
emitted = 0

with out_vcf.open('w', encoding='utf-8') as out:
    out.write(chr(10).join(header) + chr(10))
    for rec in records:
        cols = rec.split(chr(9))
        if len(cols) < 8:
            continue

        ref = cols[3]
        alts = [token.strip() for token in cols[4].split(',') if token.strip()]
        if not any(is_structural_or_large_indel(ref, alt, min_large_indel_bp) for alt in alts):
            continue

        structural_candidates += 1
        qual = parse_qual(cols[5])
        if qual is None or qual < qual_floor:
            low_qual_filtered += 1
            continue

        info = cols[7] if cols[7] and cols[7] != '.' else ''
        branch_tag = 'BRANCH=structural_variants'
        cols[7] = branch_tag if not info else f"{info};{branch_tag}"

        out.write(chr(9).join(cols) + chr(10))
        emitted += 1

sample_id = '${sample_id}'
audit = {
    'sample_id': sample_id,
    'stage2_manifest': str(Path('${stage2_manifest}').resolve()),
    'sorted_bam': str(Path('${sorted_bam}').resolve()),
    'sorted_bai': str(Path('${sorted_bai}').resolve()),
    'fasta': str(Path('${fasta}').resolve()),
    'target_bed': '${target_bed ?: ''}' or None,
    'is_wgs': str('${is_wgs}').strip().lower() in {'1', 'true', 'yes', 'y', 'on', 'wgs'},
    'active_supported_branches': {
        'snv_indel': bool((sample_meta.get('variant_branches') or {}).get('snv_indel')),
        'structural_variants': bool((sample_meta.get('variant_branches') or {}).get('structural_variants')),
    },
    'sample_type': sample_type,
    'qual_floor_applied': qual_floor,
    'large_indel_min_size_bp': min_large_indel_bp,
    'manta_raw_vcf': str(raw_vcf.resolve()),
    'onco_filtered_vcf': str(onco_vcf.resolve()),
    'sv_vcf': str(out_vcf.resolve()),
    'records_raw_total': sum(1 for l in raw_lines if l and not l.startswith('#')),
    'records_onco_total': len(records),
    'records_structural_candidates': structural_candidates,
    'records_filtered_low_qual': low_qual_filtered,
    'records_emitted': emitted,
    'status': 'PASS',
}

Path('stage3.structural_variants.audit.json').write_text(json.dumps(audit, indent=2) + chr(10), encoding='utf-8')
PYEOF

    # Cleanup ephemeral files generated by Manta's internal pyflow engine
    rm -rf manta_run/ workspace/ pyflow.data/ *.pickle 2>/dev/null || true
    """

    stub:
    """
    cat > structural_variants.calibrated.vcf <<'VCF'
##fileformat=VCFv4.2
##source=STAGE3_STRUCTURAL_VARIANTS_STUB
##INFO=<ID=BRANCH,Number=1,Type=String,Description="Stage 3 variant branch origin">
#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
1\t10000\t.\tN\t<DEL>\t60\tPASS\tSVTYPE=DEL;END=10100;BRANCH=structural_variants
VCF
    cat > stage3.structural_variants.audit.json <<'JSON'
{
  "sample_id": "${sample_id}",
  "status": "PASS",
  "stub": true
}
JSON
    """
}
