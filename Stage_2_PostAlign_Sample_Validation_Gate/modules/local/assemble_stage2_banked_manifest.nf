process ASSEMBLE_STAGE2_MANIFEST {

    label 'process_low'
    container 'genvar-core:2.1.0'

    publishDir "${params.stage2_outdir}", mode: 'copy', overwrite: true

    input:
    path fragments

    output:
    path 'samples_*_stage2.yaml', emit: stage2_manifest

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

content = json.dumps(payload, indent=2) + '\\n'
sample_ids = sorted({str(rec.get('sample_id', 'UNKNOWN')) for rec in records})
canonical_id = sample_ids[0] if len(sample_ids) == 1 else 'multi_sample'
safe_id = ''.join(ch if (ch.isalnum() or ch in ('_', '-')) else '_' for ch in canonical_id) or 'UNKNOWN'
Path(f'samples_{safe_id}_stage2.yaml').write_text(content, encoding='utf-8')
PYEOF
    """
}
