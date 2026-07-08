#!/usr/bin/env bash
ulimit -n 524288
set -euo pipefail

###############################################################################
# End-to-end test script for GPU metrics on ECS EC2
#
# This script:
#   1. Builds the ecs-init RPM from the amazon-ecs-agent repo
#   2. Copies the RPM to the amazon-ecs-ami repo
#   3. Builds the AL2023 GPU AMI
#   4. Launches a g4dn.xlarge instance (directly by default, or via an ASG +
#      capacity provider with --use-asg) and registers it with the cluster
#   5. Deploys a GPU-intensive ECS task
#   6. Verifies GPU metrics appear in CloudWatch Enhanced Container Insights,
#      including the container-level set AND the instance-level metrics
#      (InstanceGPULimit, InstanceGPUUsageTotal) at both the cluster-level
#      dimension set {ClusterName} and the per-instance dimension set
#      {ClusterName, CapacityProviderName, ContainerInstanceId, EC2InstanceId}
#   7. Cleans up all resources
#
# Prerequisites:
#   - Valid AWS credentials (ada credentials update)
#   - amazon-ecs-agent repo checked out at the expected path
#   - Task definition gpu-burn-test:4 already registered in the target region
#
# Usage:
#   ./scripts/test-gpu-metrics-e2e.sh [OPTIONS]
#
# Options:
#   --region REGION          AWS region (default: us-east-1)
#   --account ACCOUNT_ID     AWS account ID for ada credentials
#   --role ROLE              IAM role for ada credentials (default: Admin)
#   --agent-repo PATH       Path to amazon-ecs-agent worktree
#   --skip-rpm-build        Skip RPM build, use existing RPM in additional-packages/
#   --skip-ami-build        Skip AMI build, use provided AMI ID
#   --ami-id AMI_ID         AMI ID to use (requires --skip-ami-build)
#   --instance-type TYPE    Instance type (default: g4dn.xlarge)
#   --task-definition TD    Task definition (default: gpu-burn-test:4)
#   --use-asg               Provision the instance via an Auto Scaling Group +
#                           ECS capacity provider instead of a direct EC2 launch
#                           (default: direct launch, no ASG)
#   --cleanup               Destroy all AWS resources after test (default: keep resources)
#   --no-cleanup            Keep resources after test (default behavior)
#   --delete-cluster NAME   Delete a cluster and all associated resources, then exit
#   --timeout SECONDS       Max wait time for GPU metrics (default: 600)
###############################################################################

# Default configuration values — override via command-line flags
REGION="us-east-1"
ACCOUNT_ID=""
ROLE="Admin"
AGENT_REPO="$HOME/workplace/amazon-ecs-agent/.claude/worktrees/dcgm-init"
SKIP_RPM_BUILD=false
SKIP_AMI_BUILD=false
AMI_ID=""
INSTANCE_TYPE="g4dn.xlarge"
TASK_DEFINITION="gpu-burn-test:4"
NO_CLEANUP=true
TIMEOUT=600
DELETE_CLUSTER_NAME=""
USE_ASG=false

# Resolve the root of the amazon-ecs-ami repo (one level up from scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Unique identifier for all AWS resources created in this run, enables
# parallel test runs and makes cleanup deterministic
TEST_ID="gpu-test-$(date +%Y%m%d%H%M%S)"

# Tracks the security group ID for cleanup (set during setup_infrastructure)
CREATED_RESOURCES=()

cleanup() {
    # Called automatically on EXIT (success or failure) via trap.
    # Default behavior is to keep resources (NO_CLEANUP=true).
    # Pass --cleanup to destroy all resources created during the test.
    if [ "$NO_CLEANUP" = true ]; then
        echo "==> Keeping resources (pass --cleanup to destroy them)"
        echo "    Resources created with prefix: $TEST_ID"
        return
    fi

    # Delegate to delete_cluster which handles the full teardown sequence
    delete_cluster "$TEST_ID"
}

die() {
    echo "ERROR: $1" >&2
    exit 1
}

