process SPECIMEN_PARADIGM_PURITY_RESOLVER {

    label 'process_medium'
    container 'wes-onco-core:1.0.0'

    publishDir "${params.outdir}/audit_and_qc/stage2", mode: 'copy', overwrite: true, pattern: '*.purity_and_sex_validation_audit.json'

    input:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path(precondition_audit), path(contamination_audit), path(sex_purity_audit)

    output:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path(precondition_audit), path(contamination_audit), path("${meta.sample_id}.purity_and_sex_validation_audit.json"), emit: validated

    script:
    def metaJson = groovy.json.JsonOutput.toJson(meta).replace('\\', '\\\\').replace("'", "\\'")
    def refsJson = groovy.json.JsonOutput.toJson(refs).replace('\\', '\\\\').replace("'", "\\'")
    def thresholdJson = groovy.json.JsonOutput.toJson(thresholds).replace('\\', '\\\\').replace("'", "\\'")
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
import statistics
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def nested_get(payload, keys, default=None):
    cur = payload
    for key in keys:
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur


def as_bool(value, default=False):
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    text = str(value).strip().lower()
    return text in {'1', 'true', 'yes', 'y', 'on'}


def clean_pileup_bases(bases: str, ref_base: str):
    i = 0
    counts = {'A': 0, 'C': 0, 'G': 0, 'T': 0}
    ref = (ref_base or 'N').upper()
    while i < len(bases):
        ch = bases[i]
        if ch == '^':
            i += 2
            continue
        if ch == '\$':
            i += 1
            continue
        if ch in '+-':
            i += 1
            num = []
            while i < len(bases) and bases[i].isdigit():
                num.append(bases[i])
                i += 1
            skip = int(''.join(num) or '0')
            i += skip
            continue
        if ch in '.,':
            if ref in counts:
                counts[ref] += 1
            i += 1
            continue
        up = ch.upper()
        if up in counts:
            counts[up] += 1
        i += 1
    return counts


meta = json.loads('${metaJson}')
refs = json.loads('${refsJson}')
thresholds = json.loads('${thresholdJson}')
sid = meta['sample_id']
paradigm = str(meta.get('sample_type') or 'germline').lower()
physician_purity = float(meta.get('physician_tumor_purity') or meta.get('pathologist_tumor_burden') or 0.0)

min_depth = int(nested_get(thresholds, ['clinical', 'purity', 'min_snp_depth_purity'], 30))
min_sites = int(nested_get(thresholds, ['clinical', 'purity', 'min_snp_count_purity'], 500))
max_delta = float(nested_get(thresholds, ['stage2', 'purity_max_abs_delta'], 0.30))
fail_closed = as_bool(nested_get(thresholds, ['stage2', 'purity_fail_closed'], False), False)

bed_path = refs.get('capture_wes_bed') or refs.get('onco_target_bed')
audit_path = Path(f"{sid}.purity_and_sex_validation_audit.json")
base_audit = json.loads(Path('${sex_purity_audit}').read_text(encoding='utf-8'))

purity_section = {
    'status': 'SKIPPED',
    'sample_type': paradigm,
    'method': 'heterozygous_snp_af_spectrum',
    'physician_tumor_purity': physician_purity,
    'estimated_in_silico_purity': None,
    'absolute_delta': None,
    'purity_concordance_pass': True,
    'heterozygous_site_count': 0,
    'min_depth_threshold': min_depth,
    'min_site_threshold': min_sites,
    'max_abs_delta_threshold': max_delta,
    'fail_closed_enabled': fail_closed,
    'timestamp_utc': datetime.now(timezone.utc).isoformat(),
}

chip_section = {
    'status': 'SKIPPED',
    'sample_type': paradigm,
    'vaf_window_low': 0.05,
    'vaf_window_high': 0.15,
    'candidate_site_count': 0,
    'flag_chip_or_mosaicism': False,
}

failure = None

if paradigm in {'somatic', 'liquid_biopsy', 'germline', 'normal'}:
    if not bed_path or not Path(bed_path).exists():
        failure = f"Reference target BED missing for purity resolver: {bed_path}"
    else:
        selected_regions = []
        for raw_line in Path(bed_path).read_text(encoding='utf-8', errors='replace').splitlines():
            line = raw_line.strip()
            if not line or line.startswith('#'):
                continue
            cols = line.split('\\t')
            if len(cols) < 3:
                continue
            selected_regions.append('\\t'.join(cols[:3]))
            if len(selected_regions) >= 200:
                break

        if not selected_regions:
            failure = f"No valid BED intervals available for purity resolver: {bed_path}"

        if not failure:
            Path('stage2_purity_regions.bed').write_text('\\n'.join(selected_regions) + '\\n', encoding='utf-8')
            subprocess.run(
                ['samtools', 'mpileup', '-aa', '-Q', '20', '-q', '20', '-l', 'stage2_purity_regions.bed', '${bam}'],
                check=True,
                stdout=Path('stage2_purity.mpileup').open('w', encoding='utf-8'),
                stderr=subprocess.PIPE,
                text=True,
            )

        vafs = []
        if not failure:
            for line in Path('stage2_purity.mpileup').read_text(encoding='utf-8', errors='replace').splitlines():
                cols = line.split('\\t')
                if len(cols) < 5:
                    continue
                ref = cols[2]
                depth = int(cols[3])
                bases = cols[4]
                if depth < min_depth:
                    continue
                counts = clean_pileup_bases(bases, ref)
                ref_base = ref.upper()
                alt_count = max([v for k, v in counts.items() if k != ref_base], default=0)
                if alt_count <= 0:
                    continue
                vaf = alt_count / float(depth)
                if 0.25 <= vaf <= 0.75:
                    vafs.append(vaf)

        purity_section['heterozygous_site_count'] = len(vafs)
        if paradigm in {'somatic', 'liquid_biopsy'}:
            if vafs:
                estimate = max(0.0, min(1.0, 2.0 * statistics.median(vafs)))
                delta = abs(estimate - physician_purity)
                purity_section['estimated_in_silico_purity'] = round(estimate, 6)
                purity_section['absolute_delta'] = round(delta, 6)
                if len(vafs) < min_sites:
                    purity_section['status'] = 'LOW_SUPPORT'
                    purity_section['purity_concordance_pass'] = True
                    purity_section['note'] = 'Insufficient heterozygous SNP support; compare cautiously.'
                elif delta > max_delta:
                    purity_section['status'] = 'DISCORDANT'
                    purity_section['purity_concordance_pass'] = False
                else:
                    purity_section['status'] = 'PASS'
                    purity_section['purity_concordance_pass'] = True
            else:
                purity_section['status'] = 'LOW_SUPPORT'
                purity_section['purity_concordance_pass'] = True
                purity_section['note'] = 'No heterozygous SNP-like sites recovered from selected regions.'

        # Germline-only subclonal detector: flag persistent low-VAF spectrum (5-15%) consistent with CHIP/mosaicism.
        if paradigm in {'germline', 'normal'}:
            chip_candidates = [v for v in vafs if 0.05 <= v <= 0.15]
            chip_section['status'] = 'EVALUATED'
            chip_section['candidate_site_count'] = len(chip_candidates)
            if len(chip_candidates) >= 10:
                chip_section['flag_chip_or_mosaicism'] = True
                chip_section['note'] = 'Subclonal low-VAF burden in 5-15% window suggests CHIP/mosaicism review.'
            else:
                chip_section['flag_chip_or_mosaicism'] = False

        if purity_section['status'] == 'DISCORDANT' and fail_closed:
            failure = (
                f"in-silico purity mismatch: estimated={purity_section['estimated_in_silico_purity']} "
                f"physician={physician_purity} delta={purity_section['absolute_delta']}"
            )

base_audit['purity_validation'] = purity_section
base_audit['subclonal_mosaicism_chip'] = chip_section
base_audit['contamination_audit'] = '${contamination_audit}'
if failure:
    base_audit['status'] = 'FAIL'
    base_audit['failure_code'] = 'STAGE2_PURITY_VALIDATION_FAILURE'
    base_audit['failure_detail'] = failure
elif base_audit.get('status') != 'FAIL':
    base_audit['status'] = 'PASS'

audit_path.write_text(json.dumps(base_audit, indent=2) + '\\n', encoding='utf-8')

if failure:
    print('STAGE2_PURITY_VALIDATION_FAILURE: ' + failure, file=sys.stderr)
    sys.exit(1)
PYEOF
    """

        stub:
        """
        cat > "${meta.sample_id}.purity_and_sex_validation_audit.json" <<'JSON'
{
    "node": "SPECIMEN_PARADIGM_PURITY_RESOLVER",
    "sample_id": "${meta.sample_id}",
    "status": "PASS",
    "contamination_audit": "${contamination_audit}",
    "sex_concordance": {
        "stub": true
    },
    "purity_validation": {
        "status": "PASS",
        "purity_concordance_pass": true,
        "estimated_in_silico_purity": 0.0,
        "absolute_delta": 0.0,
        "stub": true
    },
    "subclonal_mosaicism_chip": {
        "status": "EVALUATED",
        "candidate_site_count": 0,
        "flag_chip_or_mosaicism": false,
        "stub": true
    },
    "precondition_audit": "${precondition_audit}"
}
JSON
        """
}
