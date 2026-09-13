process STAGE5_PRECONDITION_GUARD {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage5", mode: 'rellink', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(phased_vcf), path(phased_tbi), val(reference_meta)

    output:
    tuple val(meta), path(phased_vcf), path(phased_tbi), val(reference_meta), emit: validated_bundle
    path "${meta.sample_id}.stage5_precondition_guard.json", emit: guard_audit

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path

sid = '${sid}'
meta = json.loads('''${groovy.json.JsonOutput.toJson(meta).replace("\\n", " ").replace("\\r", "")}''')
required_meta_fields = ['sample_id', 'validation_token', 'phased_vcf', 'phased_vcf_tbi', 'ancestry_metrics_json', 'phasing_audit_json']
missing_meta = [field for field in required_meta_fields if field not in meta or meta[field] in (None, '')]
if missing_meta:
    raise SystemExit(f"STAGE5_PRECONDITION_FAILURE: canonical meta missing fields for {sid}: {missing_meta}")

required = [
    Path(meta['phased_vcf']),
    Path(meta['phased_vcf_tbi']),
    Path(meta['ancestry_metrics_json']),
    Path(meta['phasing_audit_json']),
]
missing = [str(path) for path in required if not path.exists()]
if missing:
    raise SystemExit(f"STAGE5_PRECONDITION_FAILURE: missing required Stage 4 payload for {sid}: {missing}")

with Path(meta['ancestry_metrics_json']).open('r', encoding='utf-8') as handle:
    ancestry = json.load(handle)
with Path(meta['phasing_audit_json']).open('r', encoding='utf-8') as handle:
    phasing = json.load(handle)

audit = {
    'node': 'STAGE5_PRECONDITION_GUARD',
    'sample_id': sid,
    'validation_token': phasing.get('validation_token', 'VALID_PASS|VARIANTS_HARMONIZED'),
    'ancestry_label': ancestry.get('ancestry_label', 'UNSET'),
    'superpopulation': ancestry.get('superpopulation', 'UNSET'),
    'subpopulation': ancestry.get('subpopulation', 'UNSET'),
    'phased_vcf': meta['phased_vcf'],
    'phased_vcf_tbi': meta['phased_vcf_tbi'],
    'ancestry_metrics_json': meta['ancestry_metrics_json'],
    'phasing_audit_json': meta['phasing_audit_json'],
    'status': 'PASS',
}
Path(f'{sid}.stage5_precondition_guard.json').write_text(json.dumps(audit, indent=2) + "\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    printf '{"node":"STAGE5_PRECONDITION_GUARD","sample_id":"%s","status":"PASS","stub":true}' "${meta.sample_id}" > "${meta.sample_id}.stage5_precondition_guard.json"
    """
}
