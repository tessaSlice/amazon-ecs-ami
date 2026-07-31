#!/bin/bash

set -eo pipefail

# Flags
AL2_GPU_NVIDIA_VERSION=""
AL2_GPU_CUDA_VERSION=""
AL2023_GPU_NVIDIA_VERSION=""
EXCLUDE_AMI=""

usage() {
    cat <<-EOF
Usage:
  $0

Options:
	--al2-gpu-nvidia-ver  (Optional) AL2 GPU NVIDIA version. If specified, then --al2-gpu-cuda-ver option is also required to be specified.
	--al2-gpu-cuda-ver    (Optional) AL2 GPU CUDA version. If specified, then  --al2-gpu-nvidia-ver option is also required to be specified.
    --al2023-gpu-nvidia-ver (Optional) AL2023 GPU NVIDIA version.
	--exclude-ami         (Optional) comma separated list of AMI variants that are excluded in the release.

Example:
  $0 --al2-gpu-nvidia-ver 000.00.00 --al2-gpu-cuda-ver 00.0.0 --al2023-gpu-nvidia-ver 000.00.00 --exclude-ami al2023neu,al2inf
EOF
}

main() {
    parse_args "$@"
    validate_args
    generate_release_notes
}

# Parses the options specified for the script.
parse_args() {
    while :; do
        case $1 in
        --al2-gpu-nvidia-ver)
            AL2_GPU_NVIDIA_VERSION="$2"
            shift
            ;;
        --al2-gpu-cuda-ver)
            AL2_GPU_CUDA_VERSION="$2"
            shift
            ;;
        --al2023-gpu-nvidia-ver)
            AL2023_GPU_NVIDIA_VERSION="$2"
            shift
            ;;
        --exclude-ami)
            EXCLUDE_AMI="$2"
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        --) # End of options.
            shift
            break
            ;;
        *) # Default case: No more options - break out of the loop.
            break ;;
        esac
        shift
    done
}

# Validates the options specified for the script.
validate_args() {
    if [ -z "$AL2_GPU_CUDA_VERSION" ] || [ -z "$AL2_GPU_NVIDIA_VERSION" ]; then
        if ! { is_ami_excluded "al2gpu" && is_ami_excluded "al2kernel5dot10gpu"; }; then
            printf "Error: AL2 GPU CUDA version or AL2 GPU NVIDIA version is empty when releasing AL2 GPU\n\n"
            usage
            exit 1
        fi
    fi
    if [ -z "$AL2023_GPU_NVIDIA_VERSION" ] && ! is_ami_excluded "al2023gpu"; then
        printf "Error: AL2023 GPU NVIDIA version is empty when releasing AL2023 GPU \n\n"
        usage
        exit 1
    fi
}

