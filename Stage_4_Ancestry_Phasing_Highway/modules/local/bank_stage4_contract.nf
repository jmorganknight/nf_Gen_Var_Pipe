process BANK_STAGE4_CONTRACT {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage4", mode: 'rellink', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(ancestry_metrics_json), path(phased_vcf), path(phased_tbi), path(phasing_audit)

    output:
    path "${meta.sample_id}.banked_stage4.fragment.json", emit: manifest_fragment

    script:
    def sid = meta.sample_id
    def metaJson = groovy.json.JsonOutput.toJson(meta).replace('\n', ' ').replace('\r', '')
    def ancestryJson = groovy.json.JsonOutput.toJson(ancestry_metrics_json.toString()).replace('\n', ' ').replace('\r', '')
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path

meta = json.loads('''${metaJson}''')
ancestry_path = json.loads('''${ancestryJson}''')
sid = '${sid}'
ancestry = json.loads(Path(ancestry_path).read_text(encoding='utf-8'))

fragment = {
    'sample_id': sid,
    'validation_token': meta.get('validation_token', ''),
    'consent_tokens': meta.get('consent_tokens', {}),
    'stage0_consent_tokens': meta.get('stage0_consent_tokens', {}),
    'variant_branches': meta.get('variant_branches', {}),
    'active_branches': meta.get('active_branches', []),
    'sorted_bam': meta.get('sorted_bam', ''),
    'sorted_bai': meta.get('sorted_bai', ''),
    'normalized_vcf': meta.get('normalized_vcf', ''),
    'normalized_vcf_tbi': meta.get('normalized_vcf_tbi', ''),
    'phased_vcf': '${phased_vcf}',
    'phased_vcf_tbi': '${phased_tbi}',
    'ancestry_metrics_json': ancestry_path,
    'phasing_audit_json': '${phasing_audit}',
    'ancestry_label': ancestry.get('ancestry_label'),
    'superpopulation': ancestry.get('superpopulation'),
    'subpopulation': ancestry.get('subpopulation'),
    'pc_coordinates': ancestry.get('pc_coordinates', {}),
    'reference_build': meta.get('reference_build', {}),
    'stage4_handoff_note': 'Ancestry-projected, phased VCF ready for Stage 5 annotation and PGx triage.',
    'save_dir': meta.get('save_dir', ''),
}
with open(f'{sid}.banked_stage4.fragment.json', 'w', encoding='utf-8') as handle:
    json.dump(fragment, handle, indent=2)
PYEOF
    """
}
