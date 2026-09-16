process STAGE3_HOMOLOGOUS_PSEUDOGENES {
    label 'variant_heavy'
    container 'genvar-core:2.1.0'
    cpus { (params.stage3_homologous_cpus ?: params.stage3_cpus ?: params.stage3_variant_heavy_default_cpus ?: 8) as int }

    input:
    tuple val(sample_id), path(stage2_manifest), path(sorted_bam), path(sorted_bai), val(is_wgs), val(target_bed), path(fasta), path(fasta_fai), val(sample_qc_meta), val(stage3_refs), val(sample_meta)

    output:
    tuple val(sample_id), path('homologous_pseudogenes.calibrated.vcf'), path('stage3.homologous_pseudogenes.audit.json'), val(stage3_refs), val(sample_meta), emit: calibrated_vcf
    path 'stage3.homologous_pseudogenes.audit.json', emit: audit

    script:
    def stage3RefsMap = (stage3_refs instanceof Map) ? (stage3_refs as Map) : [:]
    def pseudogeneMask = (stage3RefsMap.pseudogene_mask ?: stage3RefsMap.cyp2d6_paralog_mask_bed ?: '')?.toString()
    """
    set -euo pipefail

    MASK_BED="${pseudogeneMask}"

    if [[ -z "\${MASK_BED}" || ! -f "\${MASK_BED}" ]]; then
        echo "STAGE3_PRECONDITION_FAILURE: pseudogene mask asset missing for homologous_pseudogenes branch" >&2
        exit 1
    fi

    for tool in bcftools python3; do
        if ! command -v "\${tool}" >/dev/null 2>&1; then
            echo "STAGE3_PRECONDITION_FAILURE: required homologous-pseudogene tool missing: \${tool}" >&2
            exit 1
        fi
    done

    bcftools mpileup \
      --threads ${task.cpus ?: 1} \
      -a FORMAT/DP,FORMAT/AD \
      -f "${fasta}" \
      -R "\${MASK_BED}" \
      -Ou "${sorted_bam}" \
    | bcftools call \
      --threads ${task.cpus ?: 1} \
      -mv \
      -Ov \
      -o homologous_pseudogenes.raw.vcf

    python3 - <<'PYEOF'
import json
from pathlib import Path

in_vcf = Path('homologous_pseudogenes.raw.vcf')
out_vcf = Path('homologous_pseudogenes.calibrated.vcf')

header = []
records = []
for line in in_vcf.read_text(encoding='utf-8', errors='replace').splitlines():
    if line.startswith('#'):
        header.append(line)
    elif line.strip():
        records.append(line)

if not any(h.startswith('##INFO=<ID=PARALOG_HOMOLOGY') for h in header):
    header.insert(len([h for h in header if h.startswith('##')]), '##INFO=<ID=PARALOG_HOMOLOGY,Number=1,Type=Integer,Description="Overlap with homologous/pseudogene risk mask">')
if not any(h.startswith('##INFO=<ID=BRANCH') for h in header):
    header.insert(len([h for h in header if h.startswith('##')]), '##INFO=<ID=BRANCH,Number=1,Type=String,Description="Stage 3 variant branch origin">')

kept = 0
with out_vcf.open('w', encoding='utf-8') as out:
    out.write(chr(10).join(header) + chr(10))
    for raw in records:
        cols = raw.split(chr(9))
        if len(cols) < 8:
            continue
        info = cols[7] if cols[7] and cols[7] != '.' else ''
        extra = 'PARALOG_HOMOLOGY=1;BRANCH=homologous_pseudogenes'
        cols[7] = extra if not info else f"{info};{extra}"
        out.write(chr(9).join(cols) + chr(10))
        kept += 1

audit = {
    'sample_id': '${sample_id}',
    'stage2_manifest': str(Path('${stage2_manifest}').resolve()),
    'sorted_bam': str(Path('${sorted_bam}').resolve()),
    'sorted_bai': str(Path('${sorted_bai}').resolve()),
    'fasta': str(Path('${fasta}').resolve()),
    'pseudogene_mask': str(Path('${pseudogeneMask}').resolve()) if '${pseudogeneMask}' else None,
    'records_emitted': kept,
    'status': 'PASS',
}
Path('stage3.homologous_pseudogenes.audit.json').write_text(json.dumps(audit, indent=2) + chr(10), encoding='utf-8')
PYEOF
    """

    stub:
    """
    cat > homologous_pseudogenes.calibrated.vcf <<'VCF'
##fileformat=VCFv4.2
##source=STAGE3_HOMOLOGOUS_PSEUDOGENES_STUB
##INFO=<ID=BRANCH,Number=1,Type=String,Description="Stage 3 variant branch origin">
#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
22\t25000000\t.\tN\t<DEL>\t60\tPASS\tSVTYPE=DEL;END=26000000;PARALOGY=PCDH11;BRANCH=homologous_pseudogenes
VCF
    cat > stage3.homologous_pseudogenes.audit.json <<'JSON'
{
  "sample_id": "${sample_id}",
  "stage2_manifest": "stub_path",
  "sorted_bam": "stub_path",
  "sorted_bai": "stub_path",
  "fasta": "stub_path",
  "is_wgs": true,
  "paralogy_bed": "stub_path",
  "records_raw_total": 1,
  "records_emitted": 1,
  "status": "PASS",
  "stub": true
}
JSON
    """
}