# Generates the relevant notes for the release.
#
# The package details are rendered as HTML tables (in the same style as the
# amazon-eks-ami release notes) so that packages shared across every variant in
# a family (containerd, runc) can be collapsed into a single cell with colspan,
# while per-variant packages get one column each. Each OS family is wrapped in a
# collapsible <details> block.
generate_release_notes() {
    # Below file contains containerd version information for AL2023 and AL2 AMIs
    readonly variablespkr="variables.pkr.hcl"

    # Determine AMI version from pkrvars files
    placeholder_version="00000000"
    ami_version="$placeholder_version"
    readonly al2023pkrvars="release-al2023.auto.pkrvars.hcl"
    readonly al2pkrvars="release-al2.auto.pkrvars.hcl"
    pkvars_files="$al2023pkrvars $al2pkrvars"
    for file in $pkvars_files; do
        file_ami_version=$(cat $file | grep 'ami_version' | cut -d '"' -f2)
        if [[ $file_ami_version -gt $ami_version ]]; then
            ami_version="$file_ami_version"
        fi
    done

    if [ "$ami_version" == "$placeholder_version" ]; then
        echo "Error: AMI version was not found in files $pkvars_files"
        exit 1
    fi

    # Accumulator, populated by render_section below: the per-family collapsible
    # package tables.
    details_sections=""

    # AL2023
    if ! { is_ami_excluded "al2023" && is_ami_excluded "al2023arm" && is_ami_excluded "al2023neu" && is_ami_excluded "al2023gpu"; }; then
        # Get AL2023 AMI family details
        readonly containerd_version_al2023=$(cat $variablespkr | sed -n '/containerd_version_al2023"/,/}/p' | grep -w 'default' | cut -d '"' -f2)
        readonly runc_version_al2023=$(cat $variablespkr | sed -n '/runc_version_al2023"/,/}/p' | grep -w 'default' | cut -d '"' -f2)
        if [ -z "$containerd_version_al2023" ]; then
            echo "Error: Containerd version was not found for AL2023 in $variablespkr"
            exit 1
        fi
        if [ -z "$runc_version_al2023" ]; then
            echo "Error: Runc version was not found for AL2023 in $variablespkr"
            exit 1
        fi

        reset_section
        # Include each AL2023 variant that was not excluded from the release.
        if ! is_ami_excluded "al2023"; then
            collect_variant "AMD64" "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended" "" ""
        fi
        if ! is_ami_excluded "al2023arm"; then
            collect_variant "ARM64" "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended" "" ""
        fi
        if ! is_ami_excluded "al2023neu"; then
            collect_variant "Neuron" "/aws/service/ecs/optimized-ami/amazon-linux-2023/neuron/recommended" "" ""
        fi
        if ! is_ami_excluded "al2023gpu"; then
            collect_variant "GPU" "/aws/service/ecs/optimized-ami/amazon-linux-2023/gpu/recommended" "$AL2023_GPU_NVIDIA_VERSION" ""
        fi
        render_section "Amazon ECS-optimized Amazon Linux 2023 AMI" "$containerd_version_al2023" "$runc_version_al2023"
    fi

    # AL2 (the Kernel 4.14 and Kernel 5.10 families share containerd/runc versions)
    if ! { is_ami_excluded "al2" && is_ami_excluded "al2arm" && is_ami_excluded "al2inf" && is_ami_excluded "al2gpu" &&
        is_ami_excluded "al2kernel5dot10" && is_ami_excluded "al2kernel5dot10arm" &&
        is_ami_excluded "al2kernel5dot10inf" && is_ami_excluded "al2kernel5dot10gpu"; }; then
        # Get AL2 AMI family details
        readonly containerd_version=$(cat $variablespkr | sed -n '/containerd_version"/,/}/p' | grep -w 'default' | cut -d '"' -f2)
        readonly runc_version=$(cat $variablespkr | sed -n '/runc_version"/,/}/p' | grep -w 'default' | cut -d '"' -f2)
        if [ -z "$containerd_version" ]; then
            echo "Error: Containerd version was not found in $variablespkr"
            exit 1
        fi
        if [ -z "$runc_version" ]; then
            echo "Error: Runc version was not found in $variablespkr"
            exit 1
        fi

        # AL2 Kernel 4.14
        reset_section
        if ! is_ami_excluded "al2"; then
            collect_variant "AMD64" "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended" "" ""
        fi
        if ! is_ami_excluded "al2arm"; then
            collect_variant "ARM64" "/aws/service/ecs/optimized-ami/amazon-linux-2/arm64/recommended" "" ""
        fi
        if ! is_ami_excluded "al2inf"; then
            collect_variant "Neuron" "/aws/service/ecs/optimized-ami/amazon-linux-2/inf/recommended" "" ""
        fi
        if ! is_ami_excluded "al2gpu"; then
            collect_variant "GPU" "/aws/service/ecs/optimized-ami/amazon-linux-2/gpu/recommended" "$AL2_GPU_NVIDIA_VERSION" "$AL2_GPU_CUDA_VERSION"
        fi
        render_section "Amazon ECS-optimized Amazon Linux 2 AMI (Kernel 4.14)" "$containerd_version" "$runc_version"

        # AL2 Kernel 5.10
        reset_section
        if ! is_ami_excluded "al2kernel5dot10"; then
            collect_variant "AMD64" "/aws/service/ecs/optimized-ami/amazon-linux-2/kernel-5.10/recommended" "" ""
        fi
        if ! is_ami_excluded "al2kernel5dot10arm"; then
            collect_variant "ARM64" "/aws/service/ecs/optimized-ami/amazon-linux-2/kernel-5.10/arm64/recommended" "" ""
        fi
        if ! is_ami_excluded "al2kernel5dot10inf"; then
            collect_variant "Neuron" "/aws/service/ecs/optimized-ami/amazon-linux-2/kernel-5.10/inf/recommended" "" ""
        fi
        if ! is_ami_excluded "al2kernel5dot10gpu"; then
            collect_variant "GPU" "/aws/service/ecs/optimized-ami/amazon-linux-2/kernel-5.10/gpu/recommended" "$AL2_GPU_NVIDIA_VERSION" "$AL2_GPU_CUDA_VERSION"
        fi
        render_section "Amazon ECS-optimized Amazon Linux 2 AMI (Kernel 5.10)" "$containerd_version" "$runc_version"
    fi

    # Assemble the final release notes.
    release_notes="### Source AMI release notes
---
* [Amazon Linux 2023 release notes](https://docs.aws.amazon.com/linux/al2023/release-notes/relnotes.html)
* [Amazon Linux 2 release notes](https://docs.aws.amazon.com/AL2/latest/relnotes/relnotes-al2.html)

### Changelog
---
https://github.com/aws/amazon-ecs-ami/blob/main/CHANGELOG.md#$ami_version
"

    release_notes="${release_notes}${details_sections}"

    echo -n "$release_notes"
}

# Checks if a given AMI variant is excluded in the release.
is_ami_excluded() {
    local ami="$1"
    echo "$EXCLUDE_AMI" | grep -wq "$ami"
}

# Gets ECS Optimized AMI details from SSM parameter store given the parameter name.
# Uses the default AWS credentials as the parameter is public and can be
# fetched from a standard region (us-west-2 is used).
get_ami_details() {
    parameter_name=$1
    ami_details=$(aws ssm --region "us-west-2" get-parameters --names $parameter_name --query 'Parameters[0].Value' --output text | jq .)
    ami_name=$(echo "$ami_details" | jq -r '.image_name')
    agent_version=$(echo "$ami_details" | jq -r '.ecs_agent_version')
    docker_version=$(echo "$ami_details" | jq -r '.ecs_runtime_version' | awk '{print $3}')
    source_ami_name=$(echo "$ami_details" | jq -r '.source_image_name')
    echo "$ami_name $agent_version $docker_version $source_ami_name"
}

# Column accumulators for the family currently being rendered. Each index holds
# the details for one AMI variant (one column of the family's package table).
COL_LABELS=()
COL_AMI_NAMES=()
COL_AGENT=()
COL_DOCKER=()
COL_NVIDIA=()
COL_CUDA=()

# Clears the column accumulators before collecting a new family's variants.
reset_section() {
    COL_LABELS=()
    COL_AMI_NAMES=()
    COL_AGENT=()
    COL_DOCKER=()
    COL_NVIDIA=()
    COL_CUDA=()
}

# Collects one AMI variant into the current family's columns.
#   $1 col_label   Short column header within the family's package table.
#   $2 ssm_path    SSM parameter name for the recommended AMI.
#   $3 nvidia_ver  NVIDIA driver version, or "" if not applicable.
#   $4 cuda_ver    CUDA version, or "" if not applicable.
collect_variant() {
    local col_label="$1"
    local ssm_path="$2"
    local nvidia_ver="$3"
    local cuda_ver="$4"

    local name agent_ver docker_ver source_name
    read name agent_ver docker_ver source_name <<<$(get_ami_details "$ssm_path")

    COL_LABELS+=("$col_label")
    COL_AMI_NAMES+=("$name")
    COL_AGENT+=("$agent_ver")
    COL_DOCKER+=("$docker_ver")
    COL_NVIDIA+=("$nvidia_ver")
    COL_CUDA+=("$cuda_ver")
}

# Renders the collected variants as an HTML package matrix inside a collapsible
# <details> section. Packages that are identical across the whole family
# (containerd, runc) are emitted once with a colspan; per-variant packages get
# one <td> per column. Optional rows (NVIDIA, CUDA) are only emitted when at
# least one variant in the family provides a value; cells that do not apply are
# filled with an em dash.
#   $1 title           <summary> label for the collapsible section.
#   $2 containerd_ver  Shared containerd version for the family.
#   $3 runc_ver        Shared runc version for the family.
render_section() {
    local title="$1"
    local containerd_ver="$2"
    local runc_ver="$3"

    local n=${#COL_LABELS[@]}
    if [ "$n" -eq 0 ]; then
        return
    fi

    # Only render the NVIDIA/CUDA rows if some variant in this family has them.
    local show_nvidia=false
    local show_cuda=false
    local v
    for v in "${COL_NVIDIA[@]}"; do
        if [ -n "$v" ]; then show_nvidia=true; fi
    done
    for v in "${COL_CUDA[@]}"; do
        if [ -n "$v" ]; then show_cuda=true; fi
    done

    details_sections="${details_sections}
<details>
<summary><b>${title}</b></summary>
<table>
<tr><th>Package</th>"
    for v in "${COL_LABELS[@]}"; do
        details_sections="${details_sections}<th>${v}</th>"
    done
    details_sections="${details_sections}</tr>"

    details_sections="${details_sections}
<tr><td>AMI name</td>"
    for v in "${COL_AMI_NAMES[@]}"; do
        details_sections="${details_sections}<td>${v}</td>"
    done
    details_sections="${details_sections}</tr>"

    details_sections="${details_sections}
<tr><td>ECS agent</td>"
    for v in "${COL_AGENT[@]}"; do
        details_sections="${details_sections}<td><a href=\"https://github.com/aws/amazon-ecs-agent/releases/tag/v${v}\">${v}</a></td>"
    done
    details_sections="${details_sections}</tr>"

    details_sections="${details_sections}
<tr><td>Docker</td>"
    for v in "${COL_DOCKER[@]}"; do
        details_sections="${details_sections}<td>${v}</td>"
    done
    details_sections="${details_sections}</tr>"

    # containerd and runc are identical across the family: collapse via colspan.
    details_sections="${details_sections}
<tr><td>containerd</td><td colspan=\"${n}\">${containerd_ver}</td></tr>"
    details_sections="${details_sections}
<tr><td>runc</td><td colspan=\"${n}\">${runc_ver}</td></tr>"

    if [ "$show_nvidia" = true ]; then
        details_sections="${details_sections}
<tr><td>NVIDIA driver</td>"
        for v in "${COL_NVIDIA[@]}"; do
            details_sections="${details_sections}<td>${v:-—}</td>"
        done
        details_sections="${details_sections}</tr>"
    fi

    if [ "$show_cuda" = true ]; then
        details_sections="${details_sections}
<tr><td>CUDA</td>"
        for v in "${COL_CUDA[@]}"; do
            details_sections="${details_sections}<td>${v:-—}</td>"
        done
        details_sections="${details_sections}</tr>"
    fi

    details_sections="${details_sections}
</table>
</details>
"
}

main "$@"
