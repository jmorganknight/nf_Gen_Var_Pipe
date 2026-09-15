#!/usr/bin/env bash
set -euo pipefail

# Whole-pipeline (Stages 0-6) infrastructure profile matrix runner.
# Produces profile-by-profile execution evidence for audit/FMEA updates.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPELINE_MAIN="${ROOT_DIR}/main.nf"

NXF_PROFILE="docker"
INPUT_MANIFEST="${ROOT_DIR}/assets/mini_control/samples_hg002_mini.yaml"
OUT_BASE="${ROOT_DIR}/tests/infrastructure_profile_matrix"
PROFILES=(small medium large)
WITH_RESUME=false
ALLOW_INCOMPLETE=false

usage() {
  cat <<'EOF'
Usage:
  scripts/run_pipeline_infrastructure_profile_matrix.sh [options]

Options:
  --profile <nextflow_profile>      Nextflow profile (default: docker)
  --input <manifest.yaml>           Root pipeline sample manifest (default: assets/mini_control/samples_hg002_mini.yaml)
  --outdir <output_base_dir>        Output base directory (default: tests/infrastructure_profile_matrix)
  --profiles "a b c"                Space-separated profile list (default: "small medium large")
  --resume                          Add -resume to each matrix run
  --allow-incomplete-stages         Run even if downstream stages are known incomplete
  -h, --help                        Show this help

Examples:
  scripts/run_pipeline_infrastructure_profile_matrix.sh

  scripts/run_pipeline_infrastructure_profile_matrix.sh \
    --input assets/mini_control/samples_hg002_mini.yaml \
    --profiles "small medium large"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      NXF_PROFILE="$2"
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
    --resume)
      WITH_RESUME=true
      shift
      ;;
    --allow-incomplete-stages)
      ALLOW_INCOMPLETE=true
      shift
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

if [[ ! -f "${PIPELINE_MAIN}" ]]; then
  echo "ERROR: main.nf not found at ${PIPELINE_MAIN}" >&2
  exit 2
fi

if [[ ! -f "${INPUT_MANIFEST}" ]]; then
  echo "ERROR: input manifest not found: ${INPUT_MANIFEST}" >&2
  exit 2
fi

if [[ "${ALLOW_INCOMPLETE}" != "true" ]]; then
  if grep -q "No such file or directory: Can't find a matching module file for include: ./modules/local/assemble_stage6_banked_manifest.nf" "${ROOT_DIR}/tests/infrastructure_profile_matrix"/*/run.log 2>/dev/null; then
    echo "ERROR: Whole-pipeline matrix is currently blocked by incomplete downstream stage wiring." >&2
    echo "       Run Stage 3-only matrix for current audit evidence, or re-run with --allow-incomplete-stages." >&2
    exit 3
  fi
fi

mkdir -p "${OUT_BASE}"
SUMMARY_TSV="${OUT_BASE}/matrix_summary.tsv"

echo -e "profile\tstatus\tstage6_manifest\tpipeline_infra\tstage3_infra\trun_log" > "${SUMMARY_TSV}"

for exec_profile in "${PROFILES[@]}"; do
  run_dir="${OUT_BASE}/${exec_profile}"
  run_log="${run_dir}/run.log"

  rm -rf "${run_dir}"
  mkdir -p "${run_dir}"

  echo "============================================================"
  echo "[Pipeline Infra Matrix] Running execution_profile=${exec_profile}"
  echo "[Pipeline Infra Matrix] Output directory=${run_dir}"
  echo "============================================================"

  resume_args=()
  if [[ "${WITH_RESUME}" == "true" ]]; then
    resume_args+=("-resume")
  fi

  set +e
  nextflow run "${PIPELINE_MAIN}" \
    -profile "${NXF_PROFILE}" \
    --input "${INPUT_MANIFEST}" \
    --outdir "${run_dir}" \
    --execution_profile "${exec_profile}" \
    "${resume_args[@]}" \
    -ansi-log false \
    2>&1 | tee "${run_log}"
  rc=${PIPESTATUS[0]}
  set -e

  status="RUN_FAILED"
  stage6_manifest="NA"
  pipeline_infra="NA"
  stage3_infra="NA"

  if [[ ${rc} -eq 0 ]]; then
    status="RUN_OK"
  fi

  stage6_manifest="$(find "${run_dir}" -type f -name '*stage6*.yaml' | head -n 1 || true)"
  if [[ -z "${stage6_manifest}" ]]; then
    stage6_manifest="NA"
  fi

  if grep -q "PIPELINE_INFRA:" "${run_log}"; then
    pipeline_infra="$(grep "PIPELINE_INFRA:" "${run_log}" | tail -n 1 | sed 's/\t/ /g')"
  fi

  if grep -q "STAGE3_INFRA:" "${run_log}"; then
    stage3_infra="$(grep "STAGE3_INFRA:" "${run_log}" | tail -n 1 | sed 's/\t/ /g')"
  fi

  echo -e "${exec_profile}\t${status}\t${stage6_manifest}\t${pipeline_infra}\t${stage3_infra}\t${run_log}" >> "${SUMMARY_TSV}"

  echo "[Pipeline Infra Matrix] Result profile=${exec_profile} status=${status}"
  echo "[Pipeline Infra Matrix] PIPELINE_INFRA=${pipeline_infra}"
  echo "[Pipeline Infra Matrix] STAGE3_INFRA=${stage3_infra}"
done

echo
echo "Matrix complete. Summary: ${SUMMARY_TSV}"
cat "${SUMMARY_TSV}"
