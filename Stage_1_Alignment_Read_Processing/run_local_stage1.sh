#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_ROOT="${WORK_ROOT:-/scratch/nextflow_work}"
TMP_DIR="${TMP_DIR:-/scratch/tmp}"
REF_DIR="${REF_DIR:-/media/jmk/Extreme Pro/pipeline_references}"
INPUT="${1:-../Stage_0_Preflight_Ingest_Gate/tests/inputs/hg002_mini/samples_hg002_banked_stage0.yaml}"
OUTDIR="${2:-tests/banked_stage1}"

echo "Clearing Stage 1 scratch directories: ${WORK_ROOT} and ${TMP_DIR}"
mkdir -p "$WORK_ROOT" "$TMP_DIR"
find "$WORK_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
find "$TMP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

exec nextflow run "$SCRIPT_DIR/main.nf" \
  -profile docker \
  --ref_dir "$REF_DIR" \
  --input "$INPUT" \
  --outdir "$OUTDIR" \
  --max_cpus 30