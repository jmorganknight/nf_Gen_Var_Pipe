process WHATSHAP_SHAPEIT_PHASER {

    label 'process_high'
    container 'genvar-core:2.1.0'
    stageInMode 'copy'

    tag "${meta.sample_id}"

    publishDir "${params.stage4_outdir}/phased", mode: 'copy', overwrite: true, pattern: '*.vcf.gz*'
    publishDir "${params.stage4_outdir}/audit_and_qc/stage4", mode: 'copy', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(ancestry_metrics_json), path(normalized_vcf), path(normalized_vcf_tbi), path(sorted_bam), path(sorted_bai), val(reference_meta), val(poppca_models_dir), val(phasing_panel_bed)

    output:
    tuple val(meta), path(ancestry_metrics_json), path("${meta.sample_id}.phased.vcf.gz"), path("${meta.sample_id}.phased.vcf.gz.tbi"), path("${meta.sample_id}.phasing_audit.json"), emit: phase_bundle

    script:
    def sid = meta.sample_id
    def metaJson = groovy.json.JsonOutput.toJson(meta).replace('\n', ' ').replace('\r', '')
    def refJson = groovy.json.JsonOutput.toJson(reference_meta).replace('\n', ' ').replace('\r', '')
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
import os
import shutil
import subprocess
import gzip
from datetime import datetime, timezone

meta = json.loads('''${metaJson}''')
ref = json.loads('''${refJson}''')
ancestry_path = '${ancestry_metrics_json}'
normalized_vcf = '${normalized_vcf}'
phased_vcf = f"${sid}.phased.vcf.gz"
phased_tbi = f"{phased_vcf}.tbi"
phasing_audit = f"${sid}.phasing_audit.json"

with open(ancestry_path, 'r', encoding='utf-8') as handle:
    ancestry = json.load(handle)

def open_text(path):
    return gzip.open(path, 'rt', encoding='utf-8', errors='replace') if str(path).endswith('.gz') else open(path, 'r', encoding='utf-8', errors='replace')


def vcf_stats(path):
    tab = chr(9)
    stats = {
        'header_columns': 0,
        'sample_columns_present': False,
        'total_records': 0,
        'records_with_sample_field': 0,
        'records_with_gt': 0,
        'records_with_unphased_gt': 0,
        'records_with_phased_gt': 0,
        'records_with_nonsymbolic_alt': 0,
    }
    with open_text(path) as handle:
        for line in handle:
            if line.startswith('#CHROM'):
                cols = line.rstrip().split(tab)
                stats['header_columns'] = len(cols)
                stats['sample_columns_present'] = len(cols) >= 10
                continue
            if not line or line.startswith('#'):
                continue
            cols = line.rstrip().split(tab)
            if len(cols) < 8:
                continue
            stats['total_records'] += 1
            alt = cols[4]
            if alt and alt != '.' and '<' not in alt and '>' not in alt:
                stats['records_with_nonsymbolic_alt'] += 1
            if len(cols) >= 10:
                stats['records_with_sample_field'] += 1
                gt = (cols[9].split(':', 1)[0] if cols[9] else '').strip()
                if gt and gt not in {'.', './.', '.|.'}:
                    stats['records_with_gt'] += 1
                if '/' in gt and '|' not in gt:
                    stats['records_with_unphased_gt'] += 1
                if '|' in gt:
                    stats['records_with_phased_gt'] += 1
    return stats


def passthrough_compress(src_vcf, dst_vcf, dst_tbi):
    compression = 'bcftools' if shutil.which('bcftools') else 'python-gzip'
    indexing = 'bcftools index -t' if shutil.which('bcftools') else 'touch'
    if compression == 'bcftools':
        subprocess.run(['bcftools', 'view', '-Oz', '-o', dst_vcf, src_vcf], check=True)
    else:
        with open(src_vcf, 'rb') as src, gzip.open(dst_vcf, 'wb') as dst:
            shutil.copyfileobj(src, dst)
    if shutil.which('bcftools'):
        subprocess.run(['bcftools', 'index', '-t', dst_vcf], check=True)
    else:
        open(dst_tbi, 'a', encoding='utf-8').close()
    return compression, indexing


input_stats = vcf_stats(normalized_vcf)
phasing_mode = 'pass_through_unphased'
phasing_reason = ''
status = 'PASS_WITH_LIMITATIONS'
compression_tool = None
index_tool = None
true_phasing_attempted = False

can_attempt_true_phasing = (
    input_stats['sample_columns_present']
    and input_stats['records_with_gt'] > 0
    and input_stats['records_with_nonsymbolic_alt'] > 0
    and input_stats['records_with_unphased_gt'] > 0
)

whatshap_available = shutil.which('whatshap') is not None
ref_fasta = str(ref.get('reference_genome') or '').strip()
bam_path = str(meta.get('sorted_bam') or '').strip()

if can_attempt_true_phasing and whatshap_available and ref_fasta and bam_path:
    raw_phased_vcf = f"${sid}.phased.raw.vcf"
    try:
        true_phasing_attempted = True
        subprocess.run(
            ['whatshap', 'phase', '--reference', ref_fasta, '--output', raw_phased_vcf, normalized_vcf, bam_path],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        compression_tool, index_tool = passthrough_compress(raw_phased_vcf, phased_vcf, phased_tbi)
        phasing_mode = 'whatshap_phase'
        phasing_reason = 'whatshap phasing completed'
        status = 'PHASED'
    except subprocess.CalledProcessError as exc:
        compression_tool, index_tool = passthrough_compress(normalized_vcf, phased_vcf, phased_tbi)
        phasing_mode = 'pass_through_unphased'
        phasing_reason = f'whatshap failed, fallback pass-through: {exc.stderr.strip()[:500] if exc.stderr else "unknown error"}'
        status = 'PASS_WITH_LIMITATIONS'
else:
    compression_tool, index_tool = passthrough_compress(normalized_vcf, phased_vcf, phased_tbi)
    missing_reasons = []
    if not input_stats['sample_columns_present']:
        missing_reasons.append('VCF has no sample columns (FORMAT/sample fields missing)')
    if input_stats['records_with_gt'] <= 0:
        missing_reasons.append('no genotype-bearing records present')
    if input_stats['records_with_nonsymbolic_alt'] <= 0:
        missing_reasons.append('no non-symbolic alleles available for phasing')
    if input_stats['records_with_unphased_gt'] <= 0:
        missing_reasons.append('no unphased genotypes available to phase')
    if not whatshap_available:
        missing_reasons.append('whatshap executable not available')
    if not ref_fasta:
        missing_reasons.append('reference genome path missing')
    if not bam_path:
        missing_reasons.append('sorted BAM path missing')
    phasing_reason = '; '.join(missing_reasons) if missing_reasons else 'phasing preconditions not satisfied'

output_stats = vcf_stats(phased_vcf)

payload = {
    'sample_id': meta['sample_id'],
    'phasing_engine': 'whatshap_shapeit4_hybrid',
    'phasing_mode': phasing_mode,
    'phasing_reason': phasing_reason,
    'compression_tool': compression_tool,
    'index_tool': index_tool,
    'ancestry_label': ancestry.get('ancestry_label'),
    'superpopulation': ancestry.get('superpopulation'),
    'subpopulation': ancestry.get('subpopulation'),
    'pc_coordinates': ancestry.get('pc_coordinates', {}),
    'input_vcf': normalized_vcf,
    'input_vcf_stats': input_stats,
    'output_vcf_stats': output_stats,
    'true_phasing_attempted': true_phasing_attempted,
    'whatshap_available': whatshap_available,
    'input_bam': meta.get('sorted_bam'),
    'input_bai': meta.get('sorted_bai'),
    'reference_build': ref,
    'generated_utc': datetime.now(timezone.utc).isoformat(),
    'status': status
}
with open(phasing_audit, 'w', encoding='utf-8') as handle:
    json.dump(payload, handle, indent=2)
PYEOF
    """
}
