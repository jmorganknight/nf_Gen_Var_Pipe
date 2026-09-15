#!/usr/bin/env bash
set -euo pipefail

# Verify Stage 3 production mini-control artifacts are audit-safe and non-stub.
# Audit rule: tests/mini_control must contain only production branch outputs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${ROOT_DIR}/Stage_3_Variant_Discovery_Engine/tests/mini_control"

branches=(snv sv cnv str)

echo "[verify-stage3] base=${BASE_DIR}"

if [[ -d "${BASE_DIR}/smoke" ]]; then
    echo "FAIL: smoke directory is present under production evidence root: ${BASE_DIR}/smoke" >&2
    exit 1
fi

for branch in "${branches[@]}"; do
  branch_dir="${BASE_DIR}/${branch}"
  audit_json="${branch_dir}/hg002_mini.harmonization_audit.json"
  vcf_gz="${branch_dir}/hg002_mini.normalized.vcf.gz"
  tbi="${vcf_gz}.tbi"

  [[ -f "${audit_json}" ]] || { echo "FAIL: missing audit ${audit_json}" >&2; exit 1; }
  [[ -f "${vcf_gz}" ]] || { echo "FAIL: missing VCF ${vcf_gz}" >&2; exit 1; }
  [[ -s "${tbi}" ]] || { echo "FAIL: missing/empty index ${tbi}" >&2; exit 1; }

  gzip -t "${vcf_gz}" || { echo "FAIL: gzip integrity check failed for ${vcf_gz}" >&2; exit 1; }

  python3 - <<'PY' "${branch}" "${audit_json}" "${vcf_gz}"
import gzip
import json
import sys

branch = sys.argv[1]
audit_path = sys.argv[2]
vcf_path = sys.argv[3]

expected_active = {
    'snv': 'snv_indel',
    'sv': 'structural_variants',
    'cnv': 'copy_number_cnv',
    'str': 'str_expansions',
}[branch]

audit = json.load(open(audit_path, encoding='utf-8'))
sv = audit.get('schema_validation', {})
if audit.get('status') != 'PASS':
    raise SystemExit(f"FAIL: {branch} audit status is not PASS")
if sv.get('status') != 'PASS':
    raise SystemExit(f"FAIL: {branch} schema_validation.status is not PASS")

active = audit.get('active_branches') or []
if expected_active not in active:
    raise SystemExit(f"FAIL: {branch} active_branches does not include {expected_active}")

record_count = 0
branch_hits = 0
alt_dot = 0
ref_dot = 0
stub_hit = False

with gzip.open(vcf_path, 'rt', encoding='utf-8', errors='replace') as fh:
    for line in fh:
        if 'STUB' in line or 'stub' in line:
            stub_hit = True
        if line.startswith('#'):
            continue
        cols = line.rstrip('\n').split('\t')
        if len(cols) < 8:
            raise SystemExit(f"FAIL: {branch} has malformed VCF row with <8 columns")
        record_count += 1
        if cols[3] == '.':
            ref_dot += 1
        if cols[4] == '.':
            alt_dot += 1
        if f'BRANCH={expected_active}' in cols[7]:
            branch_hits += 1

if stub_hit:
    raise SystemExit(f"FAIL: {branch} output contains STUB marker")
if ref_dot or alt_dot:
    raise SystemExit(f"FAIL: {branch} contains missing allele values (REF .={ref_dot}, ALT .={alt_dot})")

# For zero-record branches (e.g. SV in this mini-control), branch hit checks are skipped.
if record_count > 0 and branch_hits != record_count:
    raise SystemExit(f"FAIL: {branch} BRANCH tag mismatch ({branch_hits}/{record_count})")

schema_count = sv.get('record_count')
if isinstance(schema_count, int) and schema_count != record_count:
    raise SystemExit(f"FAIL: {branch} schema record_count ({schema_count}) != observed ({record_count})")

print(f"OK: {branch} records={record_count} schema_count={schema_count} branch_hits={branch_hits}")
PY

done

echo "[verify-stage3] PASS: production Stage 3 mini-control artifacts are audit-safe"
