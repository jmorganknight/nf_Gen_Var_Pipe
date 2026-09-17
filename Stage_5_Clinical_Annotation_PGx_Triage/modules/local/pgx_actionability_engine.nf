process PGX_ACTIONABILITY_ENGINE {

    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'

    tag "${sample_id}"

    input:
    tuple val(sample_id), path(pgx_diplotype_json), val(reference_meta), val(pgx_cli_script)

    output:
    tuple val(sample_id), path("${sample_id}.pgx_actionability.json"), emit: actionability_json
    path "${sample_id}.pgx_actionability.fragment.json", emit: fragment

    script:
    def sid = sample_id
    def refJson = groovy.json.JsonOutput.toJson(reference_meta).replace('\n', ' ').replace('\r', '')
    """
    set -euo pipefail

        python3 "${pgx_cli_script}" actionability \
      --sample-id "${sid}" \
      --diplotype-json "${pgx_diplotype_json}" \
      --reference-meta '${refJson}' \
      --out "${sid}.pgx_actionability.json"

    python3 - <<'PYEOF'
import json
from pathlib import Path
sid = '${sid}'
action = json.loads(Path(f'{sid}.pgx_actionability.json').read_text(encoding='utf-8'))
fragment = {
    'sample_id': sid,
    'component': 'pgx_actionability',
    'pgx_diplotype_json': f'{sid}.pgx_diplotype.json',
    'pgx_actionability_json': f'{sid}.pgx_actionability.json',
    'pgx_overall_risk_tier': action.get('overall_risk_tier', 'UNKNOWN'),
    'genes': {
        gene: {
            'diplotype': details.get('diplotype'),
            'phenotype': details.get('phenotype'),
            'therapeutic_risk_tier': details.get('therapeutic_risk_tier'),
            'evidence_level': details.get('evidence_level'),
        }
        for gene, details in action.get('genes', {}).items()
    },
}
Path(f'{sid}.pgx.fragment.json').write_text(json.dumps(fragment, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """
}