delete_cluster() {
    # Deletes a gpu-test-* cluster and all associated resources by name.
    # Handles both provisioning models:
    #   - Direct launch: an EC2 instance tagged Name=<cluster-name>, plus <cluster-name>-sg
    #   - ASG-backed:    <cluster-name>-asg, <cluster-name>-cp, <cluster-name>-lt, the
    #                    ASG-launched instance, plus <cluster-name>-sg
    # ASG-specific deletes are guarded so they're harmless no-ops for direct-launch runs.
    local cluster_name="$1"
    local region="$REGION"

    echo "==> Deleting cluster: $cluster_name (region: $region)"

    # 1. Scale and delete ECS service
    for svc in $(aws ecs list-services --cluster "$cluster_name" --region "$region" \
        --query "serviceArns[]" --output text 2>/dev/null); do
        local svc_name
        svc_name=$(basename "$svc")
        echo "    Deleting service: $svc_name"
        aws ecs update-service --cluster "$cluster_name" --service "$svc_name" \
            --desired-count 0 --region "$region" 2>/dev/null || true
        aws ecs delete-service --cluster "$cluster_name" --service "$svc_name" \
            --force --region "$region" 2>/dev/null || true
    done

    # 2. Wait for services to drain
    local drain_attempts=0
    while [ $drain_attempts -lt 12 ]; do
        local svc_count
        svc_count=$(aws ecs describe-clusters --clusters "$cluster_name" --region "$region" \
            --query "clusters[0].activeServicesCount" --output text 2>/dev/null)
        [ "$svc_count" = "0" ] && break
        sleep 5
        drain_attempts=$((drain_attempts + 1))
    done

    # 3. Deregister all container instances
    for ci in $(aws ecs list-container-instances --cluster "$cluster_name" --region "$region" \
        --query "containerInstanceArns[]" --output text 2>/dev/null); do
        aws ecs deregister-container-instance --cluster "$cluster_name" \
            --container-instance "$ci" --force --region "$region" 2>/dev/null || true
    done

    # 4. Detach capacity providers from the cluster (ASG runs only; no-op otherwise).
    #    The cluster can't be deleted while cluster-scoped capacity providers are attached.
    aws ecs put-cluster-capacity-providers --cluster "$cluster_name" \
        --capacity-providers "[]" --default-capacity-provider-strategy "[]" \
        --region "$region" 2>/dev/null || true

    # 5. Find, deregister the AMI, and terminate EC2 instances tagged with the cluster name
    local terminated_instances=""
    for instance_id in $(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=${cluster_name}" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --region "$region" \
        --query "Reservations[*].Instances[*].InstanceId" --output text 2>/dev/null); do
        # Capture the AMI ID from the instance before terminating it
        local ami_id
        ami_id=$(aws ec2 describe-instances --instance-ids "$instance_id" --region "$region" \
            --query "Reservations[0].Instances[0].ImageId" --output text 2>/dev/null)
        echo "    Terminating instance: $instance_id"
        aws ec2 terminate-instances --instance-ids "$instance_id" --region "$region" 2>/dev/null || true
        terminated_instances="$terminated_instances $instance_id"
        # Deregister the AMI that was baked for this test
        if [ -n "$ami_id" ] && [ "$ami_id" != "None" ]; then
            echo "    Deregistering AMI: $ami_id"
            aws ec2 deregister-image --image-id "$ami_id" --region "$region" 2>/dev/null || true
        fi
    done

    # 6. Delete the ASG (force-delete also terminates any remaining ASG instance),
    #    its capacity provider, and launch template (ASG runs only; no-ops otherwise).
    if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${cluster_name}-asg" \
        --region "$region" --query "AutoScalingGroups[0]" --output text 2>/dev/null | grep -q .; then
        echo "    Deleting Auto Scaling Group: ${cluster_name}-asg"
        aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "${cluster_name}-asg" \
            --force-delete --region "$region" 2>/dev/null || true
    fi
    aws ecs delete-capacity-provider --capacity-provider "${cluster_name}-cp" \
        --region "$region" 2>/dev/null || true
    aws ec2 delete-launch-template --launch-template-name "${cluster_name}-lt" \
        --region "$region" 2>/dev/null || true

    # 7. Delete cluster (retry: capacity-provider detach leaves attachments
    #    briefly in an updating state that blocks deletion)
    local cluster_attempts=0
    while [ $cluster_attempts -lt 8 ]; do
        local cstatus
        cstatus=$(aws ecs delete-cluster --cluster "$cluster_name" --region "$region" \
            --query "cluster.status" --output text 2>/dev/null)
        [ "$cstatus" = "INACTIVE" ] && break
        # Also break if the cluster is already gone
        aws ecs describe-clusters --clusters "$cluster_name" --region "$region" \
            --query "clusters[0].status" --output text 2>/dev/null | grep -qE "INACTIVE|^None$|^$" && break
        sleep 12
        cluster_attempts=$((cluster_attempts + 1))
    done

    # 8. Wait for terminated instances to release their ENIs, then delete the security group
    for instance_id in $terminated_instances; do
        aws ec2 wait instance-terminated --instance-ids "$instance_id" --region "$region" 2>/dev/null || true
    done
    local sg_id
    sg_id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${cluster_name}-sg" \
        --region "$region" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)
    if [ -n "$sg_id" ] && [ "$sg_id" != "None" ]; then
        # Retry SG deletion a few times in case the ENI is still detaching
        local sg_attempts=0
        while [ $sg_attempts -lt 6 ]; do
            aws ec2 delete-security-group --group-id "$sg_id" --region "$region" 2>/dev/null && break
            sleep 15
            sg_attempts=$((sg_attempts + 1))
        done
    fi

    echo "==> Cluster $cluster_name and all associated resources deleted"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
        --region)
            REGION="$2"
            shift 2
            ;;
        --account)
            ACCOUNT_ID="$2"
            shift 2
            ;;
        --role)
            ROLE="$2"
            shift 2
            ;;
        --agent-repo)
            AGENT_REPO="$2"
            shift 2
            ;;
        --skip-rpm-build)
            SKIP_RPM_BUILD=true
            shift
            ;;
        --skip-ami-build)
            SKIP_AMI_BUILD=true
            shift
            ;;
        --ami-id)
            AMI_ID="$2"
            shift 2
            ;;
        --instance-type)
            INSTANCE_TYPE="$2"
            shift 2
            ;;
        --task-definition)
            TASK_DEFINITION="$2"
            shift 2
            ;;
        --use-asg)
            USE_ASG=true
            shift
            ;;
        --cleanup)
            NO_CLEANUP=false
            shift
            ;;
        --no-cleanup)
            NO_CLEANUP=true
            shift
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --delete-cluster)
            DELETE_CLUSTER_NAME="$2"
            shift 2
            ;;
        *) die "Unknown option: $1" ;;
        esac
    done
}

