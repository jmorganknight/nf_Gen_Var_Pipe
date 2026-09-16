#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  containers/build_containers.sh [options]

Options:
  --tag <tag>                 Image tag to build. Default: 2.1.0
  --targets <list>            Comma-separated targets: core,annotation,reporting. Default: core,annotation,reporting
  --references <path>         References manifest. Default: ../control_plane/references.yaml
  --elprep-bin <path>         Optional override for target core. If unset, the script downloads elPrep from the official release URL.
  --elprep-url <url>          Override the elPrep download URL.
  --elprep-sha256 <sha256>    Override the expected SHA-256 for the downloaded elPrep tarball.
  --pharmcat-jar <path>       Optional override for target annotation. Defaults to references.yaml container_assets.pharmcat_jar.
  --build-sif                 Also build SIF artifacts in containers/ using singularity/apptainer.
  --no-cache                  Pass --no-cache to docker build.
  -h, --help                  Show this help.

Examples:
  containers/build_containers.sh \
    --references control_plane/references.yaml \
    --build-sif

  containers/build_containers.sh --targets reporting --build-sif
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="2.1.0"
TARGETS="core,annotation,reporting"
REFERENCES_FILE="${SCRIPT_DIR}/../control_plane/references.yaml"
ELPREP_BIN=""
ELPREP_URL="https://github.com/ExaScience/elprep/releases/download/v5.1.2/elprep-v5.1.2.tar.gz"
ELPREP_SHA256="cd9b3d9dfaeab253716191275c70362038ca5efbfacf8ffe33ddfc94f597a5a4"
PHARMCAT_JAR=""
BUILD_SIF=0
NO_CACHE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="$2"
      shift 2
      ;;
    --targets)
      TARGETS="$2"
      shift 2
      ;;
    --references)
      REFERENCES_FILE="$2"
      shift 2
      ;;
    --elprep-bin)
      ELPREP_BIN="$2"
      shift 2
      ;;
    --elprep-url)
      ELPREP_URL="$2"
      shift 2
      ;;
    --elprep-sha256)
      ELPREP_SHA256="$2"
      shift 2
      ;;
    --pharmcat-jar)
      PHARMCAT_JAR="$2"
      shift 2
      ;;
    --build-sif)
      BUILD_SIF=1
      shift
      ;;
    --no-cache)
      NO_CACHE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$REFERENCES_FILE" ]]; then
  echo "ERROR: references manifest not found: $REFERENCES_FILE" >&2
  exit 1
fi

resolve_from_references() {
  local key_path="$1"
  python3 - "$REFERENCES_FILE" "$key_path" <<'PY'
import sys
from pathlib import Path

refs_path = Path(sys.argv[1])
key_path = sys.argv[2].split('.')

def parse_scalar(value):
    value = value.strip()
    if value.startswith(('"', "'")) and value.endswith(('"', "'")):
        return value[1:-1]
    if value in ('{}', '[]'):
        return value
    return value

root = {}
stack = [(-1, root)]
for raw in refs_path.read_text(encoding='utf-8').splitlines():
    if not raw.strip() or raw.lstrip().startswith('#'):
        continue
    indent = len(raw) - len(raw.lstrip(' '))
    stripped = raw.strip()
    if ':' not in stripped:
        continue
    key, value = stripped.split(':', 1)
    value = value.strip()
    while len(stack) > 1 and indent <= stack[-1][0]:
        stack.pop()
    current = stack[-1][1]
    if not value:
        current[key] = {}
        stack.append((indent, current[key]))
    else:
        current[key] = parse_scalar(value)

cursor = root
for key in key_path:
    if not isinstance(cursor, dict) or key not in cursor:
        print('')
        sys.exit(0)
    cursor = cursor[key]

if isinstance(cursor, dict):
    print('')
else:
    print(str(cursor))
PY
}

