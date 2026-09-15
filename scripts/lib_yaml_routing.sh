#!/usr/bin/env bash
# ==============================================================================
# YAML ROUTING UTILITIES
# Purpose: Provide bash functions for parsing sample YAML manifests and 
#          extracting routing information (sample_id, case_id, etc.) that 
#          governs output directory structure and asset_base_uri paths.
# 
# Contract: All Nextflow workflows MUST source this library to ensure that
#           output routing is driven solely by parsed YAML manifest content.
#           The sample_id extracted here becomes the Single Source of Truth.
# ==============================================================================

set -euo pipefail

# Extract sample_id from a Stage 0-compatible YAML manifest.
# Usage: extract_sample_id "/path/to/manifest.yaml"
# Output: single sample_id string (first sample if multi-sample)
# Fallback: "unknown_sample" if extraction fails
extract_sample_id() {
    local yaml_file="$1"
    
    if [[ ! -f "$yaml_file" ]]; then
        echo "ERROR: YAML file not found: $yaml_file" >&2
        return 1
    fi
    
    # Try yq first (if available); fall back to grep+awk
    if command -v yq &> /dev/null; then
        yq '.samples[0].sample_id' "$yaml_file" 2>/dev/null | grep -v 'null' || echo "unknown_sample"
    else
        # Fallback: grep for "sample_id:" and extract the value after the colon
        grep -m 1 'sample_id:' "$yaml_file" \
            | awk -F': ' '{print $2}' \
            | sed 's/"//g' \
            | tr -d " \t" \
            || echo "unknown_sample"
    fi
}

# Extract case_id from a Stage 0-compatible YAML manifest.
# Usage: extract_case_id "/path/to/manifest.yaml"
# Output: single case_id string (first sample if multi-sample)
# Fallback: extracted sample_id if case_id is empty
extract_case_id() {
    local yaml_file="$1"
    
    if [[ ! -f "$yaml_file" ]]; then
        echo "ERROR: YAML file not found: $yaml_file" >&2
        return 1
    fi
    
    if command -v yq &> /dev/null; then
        local case_id=$(yq '.samples[0].case_id' "$yaml_file" 2>/dev/null || echo "")
        if [[ -z "$case_id" || "$case_id" == "null" || "$case_id" == '""' ]]; then
            extract_sample_id "$yaml_file"
        else
            echo "$case_id"
        fi
    else
        local case_id=$(grep -m 1 '^\s*case_id:' "$yaml_file" \
            | awk -F': ' '{print $2}' \
            | tr -d ' "' \
            | head -1)
        if [[ -z "$case_id" ]]; then
            extract_sample_id "$yaml_file"
        else
            echo "$case_id"
        fi
    fi
}

# Extract sample_type from a Stage 0-compatible YAML manifest.
# Usage: extract_sample_type "/path/to/manifest.yaml"
# Output: sample_type string (germline, somatic, etc.)
# Fallback: "germline"
extract_sample_type() {
    local yaml_file="$1"
    
    if [[ ! -f "$yaml_file" ]]; then
        echo "ERROR: YAML file not found: $yaml_file" >&2
        return 1
    fi
    
    if command -v yq &> /dev/null; then
        yq '.samples[0].sample_type' "$yaml_file" 2>/dev/null || echo "germline"
    else
        grep -m 1 '^\s*sample_type:' "$yaml_file" \
            | awk -F': ' '{print $2}' \
            | tr -d ' "' \
            | head -1 \
            || echo "germline"
    fi
}

# Construct dynamic outdir based on extracted sample_id.
# Usage: compute_outdir_path "<base_outdir>" "<extracted_sample_id>"
# Output: computed outdir path
# Example: compute_outdir_path "tests" "hg002_mini" → "tests/outputs/hg002_mini"
compute_outdir_path() {
    local base_outdir="${1:-tests}"
    local sample_id="${2:-unknown_sample}"
    
    # Normalize base_outdir to remove trailing slashes
    base_outdir="${base_outdir%/}"
    
    # Construct: <base>/<sample_id> or <base>/outputs/<sample_id> depending on context
    # Using /outputs/ prefix ensures clear separation between test/production routing
    if [[ "$base_outdir" == "tests" ]]; then
        echo "${base_outdir}/outputs/${sample_id}"
    else
        echo "${base_outdir}/${sample_id}"
    fi
}

# Construct asset_base_uri based on outdir and sample_id.
# Usage: compute_asset_base_uri "<outdir>" "<sample_id>"
# Output: asset_base_uri suitable for workflow asset resolution
# Example: compute_asset_base_uri "tests/outputs/hg002_mini" "hg002_mini"
#          → "file:///media/drive_c/nf_pipes/nf_Gen_Var_Pipe/tests/outputs/hg002_mini"
compute_asset_base_uri() {
    local outdir="$1"
    local sample_id="${2:-unknown_sample}"
    
    # Make outdir absolute
    local abs_outdir
    if [[ "$outdir" = /* ]]; then
        abs_outdir="$outdir"
    else
        abs_outdir="$(cd "$(pwd)" && echo "${PWD}/${outdir}")"
    fi
    
    # Remove trailing slashes and construct file:// URI
    abs_outdir="${abs_outdir%/}"
    echo "file://${abs_outdir}"
}

# Validate that YAML file contains expected sample_id.
# Usage: validate_yaml_sample_id "/path/to/manifest.yaml" "expected_sample_id"
# Output: exit code 0 if match, 1 if mismatch
validate_yaml_sample_id() {
    local yaml_file="$1"
    local expected_sample_id="${2:-}"
    
    if [[ -z "$expected_sample_id" ]]; then
        echo "ERROR: Expected sample_id not provided for validation" >&2
        return 1
    fi
    
    local extracted_id=$(extract_sample_id "$yaml_file")
    
    if [[ "$extracted_id" == "$expected_sample_id" ]]; then
        return 0
    else
        echo "ERROR: Sample ID mismatch. Expected '$expected_sample_id', found '$extracted_id'" >&2
        return 1
    fi
}

# Export functions so they're available to sourcing scripts
export -f extract_sample_id
export -f extract_case_id
export -f extract_sample_type
export -f compute_outdir_path
export -f compute_asset_base_uri
export -f validate_yaml_sample_id