refresh_credentials() {
    if [ -n "$ACCOUNT_ID" ]; then
        echo "==> Refreshing AWS credentials..."
        ada credentials update --account="$ACCOUNT_ID" --role="$ROLE" --once

        # ada writes credentials to ~/.aws/credentials, but stale
        # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
        # environment variables (if present) take precedence over the file and
        # will keep using the expired session token. Unset them so the CLI and
        # packer fall back to the freshly-refreshed credentials file.
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    fi

    # Verify credentials work
    aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1 ||
        die "AWS credentials are invalid or expired. Provide --account and --role, or refresh manually."
}

build_rpm() {
    if [ "$SKIP_RPM_BUILD" = true ]; then
        echo "==> Skipping RPM build (--skip-rpm-build)"
        return
    fi

    echo "==> Building ecs-init RPM from $AGENT_REPO..."
    [ -d "$AGENT_REPO" ] || die "Agent repo not found at: $AGENT_REPO"

    # Build the RPM using CodeBuild-style make target. This compiles ecs-init,
    # dcgm-init, amazon-ecs-volume-plugin, and packages them into a single RPM.
    (cd "$AGENT_REPO" && make amazon-linux-rpm-codebuild)

    # Find the newest built RPM (sort -V handles version sorting correctly)
    local rpm_file
    rpm_file=$(find "$AGENT_REPO/RPMS" -name "ecs-init-*.amzn2023int.x86_64.rpm" | sort -V | tail -1)
    [ -f "$rpm_file" ] || die "RPM not found after build"

    echo "==> Copying RPM to additional-packages/..."
    # Remove any old RPMs to avoid install conflicts (dnf fails if two
    # versions of the same package are present)
    rm -f "$SCRIPT_DIR/additional-packages"/ecs-init-*.amzn2023int.x86_64.rpm
    cp "$rpm_file" "$SCRIPT_DIR/additional-packages/"

    # Extract version from RPM filename (e.g., "1.104.0" from "ecs-init-1.104.0-1.amzn2023int.x86_64.rpm")
    local rpm_basename
    rpm_basename=$(basename "$rpm_file")
    local agent_version
    agent_version=$(echo "$rpm_basename" | sed 's/ecs-init-\(.*\)-1.amzn2023int.x86_64.rpm/\1/')

    echo "==> RPM built: $rpm_basename (version $agent_version)"
    echo "    Updating release-al2023.auto.pkrvars.hcl..."

    # Update the Packer variables file so the AMI build uses the correct
    # agent version tag and knows to install from the local RPM override
    sed -i "s/^ecs_agent_version.*/ecs_agent_version         = \"$agent_version\"/" \
        "$SCRIPT_DIR/release-al2023.auto.pkrvars.hcl"
    sed -i "s/^ecs_init_local_override.*/ecs_init_local_override   = \"$rpm_basename\"/" \
        "$SCRIPT_DIR/release-al2023.auto.pkrvars.hcl"
    # Append the override line if it doesn't exist yet (fresh pkrvars files
    # from main branch won't have it)
    if ! grep -q "^ecs_init_local_override" "$SCRIPT_DIR/release-al2023.auto.pkrvars.hcl"; then
        echo "ecs_init_local_override   = \"$rpm_basename\"" >>"$SCRIPT_DIR/release-al2023.auto.pkrvars.hcl"
    fi
}

build_ami() {
    if [ "$SKIP_AMI_BUILD" = true ]; then
        echo "==> Skipping AMI build (--skip-ami-build), using AMI: $AMI_ID"
        [ -n "$AMI_ID" ] || die "--ami-id required when using --skip-ami-build"
        return
    fi

    echo "==> Building AL2023 GPU AMI..."

    # The GPU AMI build takes ~20 min. Refresh credentials right before it so
    # packer has a full session-token TTL window and won't hit RequestExpired
    # partway through (e.g. at the stop-instance / create-image step).
    refresh_credentials

    # Use a timestamp-based version to guarantee uniqueness and avoid
    # "AMI Name already in use" errors from previous builds
    local version_suffix
    version_suffix=$(date +%Y%m%d.%H%M%S)
    sed -i "s/^ami_version_al2023.*/ami_version_al2023        = \"$version_suffix\"/" \
        "$SCRIPT_DIR/release-al2023.auto.pkrvars.hcl"

    # Run Packer to build the GPU AMI (~20 min: compiles NVIDIA DKMS modules)
    (cd "$SCRIPT_DIR" && REGION="$REGION" make al2023gpu)

    # Packer writes a manifest.json with the built AMI ID; extract it
    AMI_ID=$(jq -r '.builds[-1].artifact_id' "$SCRIPT_DIR/manifest.json" | cut -d: -f2)
    [ -n "$AMI_ID" ] || die "Failed to extract AMI ID from manifest.json"
    echo "==> AMI built: $AMI_ID"
}

