process ASSEMBLE_STAGE4_BANKED_MANIFEST {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    publishDir "${params.outdir}", mode: 'copy', overwrite: true, pattern: 'samples_hg002_banked_stage4.yaml'

    input:
    path manifest_fragments

    output:
    path 'samples_hg002_banked_stage4.yaml', emit: banked_manifest

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
Path('samples_hg002_banked_stage4.yaml').write_text(json.dumps(payload, indent=2) + chr(10), encoding='utf-8')
PYEOF
    """
}
