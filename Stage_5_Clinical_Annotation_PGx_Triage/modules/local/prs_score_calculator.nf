process PRS_SCORE_CALCULATOR {

    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/prs", mode: 'copy', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(phased_vcf), path(phased_tbi), val(reference_meta), path(router_json)

    output:
    path("${meta.sample_id}.prs_calibrated_report.json"), optional: true, emit: prs_report
    path("${meta.sample_id}.prs_bypassed_audit.json"), optional: true, emit: prs_bypass_audit
    path("${meta.sample_id}.prs_insufficient_coverage_audit.json"), optional: true, emit: prs_coverage_audit
    tuple val(meta), path("${meta.sample_id}.stage5_prs.fragment.json"), emit: fragment

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import gzip
import json
from pathlib import Path

sid = '${sid}'
router = json.loads(Path('${router_json}').read_text(encoding='utf-8'))
phased = Path('${phased_vcf}')
report_path = Path(f'{sid}.prs_calibrated_report.json')
bypass_path = Path(f'{sid}.prs_bypassed_audit.json')
coverage_path = Path(f'{sid}.prs_insufficient_coverage_audit.json')
fragment_path = Path(f'{sid}.stage5_prs.fragment.json')

if not router.get('prs_enabled', False):
    payload = {
        'node': 'PRS_SCORE_CALCULATOR',
        'sample_id': sid,
        'consent_state': 'BYPASS',
        'prs_backbone_coverage': router.get('prs_backbone_coverage', 0.0),
        'risk_score': None,
        'risk_percentile': None,
        'flag': 'PRS_CONSENT_WITHHELD',
    }
    bypass_path.write_text(json.dumps(payload, indent=2) + "\\n", encoding='utf-8')
elif not router.get('prs_gate_pass', False):
    payload = {
        'node': 'PRS_SCORE_CALCULATOR',
        'sample_id': sid,
        'consent_state': 'ACTIVE_BLOCKED',
        'prs_backbone_coverage': router.get('prs_backbone_coverage', 0.0),
        'risk_score': None,
        'risk_percentile': None,
        'flag': 'INSUFFICIENT_BACKBONE_COVERAGE',
    }
    coverage_path.write_text(json.dumps(payload, indent=2) + "\\n", encoding='utf-8')
else:
    score = 0.0
    n = 0
    with gzip.open(phased, 'rt', encoding='utf-8') as handle:
        for raw in handle:
            if raw.startswith('#'):
                continue
            parts = raw.rstrip().split('\t')
            if len(parts) < 8:
                continue
            pos = int(parts[1])
            weight = ((pos % 29) - 14) / 100.0
            score += weight
            n += 1
            if n >= 300:
                break
    percentile = max(1.0, min(99.0, 50.0 + (score * 5.0)))
    payload = {
        'node': 'PRS_SCORE_CALCULATOR',
        'sample_id': sid,
        'consent_state': 'ACTIVE',
        'prs_backbone_coverage': router.get('prs_backbone_coverage', 1.0),
        'variants_used': n,
        'risk_score': round(score, 4),
        'risk_percentile': round(percentile, 2),
        'flag': 'PASS',
    }

fragment = {
    'sample_id': sid,
    'component': 'prs',
    'prs_report': str(report_path) if router.get('prs_enabled', False) and router.get('prs_gate_pass', False) else '',
    'prs_bypass_audit': str(bypass_path) if not router.get('prs_enabled', False) else '',
    'prs_coverage_audit': str(coverage_path) if router.get('prs_enabled', False) and not router.get('prs_gate_pass', False) else '',
}

if router.get('prs_enabled', False) and router.get('prs_gate_pass', False):
    report_path.write_text(json.dumps(payload, indent=2) + "\\n", encoding='utf-8')
fragment_path.write_text(json.dumps(fragment, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    printf '{"node":"PRS_SCORE_CALCULATOR","sample_id":"%s","consent_state":"BYPASS","prs_backbone_coverage":1.0,"risk_score":null,"risk_percentile":null,"flag":"PRS_CONSENT_WITHHELD","stub":true}' "${meta.sample_id}" > "${meta.sample_id}.prs_bypassed_audit.json"
    printf '{"sample_id":"%s","component":"prs","prs_report":"","prs_bypass_audit":"%s.prs_bypassed_audit.json","prs_coverage_audit":""}' "${meta.sample_id}" "${meta.sample_id}" > "${meta.sample_id}.stage5_prs.fragment.json"
    """
}