find_available_subnet() {
    # GPU instances are often capacity-constrained in specific AZs.
    # This function probes each default subnet with a dry-run launch to find
    # one that has capacity for the requested instance type. If none pass the
    # dry-run, it returns the first subnet as a fallback (setup_infrastructure
    # then retries the real launch across all subnets).
    local region="$1"
    local instance_type="$2"

    local subnets
    subnets=$(aws ec2 describe-subnets --filters "Name=defaultForAz,Values=true" \
        --query "Subnets[*].[SubnetId,AvailabilityZone]" --output text --region "$region")

    while IFS=$'\t' read -r subnet_id az; do
        echo "    Checking capacity in $az..." >&2
        # dry-run: "DryRunOperation" means the request would succeed
        if aws ec2 run-instances --instance-type "$instance_type" --subnet-id "$subnet_id" \
            --image-id "$AMI_ID" --dry-run --region "$region" 2>&1 | grep -q "DryRunOperation"; then
            echo "$subnet_id"
            return 0
        fi
    done <<<"$subnets"

    # Fallback — return first subnet and handle capacity errors in setup_infrastructure
    echo "$subnets" | head -1 | awk '{print $1}'
}

setup_infrastructure() {
    echo "==> Setting up ECS infrastructure..."

    # Get VPC
    local vpc_id
    vpc_id=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
        --query "Vpcs[0].VpcId" --output text --region "$REGION")

    # Find a subnet with capacity
    echo "    Finding subnet with $INSTANCE_TYPE capacity..."
    local subnet_id
    subnet_id=$(find_available_subnet "$REGION" "$INSTANCE_TYPE")
    echo "    Using subnet: $subnet_id"

    # Create security group
    SG_ID=$(aws ec2 create-security-group --group-name "${TEST_ID}-sg" \
        --description "SG for GPU metrics test $TEST_ID" \
        --vpc-id "$vpc_id" --region "$REGION" --query "GroupId" --output text)
    echo "    Security group: $SG_ID"

    # Encode user data
    local userdata
    userdata=$(echo -n "#!/bin/bash
echo ECS_CLUSTER=$TEST_ID >> /etc/ecs/ecs.config
echo ECS_ENABLE_GPU_SUPPORT=true >> /etc/ecs/ecs.config
" | base64 -w0)

    # Create ECS cluster with enhanced container insights
    aws ecs create-cluster --cluster-name "$TEST_ID" --region "$REGION" \
        --settings "name=containerInsights,value=enhanced" >/dev/null
    echo "    Cluster: $TEST_ID"

    # Provision the instance either via an ASG + capacity provider (--use-asg)
    # or by launching a single EC2 instance directly (default).
    if [ "$USE_ASG" = true ]; then
        provision_via_asg "$subnet_id" "$userdata"
    else
        provision_direct_instance "$subnet_id" "$userdata"
    fi

    # Wait for ECS registration (common to both provisioning paths)
    echo "    Waiting for instance to register with ECS..."
    local reg_attempts=0
    local ci_count=0
    while [ $reg_attempts -lt 12 ]; do
        ci_count=$(aws ecs list-container-instances --cluster "$TEST_ID" --region "$REGION" \
            --query "length(containerInstanceArns)" --output text)
        if [ "$ci_count" -gt 0 ] 2>/dev/null; then
            break
        fi
        sleep 10
        reg_attempts=$((reg_attempts + 1))
    done

    [ "$ci_count" -gt 0 ] 2>/dev/null || die "Instance failed to register with ECS cluster"
    echo "    Instance registered with ECS"
}

provision_direct_instance() {
    # Launch a single EC2 instance directly (no ASG / capacity provider).
    # The instance joins the cluster via the ECS_CLUSTER setting in user data.
    # GPU instances can be capacity-constrained in a given AZ, so we retry
    # across the default subnets until one succeeds.
    local subnet_id="$1"
    local userdata="$2"

    echo "    Launching EC2 instance directly (no ASG)..."
    local instance_id=""
    local launch_subnets
    launch_subnets=$(aws ec2 describe-subnets --filters "Name=defaultForAz,Values=true" \
        --query "Subnets[*].SubnetId" --output text --region "$REGION")
    # Put the chosen subnet first so we try it before the rest
    launch_subnets="$subnet_id $(echo "$launch_subnets" | tr '\t' '\n' | grep -v "^${subnet_id}$" | tr '\n' ' ')"

    for try_subnet in $launch_subnets; do
        [ -n "$try_subnet" ] || continue
        echo "    Trying subnet $try_subnet..."
        instance_id=$(aws ec2 run-instances \
            --image-id "$AMI_ID" \
            --instance-type "$INSTANCE_TYPE" \
            --iam-instance-profile "Name=ecsInstanceRole" \
            --security-group-ids "$SG_ID" \
            --subnet-id "$try_subnet" \
            --user-data "$(echo "$userdata" | base64 -d)" \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TEST_ID}]" \
            --region "$REGION" \
            --query "Instances[0].InstanceId" --output text 2>/dev/null) || instance_id=""

        if [ -n "$instance_id" ] && [ "$instance_id" != "None" ]; then
            echo "    Launched instance $instance_id in $try_subnet"
            break
        fi
        echo "    Capacity unavailable in $try_subnet, trying next..."
    done

    [ -n "$instance_id" ] && [ "$instance_id" != "None" ] ||
        die "Failed to launch instance in any availability zone"

    INSTANCE_ID="$instance_id"

    # Wait for instance to be healthy
    echo "    Waiting for instance health checks..."
    aws ec2 wait instance-status-ok --instance-ids "$instance_id" --region "$REGION"

    # Refresh credentials after the long wait (instance health check can take 3+ min)
    refresh_credentials
}

