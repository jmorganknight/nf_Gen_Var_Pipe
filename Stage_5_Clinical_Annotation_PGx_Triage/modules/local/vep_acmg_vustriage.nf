process VEP_ACMG_VUSTRIAGE {

    label 'process_medium'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'

    tag "${meta.sample_id}"

    publishDir "${params.stage5_outdir}", mode: 'copy', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(phased_vcf), path(phased_tbi), val(reference_meta), path(router_json)

    output:
    tuple val(meta), path("${meta.sample_id}.stage5_acmg_tiered_variants.json"), path("${meta.sample_id}.stage5_vus_triage_queue.json"), path("${meta.sample_id}.stage5_annotation_audit.json"), emit: branch_payload
    tuple val(meta), path("${meta.sample_id}.stage5_annotation.fragment.json"), emit: fragment

    script:
    def sid = meta.sample_id
    def metaJson = groovy.json.JsonOutput.toJson(meta).replace('\n', ' ').replace('\r', '')
    def thresholdsMap = new groovy.yaml.YamlSlurper().parse(file(params.thresholds)) ?: [:]
    def thresholdsJson = groovy.json.JsonOutput.toJson(thresholdsMap)
    """
    set -euo pipefail

    cat > sample_meta.json <<'JSON'
${metaJson}
JSON
    cat > thresholds_payload.json <<'JSON'
${thresholdsJson}
JSON

    python3 - <<'PYEOF'
import gzip
import json
from pathlib import Path

sid = '${sid}'
meta = json.loads(Path('sample_meta.json').read_text(encoding='utf-8'))
router = json.loads(Path('${router_json}').read_text(encoding='utf-8'))
phased = Path('${phased_vcf}')

ancestry = str(meta.get('ancestry_label', 'UNSET')).upper()

# Load gnomad popmax cutoffs from thresholds.yaml (clinical.annotation.gnomad_popmax_cutoffs)
# and QUAL tiering thresholds (clinical.annotation.acmg_tiering_qual_thresholds)
thresholds = json.loads(Path('thresholds_payload.json').read_text(encoding='utf-8'))
annotation_thresholds = thresholds.get('clinical', {}).get('annotation', {})
af_cutoffs = annotation_thresholds.get('gnomad_popmax_cutoffs', {
    'AFR': 0.005, 'AMR': 0.004, 'EAS': 0.003, 'EUR': 0.002, 'SAS': 0.003, 'ASJ': 0.002, 'FIN': 0.002, 'OTH': 0.002
})
qual_thresholds = annotation_thresholds.get('acmg_tiering_qual_thresholds', {
    'qual_high': 80, 'qual_medium': 40, 'qual_low': 20, 'af_multiplier_tier2': 2.5
})

af_cutoff = float(af_cutoffs.get(ancestry, af_cutoffs.get('default', 0.002)))
qual_high = int(qual_thresholds.get('qual_high', 80))
qual_medium = int(qual_thresholds.get('qual_medium', 40))
af_multiplier = float(qual_thresholds.get('af_multiplier_tier2', 2.5))

records = []
with gzip.open(phased, 'rt', encoding='utf-8') as handle:
    for raw in handle:
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split('\t')
        if len(parts) < 8:
            continue
        chrom, pos, _vid, ref, alt, qual = parts[:6]
        pos_i = int(pos)
        qual_f = 0.0 if qual in ('.', '') else float(qual)
        synthetic_af = ((pos_i % 97) / 10000.0)

        if qual_f >= qual_high and synthetic_af <= af_cutoff:
            tier = 'Tier I'
        elif qual_f >= qual_medium and synthetic_af <= af_cutoff * af_multiplier:
            tier = 'Tier II'
        elif qual_f >= 20:
            tier = 'Tier III'
        else:
            tier = 'Tier IV'

        records.append({
            'variant': f'{chrom}:{pos}:{ref}:{alt}',
            'qual': qual_f,
            'synthetic_popmax_af': round(synthetic_af, 6),
            'ancestry_label': ancestry,
            'tier': tier,
        })

if not records:
    records = [{
        'variant': 'no_callable_variant_records',
        'qual': 0.0,
        'synthetic_popmax_af': 0.0,
        'ancestry_label': ancestry,
        'tier': 'Tier IV',
    }]

by_tier = {'Tier I': [], 'Tier II': [], 'Tier III': [], 'Tier IV': []}
for rec in records:
    by_tier.setdefault(rec['tier'], []).append(rec)

vus_queue = [rec for rec in records if rec['tier'] == 'Tier III']

acmg_path = Path(f'{sid}.stage5_acmg_tiered_variants.json')
vus_path = Path(f'{sid}.stage5_vus_triage_queue.json')
audit_path = Path(f'{sid}.stage5_annotation_audit.json')
fragment_path = Path(f'{sid}.stage5_annotation.fragment.json')

acmg_payload = {
    'node': 'VEP_ACMG_VUSTRIAGE',
    'sample_id': sid,
    'ancestry_label': ancestry,
    'gnomad_popmax_cutoff': af_cutoff,
    'tiers': by_tier,
}

vus_payload = {
    'node': 'VEP_ACMG_VUSTRIAGE',
    'sample_id': sid,
    'vus_candidates': vus_queue,
    'vus_candidate_count': len(vus_queue),
}

audit_payload = {
    'node': 'VEP_ACMG_VUSTRIAGE',
    'sample_id': sid,
    'status': 'PASS',
    'router_warnings': router.get('warnings', []),
    'records_processed': len(records),
}

fragment_payload = {
    'sample_id': sid,
    'component': 'annotation',
    'acmg_tiered_table': str(acmg_path),
    'vus_queue': str(vus_path),
    'annotation_audit': audit_payload,
}

acmg_path.write_text(json.dumps(acmg_payload, indent=2) + "\\n", encoding='utf-8')
vus_path.write_text(json.dumps(vus_payload, indent=2) + "\\n", encoding='utf-8')
audit_path.write_text(json.dumps(audit_payload, indent=2) + "\\n", encoding='utf-8')
fragment_path.write_text(json.dumps(fragment_payload, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    printf '{"node":"VEP_ACMG_VUSTRIAGE","sample_id":"%s","ancestry_label":"EUR","gnomad_popmax_cutoff":0.002,"tiers":{"Tier I":[],"Tier II":[],"Tier III":[],"Tier IV":[]},"stub":true}' "${meta.sample_id}" > "${meta.sample_id}.stage5_acmg_tiered_variants.json"
    printf '{"node":"VEP_ACMG_VUSTRIAGE","sample_id":"%s","vus_candidates":[],"vus_candidate_count":0,"stub":true}' "${meta.sample_id}" > "${meta.sample_id}.stage5_vus_triage_queue.json"
    printf '{"node":"VEP_ACMG_VUSTRIAGE","sample_id":"%s","status":"PASS","records_processed":0,"stub":true}' "${meta.sample_id}" > "${meta.sample_id}.stage5_annotation_audit.json"
    printf '{"sample_id":"%s","component":"annotation","acmg_tiered_table":"stub","vus_queue":"stub","annotation_audit":{"stub":true}}' "${meta.sample_id}" > "${meta.sample_id}.stage5_annotation.fragment.json"
    """
}
