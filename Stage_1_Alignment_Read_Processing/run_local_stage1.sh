#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_ROOT="${WORK_ROOT:-/scratch/nextflow_work}"
TMP_DIR="${TMP_DIR:-/scratch/tmp}"
REF_DIR="${REF_DIR:-/media/jmk/Extreme Pro/pipeline_references}"
INPUT="${1:-../Stage_0_Preflight_Ingest_Gate/tests/inputs/hg002_mini/samples_hg002_banked_stage0.yaml}"

# Source YAML routing library for sample_id extraction
source "$PROJECT_ROOT/scripts/lib_yaml_routing.sh"

# Resolve INPUT to absolute path for YAML parsing
INPUT_ABS="$(cd "$(dirname "$INPUT")" && pwd -P)/$(basename "$INPUT")"

# Extract sample_id from the input YAML manifest
SAMPLE_ID=$(extract_sample_id "$INPUT_ABS")
echo "[YAML-ROUTING] Extracted sample_id from YAML: $SAMPLE_ID"

# Compute dynamic outdir based on extracted sample_id
# OUTDIR is now: tests/outputs/${SAMPLE_ID}
# This ensures the outdir is ALWAYS derived from the YAML, never from CLI defaults
OUTDIR=$(compute_outdir_path "tests" "$SAMPLE_ID")
echo "[YAML-ROUTING] Computed output directory: $OUTDIR"

echo "Clearing Stage 1 scratch directories: ${WORK_ROOT} and ${TMP_DIR}"
mkdir -p "$WORK_ROOT" "$TMP_DIR"
find "$WORK_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
find "$TMP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

echo "[INVOKE] Running Nextflow Stage 1 with YAML-derived routing:"
echo "  Input YAML: $INPUT_ABS"
echo "  Sample ID: $SAMPLE_ID"
echo "  Output Dir: $OUTDIR"

exec nextflow run "$SCRIPT_DIR/main.nf" \
  -profile docker \
  --ref_dir "$REF_DIR" \
  --input "$INPUT_ABS" \
  --outdir "$OUTDIR" \
  --max_cpus 30