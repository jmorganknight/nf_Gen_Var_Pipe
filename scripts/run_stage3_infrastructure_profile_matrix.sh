#!/usr/bin/env bash
set -euo pipefail

# Run Stage 3 across infrastructure profiles (small/medium/large) and capture
# reproducible evidence artifacts for performance/FMEA comparison.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE3_MAIN="${ROOT_DIR}/Stage_3_Variant_Discovery_Engine/main.nf"

PROFILE="docker"
INPUT_MANIFEST="${ROOT_DIR}/Stage_2_PostAlign_Sample_Validation_Gate/tests/mini_control/samples_hg002_banked_stage2.yaml"
OUT_BASE="${ROOT_DIR}/Stage_3_Variant_Discovery_Engine/tests/infrastructure_profile_matrix"
PROFILES=(small medium large)

usage() {
  cat <<'EOF'
Usage:
  scripts/run_stage3_infrastructure_profile_matrix.sh [options]

Options:
  --profile <nextflow_profile>      Nextflow execution profile (default: docker)
  --input <stage2_manifest.yaml>    Stage 2 banked manifest (default: mini_control all-branches)
  --outdir <output_base_dir>        Output base directory for matrix runs
  --profiles "a b c"                Space-separated profile list (default: "small medium large")

Examples:
  scripts/run_stage3_infrastructure_profile_matrix.sh
  scripts/run_stage3_infrastructure_profile_matrix.sh \
    --input Stage_2_PostAlign_Sample_Validation_Gate/tests/mini_control/samples_hg002_banked_stage2_snv_only.yaml \
    --profiles "small medium large"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --input)
      INPUT_MANIFEST="$2"
      shift 2
      ;;
    --outdir)
      OUT_BASE="$2"
      shift 2
      ;;
    --profiles)
      IFS=' ' read -r -a PROFILES <<< "$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option '$1'" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ! -f "${STAGE3_MAIN}" ]]; then
  echo "ERROR: Stage 3 main.nf not found at ${STAGE3_MAIN}" >&2
  exit 2
fi

if [[ ! -f "${INPUT_MANIFEST}" ]]; then
  echo "ERROR: input manifest not found: ${INPUT_MANIFEST}" >&2
  exit 2
fi

mkdir -p "${OUT_BASE}"
SUMMARY_TSV="${OUT_BASE}/matrix_summary.tsv"

echo -e "profile\tstatus\trecord_count\taudit_path\trun_log" > "${SUMMARY_TSV}"

for infra_profile in "${PROFILES[@]}"; do
  run_dir="${OUT_BASE}/${infra_profile}"
  run_log="${run_dir}/run.log"

  rm -rf "${run_dir}"
  mkdir -p "${run_dir}"

  echo "============================================================"
  echo "[Stage3 Infra Matrix] Running profile: ${infra_profile}"
  echo "[Stage3 Infra Matrix] Output dir: ${run_dir}"
  echo "============================================================"

  set +e
  nextflow run "${STAGE3_MAIN}" \
    -profile "${PROFILE}" \
    --input "${INPUT_MANIFEST}" \
    --outdir "${run_dir}" \
    --infrastructure_profile "${infra_profile}" \
    -ansi-log false \
    2>&1 | tee "${run_log}"
  rc=${PIPESTATUS[0]}
  set -e

  audit_file="$(find "${run_dir}" -maxdepth 1 -name '*.harmonization_audit.json' | head -n 1 || true)"
  status="RUN_FAILED"
  record_count="NA"

  if [[ ${rc} -eq 0 && -n "${audit_file}" ]]; then
    status="$(python3 - <<PY
import json
from pathlib import Path
p = Path(${audit_file@Q})
obj = json.loads(p.read_text(encoding='utf-8'))
print(obj.get('schema_validation', {}).get('status', obj.get('status', 'UNKNOWN')))
PY
)"
    record_count="$(python3 - <<PY
import json
from pathlib import Path
p = Path(${audit_file@Q})
obj = json.loads(p.read_text(encoding='utf-8'))
print(obj.get('schema_validation', {}).get('record_count', 'NA'))
PY
)"
  fi

  echo -e "${infra_profile}\t${status}\t${record_count}\t${audit_file:-NA}\t${run_log}" >> "${SUMMARY_TSV}"

  echo "[Stage3 Infra Matrix] Result: profile=${infra_profile} status=${status} record_count=${record_count}"
  if grep -q "STAGE3_INFRA:" "${run_log}"; then
    grep "STAGE3_INFRA:" "${run_log}" | tail -n 1
  fi
done

echo

echo "Matrix complete. Summary: ${SUMMARY_TSV}"
cat "${SUMMARY_TSV}"
