#!/usr/bin/env bash
set -euo pipefail

# Build a compact HG002 control FASTQ pair by slicing curated loci from a BAM/CRAM source.
# Source precedence: CLI arg -> HG002_SOURCE_BAM env -> public GIAB URL fallback.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT_R1="${SCRIPT_DIR}/hg002_mini_R1.fastq.gz"
OUT_R2="${SCRIPT_DIR}/hg002_mini_R2.fastq.gz"
TMP_DIR="$(mktemp -d "${SCRIPT_DIR}/.tmp_mini_control.XXXXXX")"

DEFAULT_SOURCE_URL="https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/HG002_NA24385_son/NIST_Illumina_2x150bps/bwa-mem-0.7.8-illumina-ref_GRCh38-20161213/HG002.GRCh38.2x150.bam"
SOURCE_INPUT="${1:-${HG002_SOURCE_BAM:-${DEFAULT_SOURCE_URL}}}"
SAMTOOLS_DOCKER_IMAGE="${SAMTOOLS_DOCKER_IMAGE:-wes-onco-core:1.0.0}"
CRAM_REFERENCE="${HG002_CRAM_REFERENCE:-}"

REGIONS=(
  "chr20:10,000,000-11,000,000"
  "chr22:42,120,000-42,150,000"
  "chr1:97,000,000-98,000,000"
  "chr13:32,300,000-32,400,000"
  "chr17:43,000,000-44,000,000"
  "chr4:3,070,000-3,080,000"
)

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

log() {
  printf '[mini-control] %s\n' "$*"
}

use_docker_samtools=false
if ! command -v samtools >/dev/null 2>&1; then
  if command -v docker >/dev/null 2>&1; then
    use_docker_samtools=true
  else
    echo "ERROR: samtools not found and docker is not available." >&2
    exit 1
  fi
fi

run_samtools() {
  if [[ "${use_docker_samtools}" == false ]]; then
    samtools "$@"
    return
  fi

  local -a docker_args
  docker_args=(run --rm -u "$(id -u):$(id -g)" -v "${REPO_ROOT}:${REPO_ROOT}" -w "${REPO_ROOT}")

  if [[ -f "${SOURCE_INPUT}" ]]; then
    local source_abs source_dir
    source_abs="$(realpath "${SOURCE_INPUT}")"
    source_dir="$(dirname "${source_abs}")"
    docker_args+=( -v "${source_dir}:${source_dir}:ro" )
  fi

  if [[ -n "${CRAM_REFERENCE}" ]]; then
    local cram_ref_abs cram_ref_dir
    cram_ref_abs="$(realpath "${CRAM_REFERENCE}")"
    cram_ref_dir="$(dirname "${cram_ref_abs}")"
    docker_args+=( -v "${cram_ref_dir}:${cram_ref_dir}:ro" )
  fi

  docker "${docker_args[@]}" "${SAMTOOLS_DOCKER_IMAGE}" samtools "$@"
}

if [[ -f "${SOURCE_INPUT}" ]]; then
  log "Source BAM/CRAM: ${SOURCE_INPUT}"
else
  log "Source BAM/CRAM URL: ${SOURCE_INPUT}"
fi

if [[ "${SOURCE_INPUT}" == *.cram && -z "${CRAM_REFERENCE}" ]]; then
  log "CRAM input detected. Set HG002_CRAM_REFERENCE=/path/to/reference.fa if decoding requires an explicit reference."
fi

rm -f "${OUT_R1}" "${OUT_R2}"

view_extra_args=()
if [[ "${SOURCE_INPUT}" == *.cram && -n "${CRAM_REFERENCE}" ]]; then
  view_extra_args=( -T "${CRAM_REFERENCE}" )
fi

slice_files=()
for idx in "${!REGIONS[@]}"; do
  region="${REGIONS[$idx]}"
  slice_bam="${TMP_DIR}/slice_$((idx + 1)).bam"
  log "Extracting region ${region}"
  run_samtools view "${view_extra_args[@]}" -b "${SOURCE_INPUT}" "${region}" -o "${slice_bam}"
  slice_files+=("${slice_bam}")
done

merged_bam="${TMP_DIR}/hg002_mini_merged.bam"
log "Merging ${#slice_files[@]} slices"
run_samtools merge -f "${merged_bam}" "${slice_files[@]}"

collated_bam="${TMP_DIR}/hg002_mini_collated.bam"
log "Collating read pairs"
run_samtools collate -u -o "${collated_bam}" "${merged_bam}"

log "Emitting gzipped FASTQ fixtures"
run_samtools fastq -n -1 "${OUT_R1}" -2 "${OUT_R2}" -0 /dev/null -s /dev/null "${collated_bam}"

log "Mini-control dataset ready"
ls -lh "${OUT_R1}" "${OUT_R2}"
