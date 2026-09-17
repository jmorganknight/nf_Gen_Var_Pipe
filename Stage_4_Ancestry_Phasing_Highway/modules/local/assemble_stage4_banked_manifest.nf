process ASSEMBLE_STAGE4_BANKED_MANIFEST {

    label 'process_low'
    container 'genvar-core:2.1.0'
    stageInMode 'copy'

    publishDir "${params.outdir}", mode: 'copy', overwrite: true, pattern: 'samples_*_banked_stage4.yaml'

    input:
    path manifest_fragments

    output:
    path 'samples_*_banked_stage4.yaml', emit: banked_manifest

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path

fragment_json = '''${groovy.json.JsonOutput.toJson(manifest_fragments.collect { fragment -> fragment.toString() }).replace('\n', ' ').replace('\r', '')}'''
fragment_paths = [Path(p) for p in json.loads(fragment_json)]
samples = [json.loads(path.read_text(encoding='utf-8')) for path in fragment_paths]
payload = {'samples': sorted(samples, key=lambda rec: str(rec.get('sample_id', '')))}
content = json.dumps(payload, indent=2) + chr(10)
sample_ids = sorted({str(rec.get('sample_id', 'UNKNOWN')) for rec in payload.get('samples', [])})
canonical_id = sample_ids[0] if len(sample_ids) == 1 else 'multi_sample'
safe_id = ''.join(ch if (ch.isalnum() or ch in ('_', '-')) else '_' for ch in canonical_id) or 'UNKNOWN'
Path(f'samples_{safe_id}_banked_stage4.yaml').write_text(content, encoding='utf-8')
PYEOF
    """
}
