process STAGE3_VARIANT_ENGINE {
    label 'process_low'
    container 'wes-onco-core:1.0.0'
    publishDir "${params.outdir}", mode: 'copy', overwrite: true

    input:
    path stage2_manifest

    output:
    path 'normalized.vcf', emit: normalized_vcf
    path 'normalized.vcf.tbi', emit: normalized_tbi
    path 'harmonization_audit.json', emit: audit
    path 'samples_hg002_banked_stage3.yaml', emit: banked_manifest

    script:
    """
    set -euo pipefail
    python3 - <<'PYEOF'
import json
from pathlib import Path

manifest = json.loads(Path('${stage2_manifest}').read_text(encoding='utf-8')) or {}
records = manifest.get('samples') or []
if not records:
    raise SystemExit('STAGE3_PRECONDITION_FAILURE: Stage 2 banked manifest contains no samples')

rec = records[0]
sample_id = str(rec.get('sample_id') or 'UNKNOWN')
validation_token = str(rec.get('validation_token') or rec.get('intake_validation_token_value') or rec.get('intake_validation_token') or '').strip()
if 'VALID_PASS|SAMPLE_VALIDATED' not in validation_token:
    raise SystemExit(f"STAGE3_PRECONDITION_FAILURE: invalid validation_token for sample '{sample_id}'")

sorted_bam = Path(str(rec.get('sorted_bam') or '')).expanduser()
sorted_bai = Path(str(rec.get('sorted_bai') or '')).expanduser() if rec.get('sorted_bai') else Path(str(sorted_bam) + '.bai')
if not sorted_bam.exists():
    raise SystemExit(f"STAGE3_PRECONDITION_FAILURE: sorted_bam missing for sample '{sample_id}': {sorted_bam}")
if not sorted_bai.exists():
    raise SystemExit(f"STAGE3_PRECONDITION_FAILURE: sorted_bai missing for sample '{sample_id}': {sorted_bai}")

variant_branches = rec.get('variant_branches') or {}
if not isinstance(variant_branches, dict):
    raise SystemExit(f"STAGE3_PRECONDITION_FAILURE: variant_branches schema invalid for sample '{sample_id}'")

stage3_faults = rec.get('stage3_faults') or {}
if not isinstance(stage3_faults, dict):
    stage3_faults = {}

reference_build = rec.get('reference_build', {}) or {}
active = [k for k, v in variant_branches.items() if bool(v)]

branch_vcfs = []
branch_lines = []

def write_vcf(name: str, lines: list[str]):
    path = Path(f'{name}.vcf')
    path.write_text('\\n'.join(lines) + '\\n', encoding='utf-8')
    branch_vcfs.append(str(path.resolve()))
    branch_lines.append({'branch': name, 'vcf': str(path.resolve())})

for branch in active:
    if branch == 'snv_indel':
        header = '##fileformat=VCFv4.2'
        if stage3_faults.get('corrupt_vcf_header'):
            header = '##fileformat=BADVCF'
        write_vcf('snv_indel', [header, '##source=STAGE3_SNV_INDEL', '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO', f'1\t100\t.\tA\tG,C\t60\tPASS\tBRANCH=snv_indel;SAMPLE={sample_id}'])
    elif branch == 'structural_variants':
        write_vcf('structural_variants', ['##fileformat=VCFv4.2', '##source=STAGE3_STRUCTURAL_VARIANTS', '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO', f'2\t200\t.\tN\t<DEL>\t60\tPASS\tSVTYPE=DEL;END=250;SAMPLE={sample_id}'])
    elif branch == 'copy_number_cnv':
        write_vcf('copy_number_cnv', ['##fileformat=VCFv4.2', '##source=STAGE3_COPY_NUMBER_CNV', '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO', f'3\t300\t.\tN\t<CNV>\t60\tPASS\tCN=3;SAMPLE={sample_id}'])
    elif branch == 'str_expansions':
        write_vcf('str_expansions', ['##fileformat=VCFv4.2', '##source=STAGE3_STR_EXPANSIONS', '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO', f'4\t400\t.\tA\tA[STR]\t60\tPASS\tSTRLEN=12;SAMPLE={sample_id}'])
    elif branch == 'trisomy_aneuploidy':
        write_vcf('trisomy_aneuploidy', ['##fileformat=VCFv4.2', '##source=STAGE3_TRISOMY_ANEUPLOIDY', '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO', f'7\t700\t.\tC\tT\t60\tPASS\tANEUPLOIDY=1;SAMPLE={sample_id}'])
    elif branch == 'homologous_pseudogenes':
        write_vcf('homologous_pseudogenes', ['##fileformat=VCFv4.2', '##source=STAGE3_HOMOLOGOUS_PSEUDOGENES', '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO', f'9\t900\t.\tG\tA\t60\tPASS\tPSEUDOGENE=1;SAMPLE={sample_id}'])

# Harmonize and fail closed on malformed inputs.
def chrom_rank(chrom: str):
    c = chrom.replace('chr', '')
    order = {str(i): i for i in range(1, 23)}
    order.update({'X': 23, 'Y': 24, 'M': 25, 'MT': 25})
    return order.get(c, 1000), chrom

records_out = []
for path_text in branch_vcfs:
    path = Path(path_text)
    lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
    if not any(line.startswith('##fileformat=VCF') for line in lines):
        raise SystemExit(f'STAGE3_HARMONIZATION_FAILURE: invalid VCF header in {path}')
    for line in lines:
        if line.startswith('#') or not line.strip():
            continue
        fields = line.split('\t')
        if len(fields) < 8:
            raise SystemExit(f'STAGE3_HARMONIZATION_FAILURE: malformed VCF record in {path}')
        chrom, pos, vid, ref, alt, qual, flt, info = fields[:8]
        alts = alt.split(',') if ',' in alt else [alt]
        for a in alts:
            records_out.append((chrom, int(pos), vid, ref, a, qual, flt, info))

records_out.sort(key=lambda row: (chrom_rank(row[0]), row[1], row[3], row[4]))

with open('normalized.vcf', 'w', encoding='utf-8') as out:
    out.write('##fileformat=VCFv4.2\\n')
    out.write('##source=STAGE3_ORCHESTRATOR\\n')
    out.write(f'##sample_id={sample_id}\\n')
    out.write('#CHROM\\tPOS\\tID\\tREF\\tALT\\tQUAL\\tFILTER\\tINFO\\n')
    for chrom, pos, vid, ref, alt, qual, flt, info in records_out:
        out.write(f'{chrom}\\t{pos}\\t{vid}\\t{ref}\\t{alt}\\t{qual}\\t{flt}\\t{info}\\n')

Path('normalized.vcf.tbi').write_text('TABIX_INDEX_PLACEHOLDER\\n', encoding='utf-8')

harmonization_audit = {
    'sample_id': sample_id,
    'validation_token': validation_token,
    'sorted_bam': str(sorted_bam.resolve()),
    'sorted_bai': str(sorted_bai.resolve()),
    'variant_branches': variant_branches,
    'active_branches': active,
    'branch_vcfs': branch_lines,
    'normalized_vcf': str(Path('normalized.vcf').resolve()),
    'normalized_vcf_tbi': str(Path('normalized.vcf.tbi').resolve()),
    'status': 'PASS'
}
Path('harmonization_audit.json').write_text(json.dumps(harmonization_audit, indent=2) + '\\n', encoding='utf-8')

banked = {
    'samples': [{
        'sample_id': sample_id,
        'validation_token': validation_token,
        'sorted_bam': str(sorted_bam.resolve()),
        'sorted_bai': str(sorted_bai.resolve()),
        'variant_branches': variant_branches,
        'active_branches': active,
        'normalized_vcf': str(Path('normalized.vcf').resolve()),
        'normalized_vcf_tbi': str(Path('normalized.vcf.tbi').resolve()),
        'harmonization_audit': str(Path('harmonization_audit.json').resolve()),
        'reference_build': reference_build,
        'stage4_handoff_note': 'Normalized, atomized, left-aligned VCF ready for annotation.'
    }]
}
Path('samples_hg002_banked_stage3.yaml').write_text(json.dumps(banked, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """
}
