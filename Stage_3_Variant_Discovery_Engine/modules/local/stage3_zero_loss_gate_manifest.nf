process STAGE3_ZERO_LOSS_GATE_MANIFEST {

    label 'process_low'
    container 'genvar-core:2.1.0'

    publishDir "${params.outdir}", mode: 'copy', overwrite: true

    input:
    tuple val(sample_id), val(branch_names), path(branch_vcfs), path(merged_vcf), path(normalized_vcf_gz), path(normalized_vcf_tbi), path(harmonization_audit_json), path(contract_fragment_json)

    output:
    tuple val(sample_id), path("samples_${sample_id}_banked_stage3.yaml"), emit: banked_manifest
    tuple val(sample_id), path("${sample_id}.stage3.zero_loss_audit.json"), emit: zero_loss_audit

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import gzip
import hashlib
import json
from pathlib import Path

NL = chr(10)

sample_id = ${groovy.json.JsonOutput.toJson(sample_id)}
branch_names = ${groovy.json.JsonOutput.toJson(branch_names)}
branch_vcf_paths = [Path(p) for p in ${groovy.json.JsonOutput.toJson(branch_vcfs.collect { p -> p.toString() })}]
merged_vcf = Path('${merged_vcf}')
normalized_vcf_gz = Path('${normalized_vcf_gz}')
normalized_vcf_tbi = Path('${normalized_vcf_tbi}')
harmonization_audit_path = Path('${harmonization_audit_json}')
contract_fragment_path = Path('${contract_fragment_json}')


def count_vcf_rows(path: Path) -> int:
    count = 0
    with path.open('r', encoding='utf-8', errors='replace') as handle:
        for line in handle:
            if line and not line.startswith('#'):
                count += 1
    return count


def count_vcfgz_rows(path: Path) -> int:
    count = 0
    with gzip.open(path, 'rt', encoding='utf-8', errors='replace') as handle:
        for line in handle:
            if line and not line.startswith('#'):
                count += 1
    return count


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def portable_name(text) -> str:
    if not text:
        return ''
    return Path(str(text)).name

branch_counts = {str(path.resolve()): count_vcf_rows(path) for path in branch_vcf_paths}
pre_merge_row_sum = sum(branch_counts.values())
merged_row_count = count_vcf_rows(merged_vcf)
normalized_row_count = count_vcfgz_rows(normalized_vcf_gz)

dropped_pre_merge = pre_merge_row_sum - merged_row_count
if dropped_pre_merge != 0:
    raise SystemExit(
        f"STAGE3_ZERO_LOSS_FAILURE: merged rows mismatch for sample '{sample_id}'; "
        f"pre_merge_sum={pre_merge_row_sum}, merged={merged_row_count}, dropped={dropped_pre_merge}"
    )

dropped_post_norm = merged_row_count - normalized_row_count
if dropped_post_norm != 0:
    raise SystemExit(
        f"STAGE3_ZERO_LOSS_FAILURE: normalized rows mismatch for sample '{sample_id}'; "
        f"merged={merged_row_count}, normalized={normalized_row_count}, dropped={dropped_post_norm}"
    )

harmonization_audit = json.loads(harmonization_audit_path.read_text(encoding='utf-8'))
contract_fragment = json.loads(contract_fragment_path.read_text(encoding='utf-8'))

normalized_vcf_sha256 = sha256(normalized_vcf_gz)
normalized_vcf_tbi_sha256 = sha256(normalized_vcf_tbi)

validation_token = 'VALID_PASS|VARIANTS_HARMONIZED'
contract_fragment['validation_token'] = validation_token
harmonization_audit['validation_token'] = validation_token

zero_loss_audit = {
    'sample_id': sample_id,
    'node': 'STAGE3_ZERO_LOSS_GATE_MANIFEST',
    'status': 'PASS',
    'expected_branches': sorted(branch_names),
    'pre_merge_row_sum': pre_merge_row_sum,
    'merged_row_count': merged_row_count,
    'normalized_row_count': normalized_row_count,
    'dropped_rows_pre_merge': dropped_pre_merge,
    'dropped_rows_post_normalization': dropped_post_norm,
    'branch_row_counts': branch_counts,
    'normalized_vcf_sha256': normalized_vcf_sha256,
    'normalized_vcf_tbi_sha256': normalized_vcf_tbi_sha256,
}
Path(f'{sample_id}.stage3.zero_loss_audit.json').write_text(json.dumps(zero_loss_audit, indent=2) + NL, encoding='utf-8')

harmonization_audit['zero_loss_audit'] = str(Path(f'{sample_id}.stage3.zero_loss_audit.json').resolve())
harmonization_audit_path.write_text(json.dumps(harmonization_audit, indent=2) + NL, encoding='utf-8')

contract_fragment['zero_loss_audit'] = str(Path(f'{sample_id}.stage3.zero_loss_audit.json').resolve())
contract_fragment['row_counts'] = {
    'pre_merge_branch_sum': pre_merge_row_sum,
    'merged': merged_row_count,
    'normalized': normalized_row_count,
    'dropped_rows': 0,
}
contract_fragment['hashes'] = {
    'normalized_vcf_sha256': normalized_vcf_sha256,
    'normalized_vcf_tbi_sha256': normalized_vcf_tbi_sha256,
}
contract_fragment_path.write_text(json.dumps(contract_fragment, indent=2) + NL, encoding='utf-8')

lines = [
    '# ==============================================================================',
    '# STAGE 3 BANKED MANIFEST (IMMUTABLE)',
    '# ==============================================================================',
    'samples:',
    f'  - sample_id: {json.dumps(sample_id)}',
    f'    validation_token: {json.dumps(validation_token)}',
    f'    run_mode: {json.dumps(contract_fragment.get("run_mode", "production"))}',
    f'    stage2_contamination_status: {json.dumps(contract_fragment.get("stage2_contamination_status", ""))}',
    f'    stage2_contamination_policy_action: {json.dumps(contract_fragment.get("stage2_contamination_policy_action", ""))}',
    f'    sorted_bam: {json.dumps(contract_fragment.get("sorted_bam", ""))}',
    f'    sorted_bai: {json.dumps(contract_fragment.get("sorted_bai", ""))}',
]

variant_branches = contract_fragment.get('variant_branches') or {}
if variant_branches:
    lines.append('    variant_branches:')
    for key in sorted(variant_branches.keys()):
        value = 'true' if bool(variant_branches.get(key)) else 'false'
        lines.append(f'      {key}: {value}')
else:
    lines.append('    variant_branches: {}')

active_branches = contract_fragment.get('active_branches') or sorted(branch_names)
if active_branches:
    lines.append('    active_branches:')
    for branch in active_branches:
        lines.append(f'      - {json.dumps(branch)}')
else:
    lines.append('    active_branches: []')

lines.extend([
    f'    normalized_vcf: {json.dumps(portable_name(contract_fragment.get("normalized_vcf", normalized_vcf_gz)))}',
    f'    normalized_vcf_tbi: {json.dumps(portable_name(contract_fragment.get("normalized_vcf_tbi", normalized_vcf_tbi)))}',
    f'    harmonization_audit: {json.dumps(portable_name(contract_fragment.get("harmonization_audit", harmonization_audit_path)))}',
    f'    zero_loss_audit: {json.dumps(portable_name(Path(f"{sample_id}.stage3.zero_loss_audit.json")))}',
    f'    pre_merge_row_sum: {pre_merge_row_sum}',
    f'    merged_row_count: {merged_row_count}',
    f'    normalized_row_count: {normalized_row_count}',
    '    dropped_rows: 0',
    f'    normalized_vcf_sha256: {json.dumps(normalized_vcf_sha256)}',
    f'    normalized_vcf_tbi_sha256: {json.dumps(normalized_vcf_tbi_sha256)}',
])

reference_build = contract_fragment.get('reference_build') or {}
if reference_build:
    lines.append('    reference_build:')
    for key in sorted(reference_build.keys()):
        lines.append(f'      {key}: {json.dumps(reference_build.get(key, ""))}')

lines.append(f'    stage4_handoff_note: {json.dumps(contract_fragment.get("stage4_handoff_note", "Normalized, atomized, schema-validated VCF ready for annotation."))}')

Path(f'samples_{sample_id}_banked_stage3.yaml').write_text(NL.join(lines) + NL, encoding='utf-8')
PYEOF
    """
}
