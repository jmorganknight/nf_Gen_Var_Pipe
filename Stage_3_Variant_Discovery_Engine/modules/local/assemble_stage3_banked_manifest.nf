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
payload = {'samples': sorted(records, key=lambda rec: str(rec.get('sample_id', '')))}
Path('samples_hg002_banked_stage3.yaml').write_text(json.dumps(payload, indent=2) + chr(10), encoding='utf-8')
PYEOF
    """
}