provision_via_asg() {
    # Provision the instance via a launch template + Auto Scaling Group, and
    # register the ASG with the cluster as a managed ECS capacity provider.
    # GPU capacity can be constrained per-AZ, so the ASG spans all default
    # subnets and ECS managed scaling places the instance where capacity exists.
    local subnet_id="$1"
    local userdata="$2"

    # Collect all default subnets so the ASG can pick an AZ with capacity
    local all_subnets
    all_subnets=$(aws ec2 describe-subnets --filters "Name=defaultForAz,Values=true" \
        --query "Subnets[*].SubnetId" --output text --region "$REGION" | tr '\t' ',')

    echo "    Creating launch template: ${TEST_ID}-lt"
    aws ec2 create-launch-template --launch-template-name "${TEST_ID}-lt" \
        --region "$REGION" \
        --launch-template-data "{
            \"ImageId\": \"$AMI_ID\",
            \"InstanceType\": \"$INSTANCE_TYPE\",
            \"IamInstanceProfile\": {\"Name\": \"ecsInstanceRole\"},
            \"SecurityGroupIds\": [\"$SG_ID\"],
            \"UserData\": \"$userdata\",
            \"TagSpecifications\": [{\"ResourceType\": \"instance\", \"Tags\": [{\"Key\": \"Name\", \"Value\": \"$TEST_ID\"}]}]
        }" >/dev/null

    echo "    Creating Auto Scaling Group: ${TEST_ID}-asg"
    aws autoscaling create-auto-scaling-group \
        --auto-scaling-group-name "${TEST_ID}-asg" \
        --launch-template "LaunchTemplateName=${TEST_ID}-lt,Version=\$Latest" \
        --min-size 0 --max-size 1 --desired-capacity 1 \
        --vpc-zone-identifier "$all_subnets" \
        --new-instances-protected-from-scale-in \
        --region "$REGION"

    # Wait for the ASG to bring an instance InService
    echo "    Waiting for ASG instance to launch..."
    local instance_id=""
    local attempts=0
    while [ $attempts -lt 20 ]; do
        instance_id=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names "${TEST_ID}-asg" --region "$REGION" \
            --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId | [0]" \
            --output text 2>/dev/null)
        if [ -n "$instance_id" ] && [ "$instance_id" != "None" ]; then
            echo "    ASG instance InService: $instance_id"
            break
        fi
        sleep 15
        attempts=$((attempts + 1))
    done

    [ -n "$instance_id" ] && [ "$instance_id" != "None" ] ||
        die "ASG failed to bring an instance InService"

    INSTANCE_ID="$instance_id"

    # Wait for instance to be healthy
    echo "    Waiting for instance health checks..."
    aws ec2 wait instance-status-ok --instance-ids "$instance_id" --region "$REGION"

    # Refresh credentials after the long wait (instance health check can take 3+ min)
    refresh_credentials

    # Create the ECS capacity provider backed by the ASG and attach it to the cluster
    local asg_arn
    asg_arn=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "${TEST_ID}-asg" --region "$REGION" \
        --query "AutoScalingGroups[0].AutoScalingGroupARN" --output text)

    echo "    Creating capacity provider: ${TEST_ID}-cp"
    aws ecs create-capacity-provider --name "${TEST_ID}-cp" \
        --auto-scaling-group-provider "autoScalingGroupArn=${asg_arn},managedScaling={status=ENABLED,targetCapacity=100},managedTerminationProtection=ENABLED" \
        --region "$REGION" >/dev/null

    aws ecs put-cluster-capacity-providers --cluster "$TEST_ID" \
        --capacity-providers "${TEST_ID}-cp" \
        --default-capacity-provider-strategy "capacityProvider=${TEST_ID}-cp,weight=1" \
        --region "$REGION" >/dev/null
}

