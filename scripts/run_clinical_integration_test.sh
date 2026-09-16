#!/usr/bin/env bash
set -euo pipefail

# Standard clinical integration test runner for the nf_Gen_Var_Pipe pipeline.
#
# YAML ROUTING: sample_id is extracted from the input manifest and used to
# construct the output directory as `tests/{sample_id}`, ensuring a standard
# clinical integration test directory structure with no performance matrix or
# profiling subdirectories.
#
# OUTPUT DIRECTORY STRUCTURE:
#   tests/{sample_id}/
#     - reports/ (final clinical reports)
#     - stage_outputs/ (intermediate stage outputs)
#     - state/ (Nextflow recovery state, for --resume mode)
#
# The sample_id extraction from YAML is the SINGLE SOURCE OF TRUTH for output
# organization, eliminating manual sample naming and ensuring reproducibility.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPELINE_MAIN="${ROOT_DIR}/main.nf"

NXF_PROFILE="docker"
INPUT_MANIFEST="${ROOT_DIR}/assets/mini_control/samples_mini_control.yaml"
OUT_BASE="${ROOT_DIR}/tests"
WITH_RESUME=false
EXTRA_ARGS=()

# Source YAML routing library
source "${ROOT_DIR}/scripts/lib_yaml_routing.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/run_clinical_integration_test.sh [options]

Options:
  --profile <nextflow_profile>      Nextflow profile (default: docker)
  --input <manifest.yaml>           Sample manifest (default: assets/mini_control/samples_mini_control.yaml)
  --outbase <directory>             Base output directory (default: tests/)
  --resume                          Enable Nextflow resume mode
  --help                            Show this help message

Examples:
  # Run standard mini-control test:
  scripts/run_clinical_integration_test.sh

  # Run with custom input:
  scripts/run_clinical_integration_test.sh --input samples.yaml

  # Run with resume:
  scripts/run_clinical_integration_test.sh --resume

EOF
}

# Parse arguments
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
    --outbase)
      OUT_BASE="$2"
      shift 2
      ;;
    --resume)
      WITH_RESUME=true
      shift
      ;;
    --help)
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

# Validate prerequisites
if [[ ! -f "${PIPELINE_MAIN}" ]]; then
  echo "ERROR: main.nf not found at ${PIPELINE_MAIN}" >&2
  exit 2
fi

if [[ ! -f "${INPUT_MANIFEST}" ]]; then
  echo "ERROR: input manifest not found: ${INPUT_MANIFEST}" >&2
  exit 2
fi

# Extract sample_id from the input YAML manifest (SINGLE SOURCE OF TRUTH)
INPUT_SAMPLE_ID=$(extract_sample_id "${INPUT_MANIFEST}")
echo "[YAML-ROUTING] Extracted sample_id from input manifest: ${INPUT_SAMPLE_ID}"

# Construct clinical integration test output directory
run_dir="${OUT_BASE}/${INPUT_SAMPLE_ID}"
run_log="${run_dir}/clinical_integration_test.log"

mkdir -p "${run_dir}"

echo "============================================================"
echo "[Clinical Integration Test] Sample ID: ${INPUT_SAMPLE_ID}"
echo "[Clinical Integration Test] Input Manifest: ${INPUT_MANIFEST}"
echo "[Clinical Integration Test] Output Directory: ${run_dir}"
echo "[Clinical Integration Test] Nextflow Profile: ${NXF_PROFILE}"
echo "============================================================"

# Build Nextflow command
resume_args=()
if [[ "${WITH_RESUME}" == "true" ]]; then
  resume_args+=("-resume")
fi

# Run the pipeline
set +e
nextflow run "${PIPELINE_MAIN}" \
  -profile "${NXF_PROFILE}" \
  --input "${INPUT_MANIFEST}" \
  --outdir "${run_dir}" \
  "${resume_args[@]}" \
  -ansi-log false \
  2>&1 | tee "${run_log}"
rc=${PIPESTATUS[0]}
set -e

# Report results
if [[ ${rc} -eq 0 ]]; then
  status="✓ PASS"
else
  status="✗ FAIL (rc=${rc})"
fi

echo ""
echo "============================================================"
echo "[Clinical Integration Test Complete] Status: ${status}"
echo "[Clinical Integration Test Complete] Sample: ${INPUT_SAMPLE_ID}"
echo "[Clinical Integration Test Complete] Output: ${run_dir}/"
echo "[Clinical Integration Test Complete] Log: ${run_log}"
echo "============================================================"

exit ${rc}
