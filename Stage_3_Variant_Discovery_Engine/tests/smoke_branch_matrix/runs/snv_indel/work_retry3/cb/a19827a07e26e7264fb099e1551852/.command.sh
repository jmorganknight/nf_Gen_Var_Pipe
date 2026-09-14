#!/bin/bash -ue
set -euo pipefail

    python3 - <<'PYEOF'
import hashlib
import json
from pathlib import Path

refs = json.loads('{"reference_genome":"/media/jmk/Extreme Pro/pipeline_references/reference/GRCh38_full_analysis_set_plus_decoy_hla.fa","capture_wes_bed":"/media/jmk/Extreme Pro/pipeline_references/beds/OncoPanel_v4.2_Master_hs38DH.bed","onco_target_bed":"/media/jmk/Extreme Pro/pipeline_references/beds/OncoPanel_v4.2_Master_hs38DH.bed","mane_transcripts":"/media/jmk/Extreme Pro/pipeline_references/beds/mane_select_v1.3.bed","stage3_vcf_schema":"/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_3_Variant_Discovery_Engine/tests/schemas/v4.2_Production_Schema.json","cnvkit_pooled_reference":"/media/jmk/Extreme Pro/pipeline_references/models/flat_reference_grch38.cnn","expansionhunter_catalog":"/media/jmk/Extreme Pro/pipeline_references/beds/variant_catalog_grch38.json","pseudogene_mask":null}')
meta = json.loads('{"sample_id":"hg002_mini","sample_type":"germline","sequencing_type":"WES","run_mode":"audit_only","validation_token":"VALID_PASS|SAMPLE_VALIDATED","stage2_contamination_status":"FAIL","stage2_contamination_policy_action":"CONTINUE_FOR_AUDIT","stage3_discovery_thresholds":{"somatic_qual_floor":20,"germline_qual_floor":10,"manta_min_rescue_score":20,"large_indel_min_size_bp":50,"cnv_log2_abs_floor":0.2,"trisomy_ratio_threshold":1.35,"trisomy_z_threshold":3.0},"sorted_bam":"/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_1_Alignment_Read_Processing/tests/mini_control/hg002_mini/audit_and_qc/identity/hg002_mini.identity_verified.bam","sorted_bai":"/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_1_Alignment_Read_Processing/tests/mini_control/hg002_mini/audit_and_qc/identity/hg002_mini.identity_verified.bam.bai","variant_branches":{"snv_indel":true,"structural_variants":false,"copy_number_cnv":false,"str_expansions":false,"trisomy_aneuploidy":false,"homologous_pseudogenes":false},"reference_build":{"reference_genome":"/media/jmk/Extreme Pro/pipeline_references/reference/GRCh38_full_analysis_set_plus_decoy_hla.fa","reference_fai":"/media/jmk/Extreme Pro/pipeline_references/reference/GRCh38_full_analysis_set_plus_decoy_hla.fa.fai","reference_dict":"/media/jmk/Extreme Pro/pipeline_references/reference/GRCh38_full_analysis_set_plus_decoy_hla.dict","capture_wes_bed":"/media/jmk/Extreme Pro/pipeline_references/beds/OncoPanel_v4.2_Master_hs38DH.bed","onco_target_bed":"/media/jmk/Extreme Pro/pipeline_references/beds/OncoPanel_v4.2_Master_hs38DH.bed","sf_bed":"/media/jmk/Extreme Pro/pipeline_references/beds/ACMG_SF_v3.2_hs38DH.bed","clinvar_db":"/media/jmk/Extreme Pro/pipeline_references/clinvar/clinvar_20260601.vcf.gz"},"stage3_faults":{}}')
declared_schema_path = refs.get('stage3_vcf_schema')
if not declared_schema_path:
    raise SystemExit('STAGE3_SCHEMA_VALIDATION_FAILURE: missing params.refs.stage3_vcf_schema')

schema_file = Path('v4.2_Production_Schema.json')
if not schema_file.exists():
    raise SystemExit(f'STAGE3_SCHEMA_VALIDATION_FAILURE: schema file missing: {schema_file}')

schema = json.loads(schema_file.read_text(encoding='utf-8'))
vcf_path = Path('snv_indel.mane_selected.vcf')

required_header_prefix = schema.get('required_header_prefix') or '##fileformat=VCFv4.2'
required_columns = schema.get('required_columns') or ['#CHROM', 'POS', 'ID', 'REF', 'ALT', 'QUAL', 'FILTER', 'INFO']

lines = vcf_path.read_text(encoding='utf-8', errors='replace').splitlines()
if not lines:
    raise SystemExit('STAGE3_SCHEMA_VALIDATION_FAILURE: VCF payload is empty')

if not any(line.startswith(required_header_prefix) for line in lines if line.startswith('##')):
    raise SystemExit('STAGE3_SCHEMA_VALIDATION_FAILURE: missing required VCF fileformat header')

header_line = None
for line in lines:
    if line.startswith('#CHROM'):
        header_line = line
        break
if header_line is None:
    raise SystemExit('STAGE3_SCHEMA_VALIDATION_FAILURE: missing #CHROM header line')

header_cols = header_line.split('	')
for idx, col in enumerate(required_columns):
    if idx >= len(header_cols) or header_cols[idx] != col:
        raise SystemExit(f'STAGE3_SCHEMA_VALIDATION_FAILURE: VCF header column mismatch at position {idx + 1}; expected {col}')

