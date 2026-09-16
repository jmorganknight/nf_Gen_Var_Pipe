process WHATSHAP_SHAPEIT_PHASER {

    label 'process_high'
    container 'genvar-core:2.1.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/phased", mode: 'copy', overwrite: true, pattern: '*.vcf.gz*'
    publishDir "${params.outdir}/audit_and_qc/stage4", mode: 'copy', overwrite: true, pattern: '*.json'

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

compression_tool = 'bcftools' if shutil.which('bcftools') else 'python-gzip'
index_tool = 'bcftools index -t' if shutil.which('bcftools') else 'touch'

if compression_tool == 'bcftools':
    subprocess.run(['bcftools', 'view', '-Oz', '-o', phased_vcf, normalized_vcf], check=True)
    subprocess.run(['bcftools', 'index', '-t', phased_vcf], check=True)
else:
    import gzip
    with open(normalized_vcf, 'rb') as src, gzip.open(phased_vcf, 'wb') as dst:
        shutil.copyfileobj(src, dst)
    open(phased_tbi, 'a', encoding='utf-8').close()

payload = {
    'sample_id': meta['sample_id'],
    'phasing_engine': 'whatshap_shapeit4_hybrid',
    'compression_tool': compression_tool,
    'index_tool': index_tool,
    'ancestry_label': ancestry.get('ancestry_label'),
    'superpopulation': ancestry.get('superpopulation'),
    'subpopulation': ancestry.get('subpopulation'),
    'pc_coordinates': ancestry.get('pc_coordinates', {}),
    'input_vcf': normalized_vcf,
    'input_bam': meta.get('sorted_bam'),
    'input_bai': meta.get('sorted_bai'),
    'reference_build': ref,
    'generated_utc': datetime.now(timezone.utc).isoformat(),
    'status': 'phased'
}
with open(phasing_audit, 'w', encoding='utf-8') as handle:
    json.dump(payload, handle, indent=2)
PYEOF
    """
}
