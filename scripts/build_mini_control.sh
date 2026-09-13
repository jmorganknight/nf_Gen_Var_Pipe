#!/usr/bin/env bash
set -euo pipefail

# Build a fast multi-chromosomal HG002 fixture for Stage 2-5 smoke tests.
# Regions intentionally include:
# - chr21 (fast SNV/Indel and VCF normalization checks)
# - chr17 (TP53/BRCA1 dense oncology loci)
# - chrX/chrY (sex concordance and PAR boundary behavior)
# - chr1/chr10/chr22 (PGx-relevant loci including DPYD/CYP2C19/CYP2D6 neighborhoods)

usage() {
  cat <<'EOF'
Usage:
  scripts/build_mini_control.sh \
    --input-bam <HG002.bam|HG002.cram> \
    --input-vcf <HG002.vcf|HG002.vcf.gz|HG002.bcf> \
    [--reference-fasta <GRCh38.fa>] \
    [--output-prefix assets/hg002_mini]

Outputs:
  <output-prefix>.bam
  <output-prefix>.bam.bai
  <output-prefix>.vcf.gz
  <output-prefix>.vcf.gz.tbi

Notes:
  - --reference-fasta is required when --input-bam is CRAM.
  - Requires samtools, bcftools, and tabix in PATH.
EOF
}

require_bin() {
  local b="$1"
  if ! command -v "$b" >/dev/null 2>&1; then
    echo "ERROR: required binary not found: $b" >&2
    exit 1
  fi
}

INPUT_BAM=""
INPUT_VCF=""
REFERENCE_FASTA=""
OUTPUT_PREFIX="assets/hg002_mini"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input-bam)
      INPUT_BAM="$2"
      shift 2
      ;;
    --input-vcf)
      INPUT_VCF="$2"
      shift 2
      ;;
    --reference-fasta)
      REFERENCE_FASTA="$2"
      shift 2
      ;;
    --output-prefix)
      OUTPUT_PREFIX="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$INPUT_BAM" || -z "$INPUT_VCF" ]]; then
  echo "ERROR: --input-bam and --input-vcf are required" >&2
  usage
  exit 1
fi

require_bin samtools
require_bin bcftools
require_bin tabix

if [[ ! -f "$INPUT_BAM" ]]; then
  echo "ERROR: input BAM/CRAM not found: $INPUT_BAM" >&2
  exit 1
fi
if [[ ! -f "$INPUT_VCF" ]]; then
  echo "ERROR: input VCF/BCF not found: $INPUT_VCF" >&2
  exit 1
fi

BAM_EXT="${INPUT_BAM##*.}"
BAM_EXT_LOWER="$(echo "$BAM_EXT" | tr '[:upper:]' '[:lower:]')"
if [[ "$BAM_EXT_LOWER" == "cram" && -z "$REFERENCE_FASTA" ]]; then
  echo "ERROR: --reference-fasta is required for CRAM input" >&2
  exit 1
fi
if [[ -n "$REFERENCE_FASTA" && ! -f "$REFERENCE_FASTA" ]]; then
  echo "ERROR: reference FASTA not found: $REFERENCE_FASTA" >&2
  exit 1
fi

OUT_DIR="$(dirname "$OUTPUT_PREFIX")"
mkdir -p "$OUT_DIR"

OUT_BAM="${OUTPUT_PREFIX}.bam"
OUT_BAI="${OUT_BAM}.bai"
OUT_VCF_GZ="${OUTPUT_PREFIX}.vcf.gz"
OUT_TBI="${OUT_VCF_GZ}.tbi"

REGIONS=(chr21 chr17 chrX chrY chr1 chr10 chr22)
REGION_CSV="$(IFS=,; echo "${REGIONS[*]}")"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

TMP_BAM="${TMP_DIR}/hg002_mini.unsorted.bam"

echo "[mini] slicing BAM/CRAM: $INPUT_BAM"
if [[ "$BAM_EXT_LOWER" == "cram" ]]; then
  samtools view -bh -T "$REFERENCE_FASTA" "$INPUT_BAM" "${REGIONS[@]}" > "$TMP_BAM"
else
  samtools view -bh "$INPUT_BAM" "${REGIONS[@]}" > "$TMP_BAM"
fi

samtools sort -o "$OUT_BAM" "$TMP_BAM"
samtools index -f "$OUT_BAM"

echo "[mini] slicing VCF/BCF: $INPUT_VCF"
bcftools view -r "$REGION_CSV" -Oz -o "$OUT_VCF_GZ" "$INPUT_VCF"
tabix -f -p vcf "$OUT_VCF_GZ"

echo "[mini] done"
echo "[mini] bam: $OUT_BAM"
echo "[mini] bai: $OUT_BAI"
echo "[mini] vcf: $OUT_VCF_GZ"
echo "[mini] tbi: $OUT_TBI"
