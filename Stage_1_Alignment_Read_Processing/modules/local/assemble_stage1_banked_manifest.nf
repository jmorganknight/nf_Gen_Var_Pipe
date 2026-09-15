process ASSEMBLE_STAGE1_BANKED_MANIFEST {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    publishDir "${params.outdir}", mode: 'copy', overwrite: true

    input:
    path fragments

    output:
    path 'samples_hg002_banked_stage1.yaml', emit: banked_manifest

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path
records = [json.loads(frag.read_text(encoding='utf-8')) for frag in sorted(Path('.').glob('*.json'))]
records.sort(key=lambda x: str(x.get('sample_id', '')))
payload = {'samples': records}
Path('samples_hg002_banked_stage1.yaml').write_text(json.dumps(payload, indent=2) + chr(10), encoding='utf-8')
PYEOF
    """
}
