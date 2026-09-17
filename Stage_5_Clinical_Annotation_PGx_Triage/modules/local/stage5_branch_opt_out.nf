process STAGE5_BRANCH_OPT_OUT {

    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'

    tag "${sample_id}:${branch_name}"

    input:
    tuple val(sample_id), val(branch_name), val(reason)

    output:
    tuple val(sample_id), path("${sample_id}.${branch_name}_summary.json"), emit: summary

    script:
    def sid = sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from datetime import datetime, timezone
from pathlib import Path

sid = '${sid}'
branch = '${branch_name}'
reason = '${reason}'
payload = {
    'sample_id': sid,
    'branch': branch,
    f'{branch}_consent': 'OPT_OUT',
    'status': 'OPT_OUT',
    'reason': reason,
    'computed_utc': datetime.now(timezone.utc).isoformat(),
}
Path(f'{sid}.{branch}_summary.json').write_text(json.dumps(payload, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """
}