resolve_asset_path() {
  local raw_path="$1"
  local ref_root="$2"
  if [[ -z "$raw_path" ]]; then
    return 0
  fi
  if [[ "$raw_path" = /* ]]; then
    printf '%s\n' "$raw_path"
  else
    printf '%s\n' "${ref_root%/}/$raw_path"
  fi
}

REF_DATA_ROOT="$(resolve_from_references ref_data_root)"

if [[ -z "$PHARMCAT_JAR" ]]; then
  PHARMCAT_JAR_RAW="$(resolve_from_references container_assets.pharmcat_jar)"
  if [[ -z "$PHARMCAT_JAR_RAW" ]]; then
    PHARMCAT_JAR_RAW="$(resolve_from_references pharmcat_jar)"
  fi
  PHARMCAT_JAR="$(resolve_asset_path "$PHARMCAT_JAR_RAW" "$REF_DATA_ROOT")"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is required" >&2
  exit 1
fi

SIF_TOOL=""
if [[ "$BUILD_SIF" -eq 1 ]]; then
  if command -v apptainer >/dev/null 2>&1; then
    SIF_TOOL="apptainer"
  elif command -v singularity >/dev/null 2>&1; then
    SIF_TOOL="singularity"
  else
    echo "ERROR: --build-sif requested but neither apptainer nor singularity is installed" >&2
    exit 1
  fi
fi

IFS=',' read -r -a TARGET_ARRAY <<< "$TARGETS"
want_target() {
  local needle="$1"
  local item
  for item in "${TARGET_ARRAY[@]}"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

if want_target core; then
  if [[ -z "$ELPREP_BIN" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
      echo "ERROR: curl is required to download elPrep for target core" >&2
      exit 1
    fi
    if ! command -v tar >/dev/null 2>&1; then
      echo "ERROR: tar is required to extract elPrep for target core" >&2
      exit 1
    fi
  elif [[ ! -f "$ELPREP_BIN" ]]; then
    echo "ERROR: elprep binary not found: $ELPREP_BIN" >&2
    exit 1
  fi
fi

if want_target core; then
  GENOME_FASTA_RAW="$(resolve_from_references references.reference_genome)"
  GENOME_FAI_RAW="$(resolve_from_references references.reference_fai)"
  GENOME_DICT_RAW="$(resolve_from_references references.reference_dict)"
  BWA_AMB_RAW="$(resolve_from_references references.bwa_index_amb)"
  BWA_ANN_RAW="$(resolve_from_references references.bwa_index_ann)"
  BWA_PAC_RAW="$(resolve_from_references references.bwa_index_pac)"
  BWA_BWT_RAW="$(resolve_from_references references.bwa_index_bwt_2bit_64)"
  BWA_0123_RAW="$(resolve_from_references references.bwa_index_0123)"

  for candidate in "$GENOME_FASTA_RAW" "$GENOME_FAI_RAW" "$GENOME_DICT_RAW" "$BWA_AMB_RAW" "$BWA_ANN_RAW" "$BWA_PAC_RAW" "$BWA_BWT_RAW" "$BWA_0123_RAW"; do
    if [[ -z "$candidate" ]]; then
      echo "ERROR: core image requires GRCh38 reference assets in references.yaml" >&2
      exit 1
    fi
  done

  mkdir -p "$BUILD_CONTEXT/vendor/reference"
  cp "$REF_DATA_ROOT/$GENOME_FASTA_RAW" "$BUILD_CONTEXT/vendor/reference/$(basename "$GENOME_FASTA_RAW")"
  cp "$REF_DATA_ROOT/$GENOME_FAI_RAW" "$BUILD_CONTEXT/vendor/reference/$(basename "$GENOME_FAI_RAW")"
  cp "$REF_DATA_ROOT/$GENOME_DICT_RAW" "$BUILD_CONTEXT/vendor/reference/$(basename "$GENOME_DICT_RAW")"
  cp "$REF_DATA_ROOT/$BWA_AMB_RAW" "$BUILD_CONTEXT/vendor/reference/$(basename "$BWA_AMB_RAW")"
  cp "$REF_DATA_ROOT/$BWA_ANN_RAW" "$BUILD_CONTEXT/vendor/reference/$(basename "$BWA_ANN_RAW")"
  cp "$REF_DATA_ROOT/$BWA_PAC_RAW" "$BUILD_CONTEXT/vendor/reference/$(basename "$BWA_PAC_RAW")"
  cp "$REF_DATA_ROOT/$BWA_BWT_RAW" "$BUILD_CONTEXT/vendor/reference/$(basename "$BWA_BWT_RAW")"
  cp "$REF_DATA_ROOT/$BWA_0123_RAW" "$BUILD_CONTEXT/vendor/reference/$(basename "$BWA_0123_RAW")"
fi

if want_target annotation; then
  if [[ -z "$PHARMCAT_JAR" ]]; then
    echo "ERROR: target annotation requires a governed PharmCAT jar path in references.yaml at container_assets.pharmcat_jar, or an explicit --pharmcat-jar override" >&2
    exit 1
  fi
  if [[ ! -f "$PHARMCAT_JAR" ]]; then
    echo "ERROR: PharmCAT jar not found: $PHARMCAT_JAR" >&2
    exit 1
  fi
fi

BUILD_CONTEXT="$(mktemp -d "${SCRIPT_DIR}/.build.XXXXXX")"
cleanup() {
  rm -rf "$BUILD_CONTEXT"
}
trap cleanup EXIT

cp "${SCRIPT_DIR}/Dockerfile.core" "$BUILD_CONTEXT/Dockerfile.core"
cp "${SCRIPT_DIR}/Dockerfile.annotate" "$BUILD_CONTEXT/Dockerfile.annotate"
cp "${SCRIPT_DIR}/Dockerfile.reporting" "$BUILD_CONTEXT/Dockerfile.reporting"
mkdir -p "$BUILD_CONTEXT/vendor"

if want_target core; then
  if [[ -n "$ELPREP_BIN" ]]; then
    cp "$ELPREP_BIN" "$BUILD_CONTEXT/vendor/elprep"
  else
    echo "[fetch] elprep ${ELPREP_URL}" >&2
    curl -L --fail --retry 3 -o "$BUILD_CONTEXT/vendor/elprep.tar.gz" "$ELPREP_URL"
    observed_sha="$(sha256sum "$BUILD_CONTEXT/vendor/elprep.tar.gz" | awk '{print $1}')"
    if [[ "$observed_sha" != "$ELPREP_SHA256" ]]; then
      echo "ERROR: elprep tarball checksum mismatch: expected $ELPREP_SHA256 observed $observed_sha" >&2
      exit 1
    fi
    tar -xzf "$BUILD_CONTEXT/vendor/elprep.tar.gz" -C "$BUILD_CONTEXT/vendor"
    if [[ ! -f "$BUILD_CONTEXT/vendor/elprep" ]]; then
      echo "ERROR: downloaded elprep archive did not contain top-level elprep binary" >&2
      exit 1
    fi
  fi
fi
if want_target annotation; then
  cp "$PHARMCAT_JAR" "$BUILD_CONTEXT/vendor/pharmcat.jar"
fi

DOCKER_ARGS=()
if [[ "$NO_CACHE" -eq 1 ]]; then
  DOCKER_ARGS+=(--no-cache)
fi

build_docker() {
  local dockerfile="$1"
  local image="$2"
  echo "[build] docker ${image}:${TAG}" >&2
  docker build "${DOCKER_ARGS[@]}" -f "$BUILD_CONTEXT/$dockerfile" -t "${image}:${TAG}" "$BUILD_CONTEXT"
}

build_sif() {
  local image="$1"
  local sif_name="$2"
  local output_path="${SCRIPT_DIR}/${sif_name}"
  echo "[build] ${SIF_TOOL} ${output_path}" >&2
  rm -f "$output_path"
  "$SIF_TOOL" build "$output_path" "docker-daemon://${image}:${TAG}"
}

if want_target core; then
  build_docker Dockerfile.core genvar-core
fi
if want_target annotation; then
  build_docker Dockerfile.annotate genvar-annotation
fi
if want_target reporting; then
  build_docker Dockerfile.reporting genvar-reporting
fi

if [[ "$BUILD_SIF" -eq 1 ]]; then
  if want_target core; then
    build_sif genvar-core genvar-core.sif
  fi
  if want_target annotation; then
    build_sif genvar-annotation genvar-annotation.sif
  fi
  if want_target reporting; then
    build_sif genvar-reporting genvar-reporting.sif
  fi
fi

echo "Build complete." >&2
