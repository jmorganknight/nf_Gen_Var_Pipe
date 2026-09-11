process LOAD_STAGE2_CONTRACT {
    label 'process_low'
    container 'wes-onco-core:1.0.0'

    input:
    path stage2_manifest

    output:
    tuple path('stage2.contract.json'), path('stage2.branch_plan.json'), emit: loaded

    script:
    """
    set -euo pipefail
    python3 - <<'PYEOF'
import json
from pathlib import Path

try:
    import yaml
except ImportError as exc:
    raise RuntimeError('PyYAML is required to load the Stage 2 banked manifest') from exc

manifest = yaml.safe_load(Path('${stage2_manifest}').read_text(encoding='utf-8')) or {}
records = manifest.get('samples') or []
if not records:
    raise SystemExit('STAGE3_PRECONDITION_FAILURE: Stage 2 banked manifest contains no samples')

record = records[0]
sid = str(record.get('sample_id') or 'UNKNOWN')
raw_token = str(record.get('validation_token') or record.get('intake_validation_token_value') or record.get('intake_validation_token') or '').strip()
if 'VALID_PASS|SAMPLE_VALIDATED' not in raw_token:
    raise SystemExit(f"STAGE3_PRECONDITION_FAILURE: invalid validation_token for sample '{sid}'")

sorted_bam = Path(str(record.get('sorted_bam') or '')).expanduser()
sorted_bai = Path(str(record.get('sorted_bai') or '')).expanduser() if record.get('sorted_bai') else Path(str(sorted_bam) + '.bai')
if not sorted_bam.exists():
    raise SystemExit(f"STAGE3_PRECONDITION_FAILURE: sorted_bam missing for sample '{sid}': {sorted_bam}")
if not sorted_bai.exists():
    raise SystemExit(f"STAGE3_PRECONDITION_FAILURE: sorted_bai missing for sample '{sid}': {sorted_bai}")

variant_branches = record.get('variant_branches') or {}
if not isinstance(variant_branches, dict):
    raise SystemExit(f"STAGE3_PRECONDITION_FAILURE: variant_branches schema invalid for sample '{sid}'")

stage3_faults = record.get('stage3_faults') or {}
if not isinstance(stage3_faults, dict):
    stage3_faults = {}

contract_payload = {
    'sample_id': sid,
    'validation_token': raw_token,
    'sorted_bam': str(sorted_bam.resolve()),
    'sorted_bai': str(sorted_bai.resolve()),
    'variant_branches': variant_branches,
    'stage3_faults': stage3_faults,
    'reference_build': record.get('reference_build', {}),
    'snv_mask_bed': record.get('snv_mask_bed'),
    'cnv_target_bed': record.get('cnv_target_bed'),
    'save_dir': record.get('save_dir', ''),
}

Path('stage2.contract.json').write_text(json.dumps(contract_payload, indent=2) + '\n', encoding='utf-8')
Path('stage2.branch_plan.json').write_text(json.dumps(variant_branches, indent=2) + '\n', encoding='utf-8')
PYEOF
    """
}
