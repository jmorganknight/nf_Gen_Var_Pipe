process ASSEMBLE_STAGE3_BANKED_MANIFEST {
    label 'process_low'
    container 'genvar-core:2.1.0'

    publishDir "${params.outdir}", mode: 'copy', overwrite: true

    input:
    path fragments

    output:
    path 'samples_hg002_banked_stage3.yaml', emit: banked_manifest

    script:
    """
    set -euo pipefail
    python3 - <<'PYEOF'
import json
from pathlib import Path

records = [json.loads(p.read_text(encoding='utf-8')) for p in sorted(Path('.').glob('*.json'))]
lines = [
    '# ==============================================================================',
    '# STAGE 3 BANKED MANIFEST',
    '# Purpose: Variant-discovery handoff after dynamic branch execution and VCF',
    '#          harmonization for Stage 4 annotation / PGx triage.',
    '# ==============================================================================',
    'samples:'
]
for rec in records:
    lines.append('  - sample_id: ' + json.dumps(rec['sample_id']))
    lines.append('    validation_token: ' + json.dumps(rec.get('validation_token', '')))
    lines.append('    run_mode: ' + json.dumps(rec.get('run_mode', 'production')))
    lines.append('    stage2_contamination_status: ' + json.dumps(rec.get('stage2_contamination_status', '')))
    lines.append('    stage2_contamination_policy_action: ' + json.dumps(rec.get('stage2_contamination_policy_action', '')))
    lines.append('    sorted_bam: ' + json.dumps(rec.get('sorted_bam', '')))
    lines.append('    sorted_bai: ' + json.dumps(rec.get('sorted_bai', '')))
    variant_branches = rec.get('variant_branches') or {}
    if variant_branches:
        lines.append('    variant_branches:')
        for key, value in variant_branches.items():
            lines.append('      ' + key + ': ' + json.dumps(bool(value)).lower())
    else:
        lines.append('    variant_branches: {}')
    active_branches = rec.get('active_branches', [])
    if active_branches:
        lines.append('    active_branches:')
        for branch in active_branches:
            lines.append('      - ' + json.dumps(branch))
    else:
        lines.append('    active_branches: []')
    lines.append('    normalized_vcf: ' + json.dumps(rec.get('normalized_vcf', '')))
    lines.append('    normalized_vcf_tbi: ' + json.dumps(rec.get('normalized_vcf_tbi', '')))
    lines.append('    harmonization_audit: ' + json.dumps(rec.get('harmonization_audit', '')))
    lines.append('    stage4_handoff_note: "Normalized, atomized, left-aligned VCF ready for annotation."')
Path('samples_hg002_banked_stage3.yaml').write_text(chr(10).join(lines) + chr(10), encoding='utf-8')
PYEOF
    """
}
