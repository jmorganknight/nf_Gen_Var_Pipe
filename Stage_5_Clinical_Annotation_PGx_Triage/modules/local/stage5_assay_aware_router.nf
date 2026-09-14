process STAGE5_ASSAY_AWARE_ROUTER {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage5", mode: 'rellink', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(phased_vcf), path(phased_tbi), val(reference_meta)

    output:
    tuple val(meta), path(phased_vcf), path(phased_tbi), val(reference_meta), path("${meta.sample_id}.stage5_router.json"), emit: router_bundle
    tuple val(meta), path("${meta.sample_id}.stage5_router.fragment.json"), emit: router_fragment

    script:
    def sid = meta.sample_id
    def metaJson = groovy.json.JsonOutput.toJson(meta).replace('\n', ' ').replace('\r', '')
    def refJson = groovy.json.JsonOutput.toJson(reference_meta).replace('\n', ' ').replace('\r', '')
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path

sid = '${sid}'
meta = json.loads('''${metaJson}''')
ref = json.loads('''${refJson}''')

router_path = Path(f'{sid}.stage5_router.json')
fragment_path = Path(f'{sid}.stage5_router.fragment.json')

consent = meta.get('stage0_consent_tokens') or meta.get('consent_tokens') or {}
sf_token = str(consent.get('secondary_findings', ''))
prs_token = str(consent.get('prs_reporting', ''))

sf_enabled = ('CONSENTED' in sf_token and 'SF_ENABLED' in sf_token)
prs_enabled = ('CONSENTED' in prs_token and 'PRS_ENABLED' in prs_token)

snv_mask_bed = str(meta.get('snv_mask_bed') or ref.get('onco_target_bed') or ref.get('capture_wes_bed') or '')
sf_bed = str(ref.get('sf_bed') or '')
prs_backbone_bed = str(ref.get('prs_backbone_bed') or ref.get('onco_target_bed') or '')

warnings = []


def bed_total(path_text):
    p = Path(path_text)
    if not p.exists():
        return None
    total = 0
    with p.open('r', encoding='utf-8') as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) < 3:
                continue
            try:
                start = int(parts[1])
                end = int(parts[2])
            except ValueError:
                continue
            total += max(0, end - start)
    return total


mask_len = bed_total(snv_mask_bed)
sf_len = bed_total(sf_bed)
prs_len = bed_total(prs_backbone_bed)

if mask_len is not None and sf_len and sf_len > 0:
    sf_cov = min(1.0, mask_len / float(sf_len))
else:
    sf_cov = 1.0

if sf_cov < 1.0:
    warnings.append('ACMG_SF_TARGET_MASK_WARNING')

if mask_len is not None and prs_len and prs_len > 0:
    prs_cov = min(1.0, mask_len / float(prs_len))
else:
    prs_cov = 1.0

prs_gate_pass = prs_enabled and prs_cov >= float('${params.prs_min_backbone_coverage}')
if prs_enabled and prs_cov < float('${params.prs_min_backbone_coverage}'):
    warnings.append('INSUFFICIENT_BACKBONE_COVERAGE')

payload = {
    'node': 'STAGE5_ASSAY_AWARE_ROUTER',
    'sample_id': sid,
    'run_mode': str(meta.get('run_mode', 'production')),
    'sequencing_type': str(meta.get('sequencing_type', 'WES')),
    'snv_mask_bed': snv_mask_bed,
    'sf_bed': sf_bed,
    'prs_backbone_bed': prs_backbone_bed,
    'sf_consent_token': sf_token,
    'prs_consent_token': prs_token,
    'sf_enabled': sf_enabled,
    'prs_enabled': prs_enabled,
    'sf_mask_coverage': round(sf_cov, 4),
    'prs_backbone_coverage': round(prs_cov, 4),
    'prs_gate_pass': prs_gate_pass,
    'warnings': warnings,
    'router_audit_code': 'PASS_WITH_WARNINGS' if warnings else 'PASS',
}

fragment = {
    'sample_id': sid,
    'component': 'router',
    'router': payload,
}

router_path.write_text(json.dumps(payload, indent=2) + "\\n", encoding='utf-8')
fragment_path.write_text(json.dumps(fragment, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    printf '{"node":"STAGE5_ASSAY_AWARE_ROUTER","sample_id":"%s","run_mode":"production","sequencing_type":"WES","snv_mask_bed":"stub","sf_bed":"stub","prs_backbone_bed":"stub","sf_consent_token":"WITHHELD|SF_DISABLED","prs_consent_token":"WITHHELD|PRS_DISABLED","sf_enabled":false,"prs_enabled":false,"sf_mask_coverage":1.0,"prs_backbone_coverage":1.0,"prs_gate_pass":false,"warnings":[],"router_audit_code":"PASS","stub":true}' "${meta.sample_id}" > "${meta.sample_id}.stage5_router.json"
    printf '{"sample_id":"%s","component":"router","router":{"stub":true}}' "${meta.sample_id}" > "${meta.sample_id}.stage5_router.fragment.json"
    """
}
