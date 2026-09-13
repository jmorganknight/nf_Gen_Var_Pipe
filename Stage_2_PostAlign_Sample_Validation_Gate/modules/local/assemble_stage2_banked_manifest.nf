process ASSEMBLE_STAGE2_BANKED_MANIFEST {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    publishDir "${params.outdir}", mode: 'copy', overwrite: true

    input:
    path fragments

    output:
    path 'samples_hg002_banked_stage2.yaml', emit: banked_manifest

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path

records = []
for frag in sorted(Path('.').glob('*.json')):
    records.append(json.loads(frag.read_text(encoding='utf-8')))

records.sort(key=lambda x: x.get('sample_id', ''))
payload = {'samples': records}

Path('samples_hg002_banked_stage2.yaml').write_text(
    json.dumps(payload, indent=2) + '\\n',
    encoding='utf-8'
)
PYEOF
    """
}
