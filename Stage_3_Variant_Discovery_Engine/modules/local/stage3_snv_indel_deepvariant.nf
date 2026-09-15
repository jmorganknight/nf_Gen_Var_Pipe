process STAGE3_SNV_INDEL_DEEPVARIANT {
    label 'variant_heavy'
    container 'google/deepvariant:1.6.0'
    cpus { (params.stage3_snv_indel_cpus ?: params.stage3_cpus ?: params.stage3_variant_heavy_default_cpus ?: 8) as int }

    input:
    tuple val(sample_id), path(stage2_manifest), path(sorted_bam), path(sorted_bai), val(is_wgs), val(target_bed), path(fasta), path(fasta_fai), val(sample_qc_meta), val(stage3_refs), val(sample_meta)

    output:
    tuple val(sample_id), path('snv_indel.calibrated.vcf'), path('stage3.deepvariant_calibration.json'), val(stage3_refs), val(sample_meta), emit: calibrated_vcf
    path 'stage3.deepvariant_calibration.json', emit: audit

    script:
    def threads = (task.cpus ?: 1) as int
    def sampleQcJson = groovy.json.JsonOutput.toJson(sample_qc_meta).replace('\\', '\\\\').replace("'", "\\'")
    def sampleMetaJson = groovy.json.JsonOutput.toJson(sample_meta).replace('\\', '\\\\').replace("'", "\\'")
    def corruptHeaderFault = ((sample_meta?.stage3_faults instanceof Map) && (sample_meta.stage3_faults.corrupt_vcf_header as boolean)) ? 'true' : 'false'
    """
    set -euo pipefail

    THREADS=${threads}
    IS_WGS="${is_wgs}"
    TARGET_BED="${target_bed ?: ''}"
    CORRUPT_VCF_HEADER="${corruptHeaderFault}"
    FASTA_FAI="${fasta_fai}"

    if ! command -v run_deepvariant >/dev/null 2>&1; then
        echo "STAGE3_PRECONDITION_FAILURE: run_deepvariant not available in deepvariant container" >&2
        exit 1
    fi

    if [[ ! -f "\${FASTA_FAI}" ]]; then
        echo "STAGE3_PRECONDITION_FAILURE: staged FASTA index input missing for DeepVariant branch: \${FASTA_FAI}" >&2
        exit 1
    fi
    if [[ ! -f "${fasta}.fai" ]]; then
        cp -f "\${FASTA_FAI}" "${fasta}.fai"
    fi

    python3 - <<'PYEOF'
import json
from pathlib import Path


def as_float(value, default):
    try:
        if value is None:
            return default
        return float(value)
    except Exception:
        return default


sample_qc_meta = json.loads('${sampleQcJson}')
sample_meta = json.loads('${sampleMetaJson}')

estimated_purity = as_float(sample_qc_meta.get('estimated_in_silico_purity'), 1.0)
estimated_purity = max(0.05, min(1.0, estimated_purity))

contamination_rate = as_float(sample_qc_meta.get('contamination_rate'), 0.0)
contamination_rate = max(0.0, min(0.5, contamination_rate))

computed_sex = str(sample_qc_meta.get('computed_sex') or 'UNKNOWN').upper()
sample_type = str(sample_meta.get('sample_type') or 'germline').lower()
is_somatic = sample_type in {'somatic', 'tumor', 'liquid_biopsy'}

if is_somatic:
    min_vaf = max(0.01, min(0.08, 0.01 + (1.0 - estimated_purity) * 0.05))
else:
    min_vaf = 0.05

ab_floor = max(0.10, min(0.45, 0.20 + (contamination_rate * 2.0)))

payload = {
    'sample_id': '${sample_id}',
    'estimated_in_silico_purity': round(estimated_purity, 6),
    'contamination_rate': round(contamination_rate, 6),
    'computed_sex': computed_sex,
    'sample_type': sample_type,
    'somatic_mode': is_somatic,
    'dynamic_min_vaf': round(min_vaf, 6),
    'dynamic_ab_floor': round(ab_floor, 6),
}

Path('stage3.dynamic.thresholds.json').write_text(json.dumps(payload, indent=2) + chr(10), encoding='utf-8')
PYEOF

    model_type="WGS"
    region_args=()
    shopt -s nocasematch
    if [[ "\${IS_WGS}" == "true" || "\${IS_WGS}" == "1" || "\${IS_WGS}" == "wgs" ]]; then
        model_type="WGS"
    else
        model_type="WES"
        if [[ -z "\${TARGET_BED}" || "\${TARGET_BED}" == "null" ]]; then
            echo "STAGE3_PRECONDITION_FAILURE: missing target capture BED for non-WGS sample '${sample_id}'" >&2
            exit 1
        fi
        if [[ ! -f "\${TARGET_BED}" ]]; then
            echo "STAGE3_PRECONDITION_FAILURE: target capture BED not found for sample '${sample_id}': \${TARGET_BED}" >&2
            exit 1
        fi
        cp -f "\${TARGET_BED}" target_regions.bed
        region_args=(--regions target_regions.bed)
    fi
    shopt -u nocasematch

    run_deepvariant \
      --model_type="\${model_type}" \
      --ref="${fasta}" \
      --reads="${sorted_bam}" \
      --output_vcf=snv_indel.deepvariant.vcf.gz \
      --num_shards="\${THREADS}" \
      "\${region_args[@]}"

    python3 - <<'PYEOF'
import gzip
from pathlib import Path

src = Path('snv_indel.deepvariant.vcf.gz')
dst = Path('snv_indel.raw.vcf')
with gzip.open(src, 'rt', encoding='utf-8', errors='replace') as inp, dst.open('w', encoding='utf-8') as out:
    out.write(inp.read())
PYEOF

    python3 - <<'PYEOF'
import json
from pathlib import Path


def parse_sample(format_keys, sample_values):
    return {k: sample_values[i] if i < len(sample_values) else '' for i, k in enumerate(format_keys)}


cfg = json.loads(Path('stage3.dynamic.thresholds.json').read_text(encoding='utf-8'))
ab_floor = float(cfg['dynamic_ab_floor'])
min_vaf = float(cfg['dynamic_min_vaf'])
somatic_mode = bool(cfg['somatic_mode'])

in_path = Path('snv_indel.raw.vcf')
out_path = Path('snv_indel.calibrated.vcf')

header = []
body = []
for line in in_path.read_text(encoding='utf-8', errors='replace').splitlines():
    if line.startswith('#'):
        header.append(line)
    elif line.strip():
        body.append(line)

existing_filter_lines = {h for h in header if h.startswith('##FILTER=')}
if '##FILTER=<ID=LOW_AB,Description="Failed dynamic contamination-aware allele-balance floor">' not in existing_filter_lines:
    header.insert(len([h for h in header if h.startswith('##')]), '##FILTER=<ID=LOW_AB,Description="Failed dynamic contamination-aware allele-balance floor">')
if '##FILTER=<ID=LOW_VAF,Description="Failed dynamic purity-aware somatic VAF floor">' not in existing_filter_lines:
    header.insert(len([h for h in header if h.startswith('##')]), '##FILTER=<ID=LOW_VAF,Description="Failed dynamic purity-aware somatic VAF floor">')
if not any(h.startswith('##INFO=<ID=BRANCH') for h in header):
    header.insert(len([h for h in header if h.startswith('##')]), '##INFO=<ID=BRANCH,Number=1,Type=String,Description="Stage 3 variant branch origin">')

records_kept = 0
records_tagged = 0
low_ab = 0
low_vaf = 0

with out_path.open('w', encoding='utf-8') as out:
    out.write(chr(10).join(header) + chr(10))
    for raw in body:
        cols = raw.split(chr(9))
        if len(cols) < 10:
            continue

        fmt_keys = cols[8].split(':')
        sample_vals = cols[9].split(':')
        sample_map = parse_sample(fmt_keys, sample_vals)

        ad_vals = []
        if sample_map.get('AD'):
            try:
                ad_vals = [int(x) for x in sample_map['AD'].split(',') if x != '.']
            except Exception:
                ad_vals = []

        if len(ad_vals) >= 2:
            ref_depth = max(0, int(ad_vals[0]))
            alt_depth = max(0, max(int(v) for v in ad_vals[1:]))
            dp = ref_depth + alt_depth
            sample_map['AD'] = f"{ref_depth},{alt_depth}"
            sample_map['DP'] = str(dp)
        else:
            try:
                dp = int(sample_map.get('DP') or 0)
            except Exception:
                dp = 0
            ref_depth = max(0, dp // 2)
            alt_depth = max(0, dp - ref_depth)
            sample_map['AD'] = f"{ref_depth},{alt_depth}"
            sample_map['DP'] = str(dp)

        ab = (float(alt_depth) / float(dp)) if dp > 0 else 0.0
        filter_tokens = [] if cols[6] in {'PASS', '.'} else [t for t in cols[6].split(';') if t]

        if ab < ab_floor:
            filter_tokens.append('LOW_AB')
            low_ab += 1
        if somatic_mode and ab < min_vaf:
            filter_tokens.append('LOW_VAF')
            low_vaf += 1

        if filter_tokens:
            records_tagged += 1
            cols[6] = ';'.join(sorted(set(filter_tokens)))
        else:
            cols[6] = 'PASS'

        info = cols[7] if cols[7] and cols[7] != '.' else ''
        branch_tag = 'BRANCH=snv_indel'
        cols[7] = branch_tag if not info else f"{info};{branch_tag}"

        cols[9] = ':'.join(sample_map.get(k, '') for k in fmt_keys)
        out.write(chr(9).join(cols) + chr(10))
        records_kept += 1

if '${corruptHeaderFault}' == 'true':
    vcf_text = Path('snv_indel.calibrated.vcf').read_text(encoding='utf-8', errors='replace')
    vcf_text = vcf_text.replace('##fileformat=VCFv4.2', '##fileformat=BADVCF', 1)
    Path('snv_indel.calibrated.vcf').write_text(vcf_text, encoding='utf-8')

sample_id = '${sample_id}'
audit = {
    'sample_id': sample_id,
    'stage2_manifest': str(Path('${stage2_manifest}').resolve()),
    'sorted_bam': str(Path('${sorted_bam}').resolve()),
    'sorted_bai': str(Path('${sorted_bai}').resolve()),
    'fasta': str(Path('${fasta}').resolve()),
    'target_bed': '${target_bed ?: ''}' or None,
    'is_wgs': str('${is_wgs}').strip().lower() in {'1', 'true', 'yes', 'y', 'on', 'wgs'},
    'model_type': 'WGS' if str('${is_wgs}').strip().lower() in {'1', 'true', 'yes', 'y', 'on', 'wgs'} else 'WES',
    'threads': int('${threads}'),
    'dynamic_calibration': cfg,
    'command': 'run_deepvariant -> dynamic recalibration (snv_indel)',
    'snv_indel_vcf': str(Path('snv_indel.calibrated.vcf').resolve()),
    'records_emitted': records_kept,
    'records_filtered_low_ab': low_ab,
    'records_filtered_low_vaf': low_vaf,
    'records_with_non_pass_filter': records_tagged,
    'status': 'PASS',
}
Path('stage3.deepvariant_calibration.json').write_text(json.dumps(audit, indent=2) + chr(10), encoding='utf-8')
PYEOF

    if [[ "\${CORRUPT_VCF_HEADER}" == "true" ]]; then
        echo "STAGE3_SCHEMA_VALIDATION_FAILURE: fault injection emitted malformed VCF header (intentional fail-closed path)" >&2
        exit 130
    fi
    """
}
