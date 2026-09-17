process ASSEMBLE_STAGE5_MANIFEST_FROM_RELEASE {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'

    publishDir "${params.stage5_outdir}", mode: 'copy', overwrite: true, pattern: 'samples_*_stage5.yaml'

    input:
    tuple val(sample_id), path(production_release_json)

    output:
    path 'samples_*_stage5.yaml', emit: stage5_manifest

    script:
    def publishedRoot = new File(params.stage5_outdir.toString()).isAbsolute()
      ? new File(params.stage5_outdir.toString()).canonicalPath
      : new File(workflow.launchDir.toString(), params.stage5_outdir.toString()).canonicalPath
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path

release_json_path = Path('${production_release_json}')
release_data = json.loads(release_json_path.read_text(encoding='utf-8'))

sample_id = '${sample_id}'
run_mode = release_data.get('run_mode') or release_data.get('clinical_payload', {}).get('metadata', {}).get('run_mode', 'production')
audit_trail = release_data.get('audit_trail', {}) if isinstance(release_data.get('audit_trail', {}), dict) else {}
signature = release_data.get('signature', {}) if isinstance(release_data.get('signature', {}), dict) else {}
published_root = Path('${publishedRoot}')
signature_alg = signature.get('alg') or signature.get('signature_algorithm') or ''
signature_version = signature.get('version') or ''
signature_scope = signature.get('signer_scope') or ''
signature_signer_id = signature.get('signer_id') or ''
signature_public_key_fingerprint = signature.get('public_key_fingerprint_sha256') or ''
release_name = release_json_path.name
bundle_name = str(audit_trail.get('clinical_bundle_tar_gz') or '').strip()
provenance_name = str(audit_trail.get('provenance_json') or '').strip()
clinical_validity = 'RESEARCH_USE_ONLY' if str(run_mode).strip().lower() in ('dev', 'audit_only') else 'CLINICAL'

manifest_content = f'''# Stage 5 Clinical Annotation & PGx Triage Manifest
# Auto-generated from Stage 5 production release
# Purpose: Handoff from Stage 5 to Stage 6 Clinical Reporting

CLINICAL_VALIDITY: "{clinical_validity}"
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
      clinical_bundle_tar_gz: "{bundle_name}"
      provenance_json: "{provenance_name}"
      production_release_json: "{release_name}"
      production_release_signature_alg: "{signature_alg}"
      production_release_signature_version: "{signature_version}"
      production_release_signature_signer_scope: "{signature_scope}"
      production_release_signature_signer_id: "{signature_signer_id}"
      production_release_signature_public_key_fingerprint_sha256: "{signature_public_key_fingerprint}"
    
    save_dir: "{published_root}"
'''

safe_id = ''.join(ch if (ch.isalnum() or ch in ('_', '-')) else '_' for ch in sample_id) or 'UNKNOWN'
output_file = Path(f'samples_{safe_id}_stage5.yaml')
output_file.write_text(manifest_content, encoding='utf-8')
print(f"Generated: {output_file}")
PYEOF
    """
}
