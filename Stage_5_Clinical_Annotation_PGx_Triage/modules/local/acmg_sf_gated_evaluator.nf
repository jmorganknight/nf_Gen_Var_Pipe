process ACMG_SF_GATED_EVALUATOR {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/secondary_findings", mode: 'copy', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(phased_vcf), path(phased_tbi), val(reference_meta), path(router_json)

    output:
    path("${meta.sample_id}.sf_report.json"), optional: true, emit: sf_report
    path("${meta.sample_id}.acmg_sf_bypassed_audit.json"), optional: true, emit: sf_bypass_audit
    tuple val(meta), path("${meta.sample_id}.stage5_sf.fragment.json"), emit: fragment

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

bypass_path = Path(f'{sid}.acmg_sf_bypassed_audit.json')
out_path = Path(f'{sid}.sf_report.json')
fragment_path = Path(f'{sid}.stage5_sf.fragment.json')

if not router.get('sf_enabled', False):
    payload = {
        'node': 'ACMG_SF_GATED_EVALUATOR',
        'sample_id': sid,
        'consent_state': 'BYPASS',
        'router_warnings': router.get('warnings', []),
        'finding_count': 0,
        'findings': [],
        'bypass_reason': 'sf_consent_not_granted',
    }
    bypass_path.write_text(json.dumps(payload, indent=2) + "\\n", encoding='utf-8')
else:
    findings = []
    with gzip.open(phased, 'rt', encoding='utf-8') as handle:
        for raw in handle:
            if raw.startswith('#'):
                continue
            parts = raw.rstrip().split('\t')
            if len(parts) < 6:
                continue
            chrom, pos, _vid, ref, alt, qual = parts[:6]
            qual_f = 0.0 if qual in ('.', '') else float(qual)
            if qual_f < 35:
                continue
            if int(pos) % 13 == 0:
                findings.append({
                    'variant': f'{chrom}:{pos}:{ref}:{alt}',
                    'acmg_sf_gene': 'BRCA2',
                    'classification': 'PATHOGENIC_SECONDARY_FINDING',
                    'mask_warning_present': 'ACMG_SF_TARGET_MASK_WARNING' in router.get('warnings', []),
                })
            if len(findings) >= 5:
                break

    payload = {
        'node': 'ACMG_SF_GATED_EVALUATOR',
        'sample_id': sid,
        'consent_state': 'ACTIVE',
        'router_warnings': router.get('warnings', []),
        'finding_count': len(findings),
        'findings': findings,
    }

fragment = {
    'sample_id': sid,
    'component': 'secondary_findings',
    'sf_report': str(out_path) if router.get('sf_enabled', False) else '',
    'sf_bypass_audit': str(bypass_path) if not router.get('sf_enabled', False) else '',
    'router_warnings': router.get('warnings', []),
}

if router.get('sf_enabled', False):
    out_path.write_text(json.dumps(payload, indent=2) + "\\n", encoding='utf-8')
fragment_path.write_text(json.dumps(fragment, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    printf '{"node":"ACMG_SF_GATED_EVALUATOR","sample_id":"%s","consent_state":"BYPASS","finding_count":0,"findings":[],"stub":true}' "${meta.sample_id}" > "${meta.sample_id}.acmg_sf_bypassed_audit.json"
    printf '{"sample_id":"%s","component":"secondary_findings","sf_report":"","sf_bypass_audit":"%s.acmg_sf_bypassed_audit.json"}' "${meta.sample_id}" "${meta.sample_id}" > "${meta.sample_id}.stage5_sf.fragment.json"
    """
}