verify_dcgm_init() {
    # Uses SSM Run Command to inspect the instance without SSH access.
    # Checks two things:
    #   1. dcgm-init systemd logs show "metrics written" (service is healthy)
    #   2. /var/run/ecs/gpu-metrics.json exists and contains GPU UUIDs
    echo "==> Verifying dcgm-init on instance $INSTANCE_ID..."

    local cmd_id
    cmd_id=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["journalctl -u dcgm-init --no-pager -n 5 2>&1; echo ===; cat /var/run/ecs/gpu-metrics.json 2>&1"]' \
        --region "$REGION" --query "Command.CommandId" --output text)

    # SSM commands take a few seconds to execute and return
    sleep 15

    local output
    output=$(aws ssm get-command-invocation --command-id "$cmd_id" \
        --instance-id "$INSTANCE_ID" --region "$REGION" \
        --query "StandardOutputContent" --output text)

    if echo "$output" | grep -q "metrics written"; then
        echo "    dcgm-init: HEALTHY (writing metrics)"
    else
        echo "    dcgm-init: WARNING - may not be writing metrics yet"
        echo "    Logs: $output"
    fi

    if echo "$output" | grep -q "gpu_uuid"; then
        echo "    GPU metrics file: PRESENT"
    else
        echo "    GPU metrics file: NOT FOUND - dcgm-init may be failing"
        echo "$output"
    fi

    # Check ACCELERATED_COMPUTE health status via describe-container-instances
    echo "==> Checking ACCELERATED_COMPUTE health status..."
    local ci_arn
    ci_arn=$(aws ecs list-container-instances --cluster "$TEST_ID" --region "$REGION" \
        --query "containerInstanceArns[0]" --output text 2>/dev/null)

    if [ -n "$ci_arn" ] && [ "$ci_arn" != "None" ]; then
        local health_output
        health_output=$(aws ecs describe-container-instances \
            --cluster "$TEST_ID" \
            --container-instances "$ci_arn" \
            --include CONTAINER_INSTANCE_HEALTH \
            --region "$REGION" \
            --query "containerInstances[0].healthStatus" --output json 2>/dev/null)

        local overall_status
        overall_status=$(echo "$health_output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('overallStatus','UNKNOWN'))" 2>/dev/null)
        echo "    Overall health status: $overall_status"

        # Display each health check detail
        echo "$health_output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
details = d.get('details', [])
if not details:
    print('    No health check details reported')
else:
    for detail in details:
        status_reason = detail.get('statusReason', '')
        reason_str = f' (reason: {status_reason})' if status_reason else ''
        print(f'    {detail[\"type\"]}: {detail[\"status\"]}{reason_str}')
        print(f'      Last updated: {detail.get(\"lastUpdated\", \"N/A\")}')
        print(f'      Last status change: {detail.get(\"lastStatusChange\", \"N/A\")}')
" 2>/dev/null

        # Highlight ACCELERATED_COMPUTE specifically
        local accel_status
        accel_status=$(echo "$health_output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for detail in d.get('details', []):
    if detail['type'] == 'ACCELERATED_COMPUTE':
        reason = detail.get('statusReason', '')
        reason_str = f' (reason: {reason})' if reason else ''
        print(f'{detail[\"status\"]}{reason_str}')
        sys.exit(0)
print('NOT_REPORTED')
" 2>/dev/null)

        if [ "$accel_status" = "NOT_REPORTED" ]; then
            echo "    ACCELERATED_COMPUTE: not reported by agent"
        else
            echo "    ACCELERATED_COMPUTE: $accel_status"
        fi
    else
        echo "    No container instance registered — cannot check health status"
    fi
}

ensure_task_definition() {
    # If the requested task definition already exists, use it as-is. Otherwise
    # register a gpu-burn task definition that burns the GPU for 120s then sleeps
    # for 120s in a continuous loop, and repoint TASK_DEFINITION at the new revision.
    echo "==> Checking task definition: $TASK_DEFINITION..."
    if aws ecs describe-task-definition --task-definition "$TASK_DEFINITION" \
        --region "$REGION" >/dev/null 2>&1; then
        echo "    Task definition $TASK_DEFINITION found"
        return 0
    fi

    echo "    Task definition $TASK_DEFINITION not found; registering a gpu-burn task definition..."

    # gpu_burn 120 burns the GPU for 120s; sleep 120 idles for 120s; loop forever.
    # No double quotes in this string so it embeds cleanly into the JSON below.
    local burn_cmd
    burn_cmd='apt-get update && apt-get install -y git build-essential && git clone https://github.com/wilicc/gpu-burn.git /gpu-burn && cd /gpu-burn && make && while true; do echo Starting GPU burn for 120s; ./gpu_burn 120; echo Sleeping for 120s; sleep 120; done'

    local container_defs
    container_defs=$(
        cat <<EOF
[
  {
    "name": "gpu-burn",
    "image": "nvidia/cuda:12.4.0-devel-ubuntu22.04",
    "cpu": 512,
    "memory": 4096,
    "essential": true,
    "resourceRequirements": [{"type": "GPU", "value": "1"}],
    "command": ["bash", "-c", "$burn_cmd"],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/gpu-burn-test",
        "awslogs-region": "$REGION",
        "awslogs-stream-prefix": "gpu-burn",
        "awslogs-create-group": "true"
      }
    }
  }
]
EOF
    )

    local new_td
    new_td=$(aws ecs register-task-definition \
        --family gpu-burn-test \
        --container-definitions "$container_defs" \
        --region "$REGION" \
        --query "taskDefinition.taskDefinitionArn" --output text 2>&1) ||
        die "Failed to register task definition: $new_td"

    # Convert the returned ARN (.../gpu-burn-test:N) into the family:revision form
    TASK_DEFINITION=$(basename "$new_td")
    echo "    Registered task definition: $TASK_DEFINITION"
}

