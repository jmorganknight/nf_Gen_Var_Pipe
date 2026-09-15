process ACMG_BAYESIAN_CLASSIFIER_STAGE5 {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/annotation", mode: 'copy', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(vep_annotations_json), path(vep_rules_json), path(clinvar_json), path(freq_rules_json), path(acmg_bayesian_classifier_script)

    output:
    tuple val(meta), path("${meta.sample_id}.stage5_acmg_tiered_variants.json"), emit: classification_payload
    tuple val(meta), path("${meta.sample_id}.stage5_candidate_vus.json"), emit: candidate_vus

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 "${acmg_bayesian_classifier_script}" --sample-id "${sid}" --vep-rules "${vep_rules_json}" --clinvar "${clinvar_json}" --freq-rules "${freq_rules_json}" --out "${sid}.stage5_acmg_tiered_variants.json"
    python3 - <<'PYEOF'
import json
from pathlib import Path
sid = '${sid}'
classification = json.loads(Path(f'{sid}.stage5_acmg_tiered_variants.json').read_text(encoding='utf-8'))
Path(f'{sid}.stage5_candidate_vus.json').write_text(json.dumps({
    'node': 'ACMG_BAYESIAN_CLASSIFIER_STAGE5',
    'sample_id': sid,
    'candidate_vus': classification.get('candidate_vus', []),
}, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    printf '{"node":"acmg_bayesian_classifier.py","sample_id":"%s","tiers":{"Tier I":[],"Tier II":[],"Tier III":[],"Tier IV":[]},"candidate_vus":[],"stub":true}' "${meta.sample_id}" > "${meta.sample_id}.stage5_acmg_tiered_variants.json"
    printf '{"node":"ACMG_BAYESIAN_CLASSIFIER_STAGE5","sample_id":"%s","candidate_vus":[],"stub":true}' "${meta.sample_id}" > "${meta.sample_id}.stage5_candidate_vus.json"
    """
}

process VUS_TRIAGE_HGMD_SEARCH {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/annotation", mode: 'copy', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(candidate_vus_json)

    output:
    tuple val(meta), path("${meta.sample_id}.stage5_vus_triage_queue.json"), emit: upgraded_vus
    tuple val(meta), path("${meta.sample_id}.stage5_annotation.fragment.json"), emit: fragment

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path
sid = '${sid}'
candidate = json.loads(Path('${candidate_vus_json}').read_text(encoding='utf-8')).get('candidate_vus', [])
upgraded = []
remaining = []
for row in candidate:
    clinvar_assertion = str(row.get('clinvar_assertion', '')).lower()
    clinvar_stars = int(row.get('clinvar_stars', 0) or 0)
    posterior = float(row.get('posterior_score', 0.0) or 0.0)
    has_pathogenic_clinvar = ('pathogenic' in clinvar_assertion and 'benign' not in clinvar_assertion)
    has_strong_score = posterior >= 1.20
    if has_pathogenic_clinvar and clinvar_stars >= 2 and has_strong_score:
        upgraded.append({
            **row,
            'hgmd_dm_only': False,
            'pmids': [],
            'upgrade_rule': 'PS4',
            'upgraded_tier': 'Tier II',
            'upgrade_reason': 'clinvar_pathogenic_2plus_with_supportive_posterior',
        })
    else:
        remaining.append({
            **row,
            'hgmd_dm_only': False,
            'pmids': [],
            'upgrade_rule': None,
            'upgraded_tier': 'Tier III',
            'upgrade_reason': 'insufficient_support_for_upgrade',
        })

queue_payload = {
    'node': 'VUS_TRIAGE_HGMD_SEARCH',
    'sample_id': sid,
    'candidate_vus_count': len(candidate),
    'upgraded_variants': upgraded,
    'remaining_vus': remaining,
}
fragment = {
    'sample_id': sid,
    'component': 'annotation',
    'acmg_tiered_table': f'{sid}.stage5_acmg_tiered_variants.json',
    'vus_queue': f'{sid}.stage5_vus_triage_queue.json',
    'vus_upgraded_count': len(upgraded),
}
Path(f'{sid}.stage5_vus_triage_queue.json').write_text(json.dumps(queue_payload, indent=2) + "\\n", encoding='utf-8')
Path(f'{sid}.stage5_annotation.fragment.json').write_text(json.dumps(fragment, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    printf '{"node":"VUS_TRIAGE_HGMD_SEARCH","sample_id":"%s","candidate_vus_count":0,"upgraded_variants":[],"remaining_vus":[],"stub":true}' "${meta.sample_id}" > "${meta.sample_id}.stage5_vus_triage_queue.json"
    printf '{"sample_id":"%s","component":"annotation","acmg_tiered_table":"stub","vus_queue":"stub","vus_upgraded_count":0}' "${meta.sample_id}" > "${meta.sample_id}.stage5_annotation.fragment.json"
    """
}