violations = []
record_count = 0
for line in lines:
    if not line or line.startswith('#'):
        continue
    cols = line.split('	')
    record_count += 1
    if len(cols) < 8:
        violations.append('record has fewer than 8 mandatory VCF columns')
        continue
    chrom, pos, _vid, ref, alt = cols[0], cols[1], cols[2], cols[3], cols[4]
    try:
        pos_int = int(pos)
        if pos_int < 1:
            violations.append(f'invalid POS value {pos} for {chrom}')
    except ValueError:
        violations.append(f'non-integer POS value {pos} for {chrom}')
    if not ref or ref == '.':
        violations.append(f'missing REF allele for {chrom}:{pos}')
    if not alt or alt == '.':
        violations.append(f'missing ALT allele for {chrom}:{pos}')

if violations:
    uniq = sorted(set(violations))
    raise SystemExit('STAGE3_SCHEMA_VALIDATION_FAILURE: ' + '; '.join(uniq[:10]))

normalized_vcf = Path('hg002_mini.normalized.vcf')
normalized_vcf.write_text(chr(10).join(lines) + chr(10), encoding='utf-8')
normalized_vcf_gz = Path('hg002_mini.normalized.vcf.gz')
normalized_vcf_tbi = Path('hg002_mini.normalized.vcf.gz.tbi')

import subprocess
with normalized_vcf.open('rb') as src, normalized_vcf_gz.open('wb') as dst:
    proc = subprocess.run(['bgzip', '-c'], stdin=src, stdout=dst, stderr=subprocess.PIPE, text=False)
if proc.returncode != 0:
    stderr_text = proc.stderr.decode('utf-8', errors='replace') if proc.stderr else ''
    raise SystemExit(f'STAGE3_HARMONIZATION_FAILURE: bgzip failed: {stderr_text.strip()}')
subprocess.run(['tabix', '-f', '-p', 'vcf', str(normalized_vcf_gz)], check=True)
normalized_vcf.unlink()

published_dir = Path('/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_3_Variant_Discovery_Engine/tests/smoke_branch_matrix/runs/snv_indel/out_retry3')
published_vcf = published_dir / 'hg002_mini.normalized.vcf.gz'
published_tbi = published_dir / 'hg002_mini.normalized.vcf.gz.tbi'

def sha256(path: Path):
    h = hashlib.sha256()
    with path.open('rb') as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

schema_validation_audit = {
    'sample_id': 'hg002_mini',
    'node': 'MASTER_HARMONIZED_VCF_PAYLOAD',
    'schema_path': str(schema_file.resolve()),
    'schema_path_declared': str(declared_schema_path),
    'schema_sha256': sha256(schema_file),
    'validated_vcf': str(vcf_path.resolve()),
    'normalized_vcf': str(normalized_vcf_gz.resolve()),
    'normalized_vcf_tbi': str(normalized_vcf_tbi.resolve()),
    'published_normalized_vcf': str(published_vcf),
    'published_normalized_vcf_tbi': str(published_tbi),
    'normalized_vcf_sha256': sha256(normalized_vcf_gz),
    'normalized_vcf_tbi_sha256': sha256(normalized_vcf_tbi),
    'record_count': record_count,
    'ga4gh_vcf_version': '4.2',
    'status': 'PASS',
}

harmonization_audit = {
    'sample_id': 'hg002_mini',
    'validation_token': meta.get('validation_token', ''),
    'sorted_bam': meta.get('sorted_bam', ''),
    'sorted_bai': meta.get('sorted_bai', ''),
    'variant_branches': meta.get('variant_branches', {}),
    'active_branches': [k for k, v in (meta.get('variant_branches', {}) or {}).items() if bool(v)],
    'normalized_vcf': str(published_vcf),
    'normalized_vcf_tbi': str(published_tbi),
    'workdir_normalized_vcf': str(normalized_vcf_gz.resolve()),
    'workdir_normalized_vcf_tbi': str(normalized_vcf_tbi.resolve()),
    'mane_selector_audit': str(Path('stage3.mane_transcript_selector.audit.json').resolve()),
    'dynamic_calibration_audit': str(Path('stage3.deepvariant_calibration.json').resolve()),
    'schema_validation': schema_validation_audit,
    'status': 'PASS',
}

Path('hg002_mini.harmonization_audit.json').write_text(json.dumps(harmonization_audit, indent=2) + chr(10), encoding='utf-8')

fragment = {
    'sample_id': 'hg002_mini',
    'validation_token': meta.get('validation_token', ''),
    'run_mode': meta.get('run_mode', 'production'),
    'sorted_bam': meta.get('sorted_bam', ''),
    'sorted_bai': meta.get('sorted_bai', ''),
    'stage2_contamination_status': meta.get('stage2_contamination_status', ''),
    'stage2_contamination_policy_action': meta.get('stage2_contamination_policy_action', ''),
    'variant_branches': meta.get('variant_branches', {}),
    'active_branches': [k for k, v in (meta.get('variant_branches', {}) or {}).items() if bool(v)],
    'normalized_vcf': str(published_vcf),
    'normalized_vcf_tbi': str(published_tbi),
    'harmonization_audit': str(published_dir / 'hg002_mini.harmonization_audit.json'),
    'reference_build': meta.get('reference_build', {}),
    'stage4_handoff_note': 'Normalized, atomized, schema-validated VCF ready for annotation.',
}
Path('hg002_mini.stage3.contract.fragment.json').write_text(json.dumps(fragment, indent=2) + chr(10), encoding='utf-8')
PYEOF