deploy_task() {
    # Make sure the task definition exists (register one if needed) before
    # creating the service.
    ensure_task_definition

    echo "==> Deploying ECS service with task definition: $TASK_DEFINITION..."

    # When using an ASG, schedule via its capacity provider; otherwise use the
    # EC2 launch type to place tasks on the directly-launched instance.
    if [ "$USE_ASG" = true ]; then
        aws ecs create-service --cluster "$TEST_ID" \
            --service-name gpu-burn-service \
            --task-definition "$TASK_DEFINITION" \
            --desired-count 1 \
            --capacity-provider-strategy "capacityProvider=${TEST_ID}-cp,weight=1" \
            --deployment-configuration "minimumHealthyPercent=0,maximumPercent=200" \
            --region "$REGION" >/dev/null
    else
        aws ecs create-service --cluster "$TEST_ID" \
            --service-name gpu-burn-service \
            --task-definition "$TASK_DEFINITION" \
            --desired-count 1 \
            --launch-type EC2 \
            --deployment-configuration "minimumHealthyPercent=0,maximumPercent=200" \
            --region "$REGION" >/dev/null
    fi

    # Wait for task to be running
    echo "    Waiting for task to start running..."
    local task_attempts=0
    while [ $task_attempts -lt 24 ]; do
        local running
        running=$(aws ecs describe-services --cluster "$TEST_ID" \
            --services gpu-burn-service --region "$REGION" \
            --query "services[0].runningCount" --output text)
        if [ "$running" -gt 0 ] 2>/dev/null; then
            echo "    Task is RUNNING"
            return 0
        fi
        sleep 10
        task_attempts=$((task_attempts + 1))
    done

    die "Task failed to start running within 4 minutes"
}

instance_gpu_metric_has_dimension_set() {
    # Returns 0 if the given instance-level GPU metric name is published under a
    # dimension set that contains ALL of the requested dimension keys for this
    # cluster. Used to distinguish the cluster-level rollup ({ClusterName}) from
    # the per-instance breakdown ({ClusterName, CapacityProviderName,
    # ContainerInstanceId, EC2InstanceId}) that the Container Insights console
    # GPU-per-instance view renders.
    #
    # Args: $1 = metric name, $2..$n = required dimension key names.
    local metric_name="$1"
    shift
    local required_keys=("$@")

    aws cloudwatch list-metrics --namespace "ECS/ContainerInsights" \
        --region "$REGION" --metric-name "$metric_name" \
        --dimensions "Name=ClusterName,Value=$TEST_ID" \
        --query "Metrics[].Dimensions" --output json 2>/dev/null |
        REQUIRED_KEYS="${required_keys[*]}" python3 -c "
import json, os, sys
required = set(os.environ['REQUIRED_KEYS'].split())
try:
    dim_sets = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for dims in dim_sets:
    keys = {d['Name'] for d in dims}
    if required.issubset(keys):
        sys.exit(0)
sys.exit(1)
"
}

