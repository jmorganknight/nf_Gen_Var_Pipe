process BANK_STAGE4_CONTRACT {

    label 'process_low'
    container 'genvar-core:2.1.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage4", mode: 'copy', overwrite: true, pattern: '*.json'

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
phasing = json.loads(Path('${phasing_audit}').read_text(encoding='utf-8'))

phase_status = str(phasing.get('status') or 'PASS_WITH_LIMITATIONS')
phase_mode = str(phasing.get('phasing_mode') or 'pass_through_unphased')
if phase_status == 'PHASED':
    handoff_note = 'Ancestry-projected and genotype-phased VCF ready for Stage 5 annotation and PGx triage.'
else:
    handoff_note = 'Ancestry-projected VCF ready for Stage 5 with phasing limitations documented in phasing_audit_json.'

save_dir = str(meta.get('save_dir') or '').strip()
if save_dir:
    save_root = Path(save_dir)
else:
    save_root = Path('.')
published_phased_vcf = str(save_root / 'phased' / Path('${phased_vcf}').name)
published_phased_tbi = str(save_root / 'phased' / Path('${phased_tbi}').name)
published_ancestry_audit = str(save_root / 'audit_and_qc' / 'stage4' / Path(ancestry_path).name)
published_phasing_audit = str(save_root / 'audit_and_qc' / 'stage4' / Path('${phasing_audit}').name)

fragment = dict(meta)
fragment.update({
    'sample_id': sid,
    'run_mode': meta.get('run_mode', 'production'),
    'validation_token': meta.get('validation_token', ''),
    'phased_vcf': published_phased_vcf,
    'phased_vcf_tbi': published_phased_tbi,
    'ancestry_metrics_json': published_ancestry_audit,
    'phasing_audit_json': published_phasing_audit,
    'ancestry_label': ancestry.get('ancestry_label'),
    'superpopulation': ancestry.get('superpopulation'),
    'subpopulation': ancestry.get('subpopulation'),
    'pc_coordinates': ancestry.get('pc_coordinates', {}),
    'stage4_phase_status': phase_status,
    'stage4_phase_mode': phase_mode,
    'stage4_phase_reason': phasing.get('phasing_reason'),
    'reference_build': meta.get('reference_build', {}),
    'stage4_handoff_note': handoff_note,
    'save_dir': save_dir,
})
with open(f'{sid}.banked_stage4.fragment.json', 'w', encoding='utf-8') as handle:
    json.dump(fragment, handle, indent=2)
PYEOF
    """
}
