process STAGE3_STR_EXPANSIONS {
    label 'variant_heavy'
    container 'genvar-core:2.1.0'
    cpus { (params.stage3_str_cpus ?: params.stage3_cpus ?: params.stage3_variant_heavy_default_cpus ?: 8) as int }

    input:
    tuple val(sample_id), path(stage2_manifest), path(sorted_bam), path(sorted_bai), val(is_wgs), val(target_bed), path(fasta), path(fasta_fai), val(sample_qc_meta), val(stage3_refs), val(sample_meta)

    output:
    tuple val(sample_id), path('str_expansions.calibrated.vcf'), path('stage3.str_expansions.audit.json'), val(stage3_refs), val(sample_meta), emit: calibrated_vcf
    path 'stage3.str_expansions.audit.json', emit: audit

    script:
    """
    set -euo pipefail

    CATALOG="${stage3_refs.expansionhunter_catalog ?: ''}"
    if [[ -z "\${CATALOG}" || ! -f "\${CATALOG}" ]]; then
        echo "STAGE3_PRECONDITION_FAILURE: missing ExpansionHunter catalog for str_expansions branch" >&2
        exit 1
    fi

    for tool in ExpansionHunter python3; do
        if ! command -v "\${tool}" >/dev/null 2>&1; then
            echo "STAGE3_PRECONDITION_FAILURE: required STR tool missing: \${tool}" >&2
            exit 1
        fi
    done

    mkdir -p expansionhunter_out
    prefix="expansionhunter_out/${sample_id}.str"

    ExpansionHunter \
      --reads "${sorted_bam}" \
      --reference "${fasta}" \
      --variant-catalog "\${CATALOG}" \
      --output-prefix "\${prefix}"

    python3 - <<'PYEOF'
import json
from pathlib import Path


def normalize_chrom(chrom):
    c = str(chrom or '1')
    return c if c.startswith('chr') else f'chr{c}'


vcf_input = Path('expansionhunter_out/${sample_id}.str.vcf')
json_input = Path('expansionhunter_out/${sample_id}.str.json')
out_vcf = Path('str_expansions.calibrated.vcf')

records = []
source = None

if vcf_input.exists():
    source = 'vcf'
    for raw in vcf_input.read_text(encoding='utf-8', errors='replace').splitlines():
        if not raw or raw.startswith('#'):
            continue
        cols = raw.split(chr(9))
        if len(cols) < 8:
            continue
        # ExpansionHunter can emit '.' ALT for some loci; enforce schema-safe symbolic STR alleles.
        cols[3] = cols[3] if cols[3] and cols[3] != '.' else 'N'
        cols[4] = cols[4] if cols[4] and cols[4] != '.' else '<STR>'
        info = cols[7] if cols[7] and cols[7] != '.' else ''
        cols[7] = 'BRANCH=str_expansions' if not info else f"{info};BRANCH=str_expansions"
        records.append(cols[:8])
elif json_input.exists():
    source = 'json'
    payload = json.loads(json_input.read_text(encoding='utf-8'))
    locus_results = payload.get('LocusResults') or payload.get('locusResults') or payload.get('Results') or payload.get('results') or {}
    if isinstance(locus_results, list):
        locus_iter = {str(i): entry for i, entry in enumerate(locus_results)}
    else:
        locus_iter = locus_results

    for locus_id, entry in locus_iter.items():
        if not isinstance(entry, dict):
            continue
        ref_region = entry.get('ReferenceRegion') or entry.get('referenceRegion') or ''
        chrom = 'chr1'
        pos = 1
        end = 2
        if ':' in ref_region and '-' in ref_region:
            chrom_token, range_token = ref_region.split(':', 1)
            start_token, end_token = range_token.split('-', 1)
            chrom = normalize_chrom(chrom_token)
            try:
                pos = int(start_token)
                end = int(end_token)
            except Exception:
                pos = 1
                end = 2

        genotype = entry.get('Genotype') or entry.get('genotype') or 'NA'
        records.append([
            chrom,
            str(pos),
            '.',
            'N',
            '<STR>',
            '60',
            'PASS',
            f'SVTYPE=STR;END={end};LOCUS={locus_id};GENOTYPE={genotype};BRANCH=str_expansions'
        ])
else:
    raise SystemExit('STAGE3_PRECONDITION_FAILURE: ExpansionHunter emitted neither VCF nor JSON output')

with out_vcf.open('w', encoding='utf-8') as out:
    out.write('##fileformat=VCFv4.2' + chr(10))
    out.write('##source=STAGE3_STR_EXPANSIONS' + chr(10))
    out.write('##INFO=<ID=BRANCH,Number=1,Type=String,Description="Stage 3 variant branch origin">' + chr(10))
    out.write('#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO' + chr(10))
    for cols in records:
        out.write(chr(9).join(cols[:8]) + chr(10))

audit = {
    'sample_id': '${sample_id}',
    'stage2_manifest': str(Path('${stage2_manifest}').resolve()),
    'sorted_bam': str(Path('${sorted_bam}').resolve()),
    'sorted_bai': str(Path('${sorted_bai}').resolve()),
    'fasta': str(Path('${fasta}').resolve()),
    'catalog': str(Path('${stage3_refs.expansionhunter_catalog ?: ''}').resolve()) if '${stage3_refs.expansionhunter_catalog ?: ''}' else None,
    'source_payload': source,
    'records_emitted': len(records),
    'status': 'PASS',
}
Path('stage3.str_expansions.audit.json').write_text(json.dumps(audit, indent=2) + chr(10), encoding='utf-8')
PYEOF
    """

    stub:
    """
    cat > str_expansions.calibrated.vcf <<'VCF'
##fileformat=VCFv4.2
##source=STAGE3_STR_EXPANSIONS_STUB
##INFO=<ID=BRANCH,Number=1,Type=String,Description="Stage 3 variant branch origin">
#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
1\t50000\t.\tN\t<STR>\t60\tPASS\tSVTYPE=STR;END=50100;LOCUS=STR_LOCUS_1;GENOTYPE=5/7;BRANCH=str_expansions
VCF
    cat > stage3.str_expansions.audit.json <<'JSON'
{
  "sample_id": "${sample_id}",
  "stage2_manifest": "stub_path",
  "sorted_bam": "stub_path",
  "sorted_bai": "stub_path",
  "fasta": "stub_path",
  "catalog": "stub_path",
  "source_payload": "stub",
  "records_emitted": 1,
  "status": "PASS",
  "stub": true
}
JSON
    """
}