verify_cloudwatch_metrics() {
    # Polls CloudWatch until GPU metrics appear under the ECS/ContainerInsights
    # namespace for our cluster. The test passes only when ALL THREE of these hold:
    #   1. Container-level GPU metrics (>= 7: the ContainerGPU* set)
    #   2. Instance-level metrics (InstanceGPULimit, InstanceGPUUsageTotal) under
    #      the cluster-level dimension set {ClusterName}
    #   3. Those same instance-level metrics under the per-instance dimension set
    #      {ClusterName, CapacityProviderName, ContainerInstanceId, EC2InstanceId}
    #      — the set the Container Insights console GPU-per-instance view renders.
    #      This only appears once the capacity-provider association propagates
    #      into the telemetry backend (can lag several minutes after registration).
    # CloudWatch can take 3-5 minutes after metrics are first emitted by the agent
    # before they're queryable via API.
    refresh_credentials
    echo "==> Waiting for GPU metrics in CloudWatch (timeout: ${TIMEOUT}s)..."

    # Resolve this instance's ContainerInstanceId + EC2InstanceId so we can assert
    # the per-instance dimension set is actually populated (not just present).
    local ci_arn ci_id ec2_id
    ci_arn=$(aws ecs list-container-instances --cluster "$TEST_ID" --region "$REGION" \
        --query "containerInstanceArns[0]" --output text 2>/dev/null)
    ci_id=$(basename "$ci_arn" 2>/dev/null)
    ec2_id=$(aws ecs describe-container-instances --cluster "$TEST_ID" \
        --container-instances "$ci_arn" --region "$REGION" \
        --query "containerInstances[0].ec2InstanceId" --output text 2>/dev/null)
    echo "    ContainerInstanceId=$ci_id  EC2InstanceId=$ec2_id  CapacityProvider=${TEST_ID}-cp"

    local elapsed=0
    local check_interval=30

    while [ $elapsed -lt "$TIMEOUT" ]; do
        # Query all metric names for this cluster and filter for GPU-related ones
        local gpu_metrics
        gpu_metrics=$(aws cloudwatch list-metrics --namespace "ECS/ContainerInsights" \
            --region "$REGION" --dimensions "Name=ClusterName,Value=$TEST_ID" \
            --query "Metrics[].MetricName" --output json 2>/dev/null |
            python3 -c "import json,sys; names=json.load(sys.stdin); gpu=[n for n in names if 'GPU' in n]; print('\n'.join(gpu))" 2>/dev/null)

        local container_count
        container_count=$(echo "$gpu_metrics" | grep -c "^Container.*GPU" || true)

        # Cluster-level instance metrics: present under {ClusterName}.
        local instance_cluster_ok=false
        if echo "$gpu_metrics" | grep -q "^InstanceGPULimit$" &&
            echo "$gpu_metrics" | grep -q "^InstanceGPUUsageTotal$"; then
            instance_cluster_ok=true
        fi

        # Per-instance dimension set (the console GPU-per-instance view).
        local instance_perinstance_ok=false
        if instance_gpu_metric_has_dimension_set "InstanceGPULimit" \
            ClusterName CapacityProviderName ContainerInstanceId EC2InstanceId &&
            instance_gpu_metric_has_dimension_set "InstanceGPUUsageTotal" \
                ClusterName CapacityProviderName ContainerInstanceId EC2InstanceId; then
            instance_perinstance_ok=true
        fi

        # 7 = minimum container-level GPU metrics (utilization, memory total/used/util,
        # power, temperature, xid count)
        if [ "$container_count" -ge 7 ] && [ "$instance_cluster_ok" = true ] && [ "$instance_perinstance_ok" = true ]; then
            echo ""
            echo "==> GPU METRICS FOUND (container=$container_count, plus instance-level at cluster + per-instance):"
            echo "$gpu_metrics" | sort -u | sed 's/^/      /'
            echo ""

            # Container-level data points
            local datapoints
            datapoints=$(aws cloudwatch get-metric-statistics \
                --namespace "ECS/ContainerInsights" \
                --metric-name "ContainerGPUUtilization" \
                --dimensions "Name=ClusterName,Value=$TEST_ID" \
                --start-time "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S)" \
                --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
                --period 60 --statistics Average --region "$REGION" \
                --query "Datapoints[*].[Timestamp,Average]" --output text 2>/dev/null)
            if [ -n "$datapoints" ]; then
                echo "    ContainerGPUUtilization data points:"
                echo "$datapoints" | sort | tail -5 | while read -r ts val; do
                    echo "      $ts: ${val}%"
                done
            fi

            # Instance-level data points, per-instance dimension set.
            local mn
            for mn in InstanceGPULimit InstanceGPUUsageTotal; do
                local idp
                idp=$(aws cloudwatch get-metric-statistics \
                    --namespace "ECS/ContainerInsights" \
                    --metric-name "$mn" \
                    --dimensions "Name=ClusterName,Value=$TEST_ID" \
                    "Name=CapacityProviderName,Value=${TEST_ID}-cp" \
                    "Name=ContainerInstanceId,Value=$ci_id" \
                    "Name=EC2InstanceId,Value=$ec2_id" \
                    --start-time "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S)" \
                    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
                    --period 60 --statistics Maximum --region "$REGION" \
                    --query "Datapoints[*].[Timestamp,Maximum]" --output text 2>/dev/null)
                echo "    $mn (per-instance) data points:"
                if [ -n "$idp" ]; then
                    echo "$idp" | sort | tail -3 | while read -r ts val; do
                        echo "      $ts: ${val}"
                    done
                else
                    echo "      (none yet)"
                fi
            done

            echo ""
            echo "========================================="
            echo "  TEST PASSED: GPU metrics are emitting"
            echo "    - container-level: $container_count metrics"
            echo "    - instance-level (cluster dim): InstanceGPULimit, InstanceGPUUsageTotal"
            echo "    - instance-level (per-instance dim): InstanceGPULimit, InstanceGPUUsageTotal"
            echo "========================================="
            return 0
        fi

        echo "    [$elapsed/${TIMEOUT}s] container=$container_count/7, instance@cluster=$instance_cluster_ok, instance@per-instance=$instance_perinstance_ok — waiting..."
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done

    echo ""
    echo "========================================="
    echo "  TEST FAILED: GPU metrics not fully emitting"
    echo "    container>=7:            $([ "$container_count" -ge 7 ] 2>/dev/null && echo yes || echo no)"
    echo "    instance @ cluster dim:  $instance_cluster_ok"
    echo "    instance @ per-instance: $instance_perinstance_ok"
    echo "========================================="
    echo ""
    echo "Diagnostics:"
    verify_dcgm_init
    return 1
}

main() {
    parse_args "$@"

    # If --delete-cluster is given, run deletion and exit immediately
    if [ -n "$DELETE_CLUSTER_NAME" ]; then
        refresh_credentials
        delete_cluster "$DELETE_CLUSTER_NAME"
        exit 0
    fi

    local provision_mode="direct EC2 launch (no ASG)"
    [ "$USE_ASG" = true ] && provision_mode="ASG + capacity provider"

    echo "==========================================="
    echo "  GPU Metrics E2E Test"
    echo "  Test ID: $TEST_ID"
    echo "  Region: $REGION"
    echo "  Instance Type: $INSTANCE_TYPE"
    echo "  Provisioning: $provision_mode"
    echo "==========================================="
    echo ""

    # Register cleanup handler — runs on EXIT regardless of success/failure
    trap cleanup EXIT

    refresh_credentials       # Step 1: Ensure AWS creds are valid
    build_rpm                 # Step 2: Build ecs-init RPM (includes dcgm-init)
    build_ami                 # Step 3: Build AL2023 GPU AMI with Packer
    setup_infrastructure      # Step 4: Create ECS cluster + provision instance (direct or ASG)
    verify_dcgm_init          # Step 5: Confirm dcgm-init is writing metrics on host
    deploy_task               # Step 6: Run GPU-intensive workload as ECS service
    verify_cloudwatch_metrics # Step 7: Poll CloudWatch until GPU metrics appear
}

main "$@"
