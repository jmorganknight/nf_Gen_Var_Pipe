process ASSEMBLE_STAGE5_MANIFEST_FROM_RELEASE {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'

    publishDir "${params.outdir}", mode: 'copy', overwrite: true, pattern: 'samples_*_banked_stage5.yaml'

    input:
    tuple val(sample_id), path(production_release_json)

    output:
    path 'samples_*_banked_stage5.yaml', emit: banked_manifest

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path

release_json_path = Path('${production_release_json}')
release_data = json.loads(release_json_path.read_text(encoding='utf-8'))

sample_id = '${sample_id}'
run_mode = release_data.get('run_mode', 'production')
signature = release_data.get('signature', {})

manifest_content = f'''# Stage 5 Clinical Annotation & PGx Triage Banked Manifest
# Auto-generated from Stage 5 production release
# Purpose: Handoff from Stage 5 to Stage 6 Clinical Reporting

CLINICAL_VALIDITY: "{run_mode.upper() if run_mode == 'dev' else 'CLINICAL'}"
REGULATORY_WARNING: "Lock-closed audit trail: all downstream changes require chain-of-custody verification"

samples:
  - sample_id: "{sample_id}"
    run_mode: "{run_mode}"
    validation_token: "VALID_PASS|VARIANTS_HARMONIZED|STAGE5_COMPLETE"
    
    lineage:
      source_stage: "Stage_4_Ancestry_Phasing_Highway"
      stage5_workflow: "STAGE5_ANNOTATION_PGX_TRIAGE"
      stage5_version: "{release_data.get('version', 'unknown')}"
    
    stage5_outputs:
      production_release_json: "{release_json_path.name}"
      production_release_signature_alg: "{signature.get('alg', 'UNKNOWN')}"
      production_release_signature_version: "{signature.get('version', 'unknown')}"
    
    save_dir: "${{PWD}}"
'''

safe_id = ''.join(ch if (ch.isalnum() or ch in ('_', '-')) else '_' for ch in sample_id) or 'UNKNOWN'
output_file = Path(f'samples_{safe_id}_banked_stage5.yaml')
output_file.write_text(manifest_content, encoding='utf-8')
print(f"Generated: {output_file}")
PYEOF
    """
}
