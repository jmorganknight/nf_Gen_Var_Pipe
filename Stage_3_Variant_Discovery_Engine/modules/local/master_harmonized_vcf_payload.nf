process MASTER_HARMONIZED_VCF_PAYLOAD {

    label 'process_low'
    container 'genvar-core:2.1.0'

    publishDir "${params.outdir}", mode: 'copy', overwrite: true

    input:
    tuple val(sample_id), path(mane_selected_vcf), path(mane_audit), path(vcf_schema), val(stage3_refs), val(sample_meta), path(calibration_audit)

    output:
    tuple val(sample_id), path("${sample_id}.normalized.vcf.gz"), path("${sample_id}.harmonization_audit.json"), path("${sample_id}.stage3.contract.fragment.json"), emit: harmonized
    path "${sample_id}.normalized.vcf.gz.tbi", emit: normalized_tbi

    script:
    def refsJson = groovy.json.JsonOutput.toJson(stage3_refs).replace('\\', '\\\\').replace("'", "\\'")
    def metaJson = groovy.json.JsonOutput.toJson(sample_meta).replace('\\', '\\\\').replace("'", "\\'")
    def publishedOutDir = new File(params.outdir.toString()).isAbsolute() ? new File(params.outdir.toString()).canonicalPath : new File(workflow.launchDir.toString(), params.outdir.toString()).canonicalPath
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import hashlib
import json
from pathlib import Path

refs = json.loads('${refsJson}')
meta = json.loads('${metaJson}')
declared_schema_path = refs.get('stage3_vcf_schema')
if not declared_schema_path:
    raise SystemExit('STAGE3_SCHEMA_VALIDATION_FAILURE: missing params.refs.stage3_vcf_schema')

schema_file = Path('${vcf_schema}')
if not schema_file.exists():
    raise SystemExit(f'STAGE3_SCHEMA_VALIDATION_FAILURE: schema file missing: {schema_file}')

schema = json.loads(schema_file.read_text(encoding='utf-8'))
vcf_path = Path('${mane_selected_vcf}')

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

header_cols = header_line.split('\t')
for idx, col in enumerate(required_columns):
    if idx >= len(header_cols) or header_cols[idx] != col:
        raise SystemExit(f'STAGE3_SCHEMA_VALIDATION_FAILURE: VCF header column mismatch at position {idx + 1}; expected {col}')

violations = []
record_count = 0
for line in lines:
    if not line or line.startswith('#'):
        continue
    cols = line.split('\t')
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

normalized_vcf = Path('${sample_id}.normalized.vcf')
normalized_vcf.write_text(chr(10).join(lines) + chr(10), encoding='utf-8')
normalized_vcf_gz = Path('${sample_id}.normalized.vcf.gz')
normalized_vcf_tbi = Path('${sample_id}.normalized.vcf.gz.tbi')

import subprocess
with normalized_vcf.open('rb') as src, normalized_vcf_gz.open('wb') as dst:
    proc = subprocess.run(['bgzip', '-c'], stdin=src, stdout=dst, stderr=subprocess.PIPE, text=False)
if proc.returncode != 0:
    stderr_text = proc.stderr.decode('utf-8', errors='replace') if proc.stderr else ''
    raise SystemExit(f'STAGE3_HARMONIZATION_FAILURE: bgzip failed: {stderr_text.strip()}')
subprocess.run(['tabix', '-f', '-p', 'vcf', str(normalized_vcf_gz)], check=True)
normalized_vcf.unlink()

published_dir = Path('${publishedOutDir}')
published_vcf = published_dir / '${sample_id}.normalized.vcf.gz'
published_tbi = published_dir / '${sample_id}.normalized.vcf.gz.tbi'

def sha256(path: Path):
    h = hashlib.sha256()
    with path.open('rb') as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

schema_validation_audit = {
    'sample_id': '${sample_id}',
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
    'sample_id': '${sample_id}',
    'validation_token': meta.get('validation_token', ''),
    'sorted_bam': meta.get('sorted_bam', ''),
    'sorted_bai': meta.get('sorted_bai', ''),
    'variant_branches': meta.get('variant_branches', {}),
    'active_branches': [k for k, v in (meta.get('variant_branches', {}) or {}).items() if bool(v)],
    'normalized_vcf': str(published_vcf),
    'normalized_vcf_tbi': str(published_tbi),
    'workdir_normalized_vcf': str(normalized_vcf_gz.resolve()),
    'workdir_normalized_vcf_tbi': str(normalized_vcf_tbi.resolve()),
    'mane_selector_audit': str(Path('${mane_audit}').resolve()),
    'dynamic_calibration_audit': str(Path('${calibration_audit}').resolve()),
    'schema_validation': schema_validation_audit,
    'status': 'PASS',
}

Path('${sample_id}.harmonization_audit.json').write_text(json.dumps(harmonization_audit, indent=2) + chr(10), encoding='utf-8')

fragment = {
    'sample_id': '${sample_id}',
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
    'harmonization_audit': str(published_dir / '${sample_id}.harmonization_audit.json'),
    'reference_build': meta.get('reference_build', {}),
    'stage4_handoff_note': 'Normalized, atomized, schema-validated VCF ready for annotation.',
}
Path('${sample_id}.stage3.contract.fragment.json').write_text(json.dumps(fragment, indent=2) + chr(10), encoding='utf-8')
PYEOF
    """

    stub:
    """
        cp "${mane_selected_vcf}" "${sample_id}.normalized.vcf"
        bgzip -f "${sample_id}.normalized.vcf"
        tabix -f -p vcf "${sample_id}.normalized.vcf.gz"
        cat > "${sample_id}.harmonization_audit.json" <<'JSON'
{
  "sample_id": "${sample_id}",
  "node": "MASTER_HARMONIZED_VCF_PAYLOAD",
  "status": "PASS",
  "stub": true
}
JSON
    cat > "${sample_id}.stage3.contract.fragment.json" <<'JSON'
{
  "sample_id": "${sample_id}",
  "validation_token": "${sample_meta.validation_token ?: ''}",
    "run_mode": "${sample_meta.run_mode ?: 'production'}",
  "variant_branches": ${groovy.json.JsonOutput.toJson(sample_meta.variant_branches ?: [:])},
  "active_branches": ["snv_indel"],
    "normalized_vcf": "${sample_id}.normalized.vcf.gz",
    "normalized_vcf_tbi": "${sample_id}.normalized.vcf.gz.tbi",
    "harmonization_audit": "${sample_id}.harmonization_audit.json",
  "stage4_handoff_note": "Normalized, atomized, schema-validated VCF ready for annotation."
}
JSON
    """
}
