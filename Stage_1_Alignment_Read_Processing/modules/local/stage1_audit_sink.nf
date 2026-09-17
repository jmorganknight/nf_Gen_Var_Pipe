process STAGE1_AUDIT_SINK {

    label 'process_low'
    container 'genvar-core:2.1.0'


    input:
    path route_audits
    path fastp_jsons
    path align_metrics
    path flagstats
    path identity_audits
    path junction_audits

    output:
    path 'stage1_audit_payload.json', emit: payload

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from datetime import datetime, timezone
from pathlib import Path


def load_jsons(paths):
    items = []
    for p in sorted(paths):
        try:
            items.append(json.loads(Path(p).read_text(encoding='utf-8')))
        except Exception:
            items.append({"file": p, "parse_error": True})
    return items

payload = {
    "node": "STAGE1_AUDIT_SINK",
    "timestamp_utc": datetime.now(timezone.utc).isoformat(),
    "route_audits": load_jsons([p.name for p in Path('.').glob('*.platform_init_route.json')]),
    "fastp_reports": load_jsons([p.name for p in Path('.').glob('*.fastp.json')]),
    "aligner_metrics": load_jsons([p.name for p in Path('.').glob('*.elprep_metrics.json')] + [p.name for p in Path('.').glob('*.bwa_metrics.json')]),
    "identity_audits": load_jsons([p.name for p in Path('.').glob('*.identity_audit.json')]),
    "junction_audits": load_jsons([p.name for p in Path('.').glob('*.junction_audit.json')]),
    "flagstat_files": [p.name for p in sorted(Path('.').glob('*.flagstat.txt'))]
}

Path('stage1_audit_payload.json').write_text(json.dumps(payload, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """
}
