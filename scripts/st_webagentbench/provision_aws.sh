#!/usr/bin/env bash
# ========= Copyright 2023-2026 @ CAMEL-AI.org. All Rights Reserved. =========
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# See the License for the specific language governing permissions and
# limitations in the License.
# ========= Copyright 2023-2026 @ CAMEL-AI.org. All Rights Reserved. =========
#
# Provision ST-WebAgentBench on AWS in one script.
# Launches WebArena AMI, configures GitLab + ShoppingAdmin, optionally SuiteCRM.
# Use provision_aws_teardown.sh to shut down when done.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Region is us-east-2 (Ohio); override via AWS_REGION env var.
REGION="${AWS_REGION:-us-east-2}"
AMI_ID="ami-06290d70feea35450"
INSTANCE_TYPE="${STWEBAGENTBENCH_INSTANCE_TYPE:-t3a.xlarge}"
TAG_NAME="${STWEBAGENTBENCH_TAG:-st-webagentbench}"
SG_NAME="st-webagentbench-sg"
KEY_NAME=""
KEY_FILE=""
DRY_RUN=false
RUNNING_INSTANCES=false
SHOPADMIN=false
GITLAB=false
SUITECRM=false
SUITECRM_INSTANCE_TYPE="${STWEBAGENTBENCH_SUITECRM_INSTANCE_TYPE:-t3a.small}"
GITLAB_INSTANCE_TYPE="${STWEBAGENTBENCH_GITLAB_INSTANCE_TYPE:-t3a.medium}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat << EOF
Usage: $(basename "$0") --key-name NAME [OPTIONS]

Provision ST-WebAgentBench on AWS: launch WebArena AMI, configure services, expose URLs.

Required:
  --key-name NAME     AWS EC2 key pair name (must exist in region $REGION)

Options:
  --key-file PATH     Path to private key for SSH (default: ~/.ssh/<key-name>.pem)
  --instance-type T   Instance type for main/Magento instance (default: $INSTANCE_TYPE)
  --tag NAME         Tag for teardown (default: $TAG_NAME)
  --all              Provision all apps (Magento + GitLab + SuiteCRM on separate instances)
  --shopadmin        Provision Magento stack (shopping, shopping_admin, forum, kiwix)
  --gitlab           Provision GitLab on its own instance
  --suitecrm         Provision SuiteCRM on its own instance
  --suitecrm-instance-type T  Instance type for SuiteCRM (default: $SUITECRM_INSTANCE_TYPE)
  --gitlab-instance-type T    Instance type for GitLab (default: $GITLAB_INSTANCE_TYPE)
  --dry-run          Show what would be done without provisioning
  --running-instances  List all running ST-WebAgentBench instances in table format (no provision)
  -h, --help          Show this help

Environment:
  STWEBAGENTBENCH_VPC_ID   VPC ID for security group (default: auto-detect)
  STWEBAGENTBENCH_INSTANCE_TYPE  Instance type (default: t3a.xlarge)
  STWEBAGENTBENCH_SUITECRM_INSTANCE_TYPE  Instance type for separate SuiteCRM (default: t3a.small)
  STWEBAGENTBENCH_GITLAB_INSTANCE_TYPE    Instance type for GitLab (default: t3a.medium)

Prerequisites:
  - AWS CLI installed and configured (aws configure)
  - EC2 key pair created in the target region
  - Sufficient EC2/Elastic IP quota

Teardown:
  ./provision_aws_teardown.sh --tag $TAG_NAME
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key-name)   KEY_NAME="$2"; shift 2 ;;
        --key-file)   KEY_FILE="$2"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --tag)        TAG_NAME="$2"; shift 2 ;;
        --all) SHOPADMIN=true; GITLAB=true; SUITECRM=true; shift ;;
        --shopadmin) SHOPADMIN=true; shift ;;
        --gitlab) GITLAB=true; shift ;;
        --suitecrm) SUITECRM=true; shift ;;
        --suitecrm-instance-type) SUITECRM_INSTANCE_TYPE="$2"; shift 2 ;;
        --gitlab-instance-type) GITLAB_INSTANCE_TYPE="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --running-instances) RUNNING_INSTANCES=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "$KEY_NAME" ]] && [[ "$RUNNING_INSTANCES" != "true" ]]; then
    log_error "Missing required --key-name"
    usage
    exit 1
fi

# --running-instances: list running apps and exit (no key-name needed)
if [[ "$RUNNING_INSTANCES" == "true" ]]; then
    if ! command -v aws &>/dev/null; then
        log_error "AWS CLI required. Install: https://aws.amazon.com/cli/"
        exit 1
    fi
    log_info "Running ST-WebAgentBench instances (tag=$TAG_NAME, region=$REGION):"
    aws ec2 describe-instances --region "$REGION" \
        --filters "Name=tag:$TAG_NAME,Values=benchmark,gitlab,suitecrm" "Name=instance-state-name,Values=running" \
        --query 'Reservations[*].Instances[*].{InstanceId:InstanceId,App:Tags[?Key==`'"$TAG_NAME"'`].Value|[0],State:State.Name,PublicIP:PublicIpAddress,Type:InstanceType}' \
        --output table
    exit 0
fi

# Default to --all when no app flags specified
if [[ "$SHOPADMIN" != "true" && "$GITLAB" != "true" && "$SUITECRM" != "true" ]]; then
    SHOPADMIN=true
    GITLAB=true
    SUITECRM=true
fi

# When GitLab is separate, downsize main (Magento) instance to t3a.medium unless user overrides
if [[ "$GITLAB" == "true" && "$INSTANCE_TYPE" == "t3a.xlarge" ]]; then
    INSTANCE_TYPE="t3a.medium"
fi

KEY_FILE="${KEY_FILE:-$HOME/.ssh/${KEY_NAME}.pem}"
if [[ ! -f "$KEY_FILE" ]] && [[ "$DRY_RUN" != "true" ]]; then
    log_error "Key file not found: $KEY_FILE"
    exit 1
fi

if ! command -v aws &>/dev/null; then
    log_error "AWS CLI required. Install: https://aws.amazon.com/cli/"
    exit 1
fi

# Resolve VPC (default or first available; override via STWEBAGENTBENCH_VPC_ID)
get_vpc() {
    local vpc_id
    vpc_id=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=is-default,Values=true" \
        --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)
    if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
        vpc_id=$(aws ec2 describe-vpcs --region "$REGION" --query 'Vpcs[0].VpcId' --output text)
    fi
    echo "$vpc_id"
}

# Resolve subnet (default VPC, first available subnet)
get_subnet() {
    local vpc_id="${1:-$(get_vpc)}"
    aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$vpc_id" "Name=map-public-ip-on-launch,Values=true" \
        --query 'Subnets[0].SubnetId' --output text
}

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would provision in $REGION with key $KEY_NAME"
    exit 0
fi

# Ensure network (VPC, SG, subnet) for any instance creation
VPC_ID="${STWEBAGENTBENCH_VPC_ID:-$(get_vpc)}"
log_info "Using VPC $VPC_ID"
SG_ID=$(aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC_ID" \
    --group-name "$SG_NAME" --description "ST-WebAgentBench: GitLab, Magento, SuiteCRM" \
    --output text 2>/dev/null) || true
if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[0].GroupId' --output text)
    [[ -z "$SG_ID" || "$SG_ID" == "None" ]] && { log_error "Could not create or find security group"; exit 1; }
    log_info "Using existing security group $SG_ID"
fi
for port in 22 80 3000 7770 7780 8023 8081 8888 9999; do
    aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
        --protocol tcp --port "$port" --cidr 0.0.0.0/0 2>/dev/null || true
done
SUBNET_ID=$(get_subnet "$VPC_ID")

#
# Main instance (Magento stack) - only when --shopadmin
#
INSTANCE_ID=""
INSTANCE_STATE=""
PUBLIC_IP=""
HOSTNAME=""

if [[ "$SHOPADMIN" == "true" ]]; then
EXISTING_DESC=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:$TAG_NAME,Values=benchmark" \
              "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[0].Instances[0].[InstanceId,State.Name,PublicIpAddress]' \
    --output text 2>/dev/null || true)

INSTANCE_ID=""
INSTANCE_STATE=""
PUBLIC_IP=""

if [[ -n "$EXISTING_DESC" && "$EXISTING_DESC" != "None" ]]; then
    read -r INSTANCE_ID INSTANCE_STATE PUBLIC_IP <<< "$EXISTING_DESC"
    log_info "Found existing main instance $INSTANCE_ID (state: $INSTANCE_STATE)"
    if [[ "$INSTANCE_STATE" != "running" ]]; then
        log_info "Starting existing instance $INSTANCE_ID..."
        aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
    fi
else
    MAIN_EBS_SIZE=1000
    [[ "$GITLAB" == "true" ]] && MAIN_EBS_SIZE=400
    log_info "Launching main instance from WebArena AMI $AMI_ID (${INSTANCE_TYPE}, ${MAIN_EBS_SIZE}GB)..."
    INSTANCE_ID=$(aws ec2 run-instances \
        --region "$REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --subnet-id "$SUBNET_ID" \
        --security-group-ids "$SG_ID" \
        --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${MAIN_EBS_SIZE}}}]" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=$TAG_NAME,Value=benchmark}]" \
        --query 'Instances[0].InstanceId' --output text)
    log_info "Created main instance: $INSTANCE_ID"
fi

if [[ -n "$INSTANCE_ID" ]]; then
log_info "Waiting for main instance $INSTANCE_ID to be running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

# Ensure we have a public IP (reuse existing Elastic IP association if present).
if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == "None" ]]; then
    PUBLIC_IP=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text 2>/dev/null || true)
fi

if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == "None" ]]; then
    log_info "Allocating Elastic IP for instance $INSTANCE_ID..."
    ALLOC_ID=$(aws ec2 allocate-address --region "$REGION" --domain vpc --query 'AllocationId' --output text)
    PUBLIC_IP=$(aws ec2 describe-addresses --region "$REGION" --allocation-ids "$ALLOC_ID" \
        --query 'Addresses[0].PublicIp' --output text)
    log_info "Associating Elastic IP $PUBLIC_IP with instance..."
    aws ec2 associate-address --region "$REGION" --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" >/dev/null
fi

# Hostname for config (use IP if no reverse DNS)
HOSTNAME="${PUBLIC_IP}"
log_info "Hostname: $HOSTNAME"

log_info "Waiting for SSH (up to 120s)..."
for i in $(seq 1 24); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        -i "$KEY_FILE" "ubuntu@$HOSTNAME" "echo ok" 2>/dev/null; then
        break
    fi
    [[ $i -eq 24 ]] && { log_error "SSH timeout"; exit 1; }
    sleep 5
done

run_ssh() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -i "$KEY_FILE" "ubuntu@$HOSTNAME" "$@"
}

log_info "Starting WebArena Docker services (only selected apps)..."
# --shopadmin: Magento stack (shopping, shopping_admin, forum, kiwix). GitLab only when --gitlab (separate instance).
run_ssh "docker start shopping shopping_admin forum kiwix33 2>/dev/null || true"
if [[ "$GITLAB" == "true" ]]; then
    log_info "Skipping GitLab on main (will run on separate instance)"
    # OpenStreetMap only when doing full setup (--gitlab)
fi
if [[ "$GITLAB" == "true" ]] && run_ssh "test -d /home/ubuntu/openstreetmap-website" 2>/dev/null; then
    run_ssh "cd /home/ubuntu/openstreetmap-website && docker compose start 2>/dev/null || true"
fi
log_info "Waiting 60s for Magento/services to start..."
sleep 60

log_info "Configuring base URLs for hostname $HOSTNAME..."
run_ssh "docker exec shopping /var/www/magento2/bin/magento setup:store-config:set --base-url=\"http://${HOSTNAME}:7770\" 2>/dev/null || true"
run_ssh "docker exec shopping mysql -u magentouser -pMyPassword magentodb -e \"UPDATE core_config_data SET value='http://${HOSTNAME}:7770/' WHERE path = 'web/secure/base_url';\" 2>/dev/null || true"
run_ssh "docker exec shopping_admin php /var/www/magento2/bin/magento config:set admin/security/password_is_forced 0 2>/dev/null || true"
run_ssh "docker exec shopping_admin php /var/www/magento2/bin/magento config:set admin/security/password_lifetime 0 2>/dev/null || true"
run_ssh "docker exec shopping /var/www/magento2/bin/magento cache:flush 2>/dev/null || true"
run_ssh "docker exec shopping_admin /var/www/magento2/bin/magento setup:store-config:set --base-url=\"http://${HOSTNAME}:7780\" 2>/dev/null || true"
run_ssh "docker exec shopping_admin mysql -u magentouser -pMyPassword magentodb -e \"UPDATE core_config_data SET value='http://${HOSTNAME}:7780/' WHERE path = 'web/secure/base_url';\" 2>/dev/null || true"
run_ssh "docker exec shopping_admin /var/www/magento2/bin/magento cache:flush 2>/dev/null || true"

GITLAB_URL_VAL=""
# GitLab runs only on separate instance (--gitlab), never on main
if false; then
    log_info "Waiting for GitLab PostgreSQL to be ready (up to 5 min)..."
    GITLAB_READY=false
    for i in $(seq 1 20); do
        if run_ssh "docker exec gitlab gitlab-ctl status 2>/dev/null | grep -qE '^run: postgresql:'"; then
            GITLAB_READY=true
            log_info "GitLab PostgreSQL is ready"
            break
        fi
        [[ $i -eq 20 ]] && log_warn "GitLab PostgreSQL not ready after 5 min; reconfigure may fail"
        sleep 15
    done

    run_ssh "docker exec gitlab sed -i \"s|^external_url.*|external_url 'http://${HOSTNAME}:8023'|\" /etc/gitlab/gitlab.rb 2>/dev/null || true"
    for attempt in 1 2 3; do
        log_info "Running gitlab-ctl reconfigure (attempt $attempt/3)..."
        if run_ssh "docker exec gitlab gitlab-ctl reconfigure"; then
            log_info "GitLab reconfigure succeeded"
            break
        fi
        if [[ $attempt -lt 3 ]]; then
            log_warn "GitLab reconfigure failed, waiting 90s before retry..."
            sleep 90
        else
            log_warn "GitLab reconfigure failed after 3 attempts. GitLab may still work; run manually: docker exec gitlab gitlab-ctl reconfigure"
        fi
    done
    GITLAB_URL_VAL="http://${HOSTNAME}:8023"
fi

# iptables redirect if services not accessible (per WebArena README)
run_ssh "sudo iptables -t nat -A PREROUTING -p tcp --dport 7770 -j REDIRECT --to-port 7770 2>/dev/null || true"
run_ssh "sudo iptables -t nat -A PREROUTING -p tcp --dport 7780 -j REDIRECT --to-port 7780 2>/dev/null || true"
# Port 8023 (GitLab) only needed when GitLab runs on main - we use separate instance (--gitlab)
fi
fi

# GitLab on separate instance (when --gitlab)
if [[ "$GITLAB" == "true" ]]; then
    EXISTING_GITLAB=$(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=tag:$TAG_NAME,Values=gitlab" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[0].Instances[0].[InstanceId,State.Name,PublicIpAddress]' --output text 2>/dev/null || true)
    if [[ -n "$EXISTING_GITLAB" && "$EXISTING_GITLAB" != "None" ]]; then
        read -r GITLAB_INSTANCE_ID GITLAB_STATE GITLAB_PUBLIC_IP <<< "$EXISTING_GITLAB"
        log_info "Found existing GitLab instance $GITLAB_INSTANCE_ID (state: $GITLAB_STATE)"
        if [[ "$GITLAB_STATE" != "running" ]]; then
            aws ec2 start-instances --region "$REGION" --instance-ids "$GITLAB_INSTANCE_ID" >/dev/null
            aws ec2 wait instance-running --region "$REGION" --instance-ids "$GITLAB_INSTANCE_ID"
            GITLAB_PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$GITLAB_INSTANCE_ID" \
                --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
        fi
        GITLAB_URL_VAL="http://${GITLAB_PUBLIC_IP}:8023"
    else
    log_info "Provisioning GitLab on separate instance (${GITLAB_INSTANCE_TYPE})..."
    GITLAB_INSTANCE_ID=$(aws ec2 run-instances \
        --region "$REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$GITLAB_INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --subnet-id "$SUBNET_ID" \
        --security-group-ids "$SG_ID" \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":1000}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=$TAG_NAME,Value=gitlab}]" \
        --query 'Instances[0].InstanceId' --output text)
    log_info "Created GitLab instance: $GITLAB_INSTANCE_ID"
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$GITLAB_INSTANCE_ID"
    GITLAB_PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$GITLAB_INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || true)
    if [[ -z "$GITLAB_PUBLIC_IP" || "$GITLAB_PUBLIC_IP" == "None" ]]; then
        log_info "Allocating Elastic IP for GitLab instance..."
        GITLAB_ALLOC=$(aws ec2 allocate-address --region "$REGION" --domain vpc --query 'AllocationId' --output text)
        GITLAB_PUBLIC_IP=$(aws ec2 describe-addresses --region "$REGION" --allocation-ids "$GITLAB_ALLOC" \
            --query 'Addresses[0].PublicIp' --output text)
        aws ec2 associate-address --region "$REGION" --instance-id "$GITLAB_INSTANCE_ID" --allocation-id "$GITLAB_ALLOC" >/dev/null
    fi
    log_info "Waiting for GitLab instance SSH (up to 180s - large AMI)..."
    for i in $(seq 1 36); do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
            -i "$KEY_FILE" "ubuntu@$GITLAB_PUBLIC_IP" "echo ok" 2>/dev/null; then
            break
        fi
        [[ $i -eq 36 ]] && { log_error "GitLab instance SSH timeout"; exit 1; }
        sleep 5
    done
    run_gitlab_ssh() {
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 -i "$KEY_FILE" "ubuntu@$GITLAB_PUBLIC_IP" "$@"
    }
    log_info "Starting GitLab on separate instance..."
    run_gitlab_ssh "docker start gitlab 2>/dev/null || true"
    log_info "Waiting 120s for GitLab to start..."
    sleep 120
    log_info "Waiting for GitLab PostgreSQL (up to 5 min)..."
    for i in $(seq 1 20); do
        if run_gitlab_ssh "docker exec gitlab gitlab-ctl status 2>/dev/null | grep -qE '^run: postgresql:'"; then
            log_info "GitLab PostgreSQL is ready"
            break
        fi
        [[ $i -eq 20 ]] && log_warn "GitLab PostgreSQL not ready after 5 min"
        sleep 15
    done
    run_gitlab_ssh "docker exec gitlab sed -i \"s|^external_url.*|external_url 'http://${GITLAB_PUBLIC_IP}:8023'|\" /etc/gitlab/gitlab.rb 2>/dev/null || true"
    for attempt in 1 2 3; do
        log_info "Running gitlab-ctl reconfigure on GitLab instance (attempt $attempt/3)..."
        if run_gitlab_ssh "docker exec gitlab gitlab-ctl reconfigure"; then
            log_info "GitLab reconfigure succeeded"
            break
        fi
        [[ $attempt -lt 3 ]] && { log_warn "Waiting 90s before retry..."; sleep 90; }
    done
    run_gitlab_ssh "sudo iptables -t nat -A PREROUTING -p tcp --dport 8023 -j REDIRECT --to-port 8023 2>/dev/null || true"
    GITLAB_URL_VAL="http://${GITLAB_PUBLIC_IP}:8023"
    log_info "GitLab running at $GITLAB_URL_VAL"
    fi
fi
GITLAB_URL_FINAL="${GITLAB_URL_VAL}"

SUITECRM_URL=""
if [[ "$SUITECRM" != "true" ]]; then
    log_warn "SuiteCRM skipped. Use --suitecrm or --all to provision SuiteCRM."
elif [[ "$SUITECRM" == "true" ]]; then
    EXISTING_SUITECRM=$(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=tag:$TAG_NAME,Values=suitecrm" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[0].Instances[0].[InstanceId,State.Name,PublicIpAddress]' --output text 2>/dev/null || true)
    if [[ -n "$EXISTING_SUITECRM" && "$EXISTING_SUITECRM" != "None" ]]; then
        read -r SUITECRM_INSTANCE_ID SUITECRM_STATE SUITECRM_PUBLIC_IP <<< "$EXISTING_SUITECRM"
        log_info "Found existing SuiteCRM instance $SUITECRM_INSTANCE_ID (state: $SUITECRM_STATE)"
        if [[ "$SUITECRM_STATE" != "running" ]]; then
            aws ec2 start-instances --region "$REGION" --instance-ids "$SUITECRM_INSTANCE_ID" >/dev/null
            aws ec2 wait instance-running --region "$REGION" --instance-ids "$SUITECRM_INSTANCE_ID"
            SUITECRM_PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$SUITECRM_INSTANCE_ID" \
                --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
        fi
        SUITECRM_URL="http://${SUITECRM_PUBLIC_IP}:8081"
    else
    log_info "Provisioning SuiteCRM on separate instance (${SUITECRM_INSTANCE_TYPE})..."
    SUITECRM_AMI=$(aws ec2 describe-images --region "$REGION" --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=state,Values=available" \
        --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text 2>/dev/null || echo "ami-0a2f69c61c8d44c6e")
    SUITECRM_INSTANCE_ID=$(aws ec2 run-instances \
        --region "$REGION" \
        --image-id "$SUITECRM_AMI" \
        --instance-type "$SUITECRM_INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --subnet-id "$SUBNET_ID" \
        --security-group-ids "$SG_ID" \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=$TAG_NAME,Value=suitecrm}]" \
        --query 'Instances[0].InstanceId' --output text)
    log_info "Created SuiteCRM instance: $SUITECRM_INSTANCE_ID"
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$SUITECRM_INSTANCE_ID"
    SUITECRM_PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$SUITECRM_INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || true)
    if [[ -z "$SUITECRM_PUBLIC_IP" || "$SUITECRM_PUBLIC_IP" == "None" ]]; then
        log_info "Allocating Elastic IP for SuiteCRM instance..."
        SUITECRM_ALLOC=$(aws ec2 allocate-address --region "$REGION" --domain vpc --query 'AllocationId' --output text)
        SUITECRM_PUBLIC_IP=$(aws ec2 describe-addresses --region "$REGION" --allocation-ids "$SUITECRM_ALLOC" \
            --query 'Addresses[0].PublicIp' --output text)
        aws ec2 associate-address --region "$REGION" --instance-id "$SUITECRM_INSTANCE_ID" --allocation-id "$SUITECRM_ALLOC" >/dev/null
    fi
    log_info "Waiting for SuiteCRM instance SSH (up to 120s)..."
    for i in $(seq 1 24); do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
            -i "$KEY_FILE" "ubuntu@$SUITECRM_PUBLIC_IP" "echo ok" 2>/dev/null; then
            break
        fi
        [[ $i -eq 24 ]] && { log_error "SuiteCRM instance SSH timeout"; exit 1; }
        sleep 5
    done
    run_suitecrm_ssh() {
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 -i "$KEY_FILE" "ubuntu@$SUITECRM_PUBLIC_IP" "$@"
    }
    log_info "Installing Docker and starting SuiteCRM on separate instance..."
    run_suitecrm_ssh "sudo apt-get update -qq && sudo apt-get install -y -qq docker.io 2>/dev/null || true"
    run_suitecrm_ssh "sudo systemctl start docker 2>/dev/null || true"
    run_suitecrm_ssh "sudo usermod -aG docker ubuntu 2>/dev/null || true"
    run_suitecrm_ssh "sudo docker run -d --name st-webagentbench-mariadb --restart unless-stopped \
        -e MARIADB_ROOT_PASSWORD=root -e MARIADB_DATABASE=bitnami_suitecrm \
        -e MARIADB_USER=bn_suitecrm -e MARIADB_PASSWORD=bitnami \
        bitnami/mariadb:latest 2>/dev/null || sudo docker start st-webagentbench-mariadb 2>/dev/null || true"
    sleep 15
    run_suitecrm_ssh "sudo docker run -d --name st-webagentbench-suitecrm --restart unless-stopped -p 8081:8080 \
        --link st-webagentbench-mariadb:mariadb \
        -e SUITECRM_USERNAME=admin -e SUITECRM_PASSWORD=bitnami -e MARIADB_HOST=mariadb \
        bitnami/suitecrm:latest 2>/dev/null || sudo docker start st-webagentbench-suitecrm 2>/dev/null || true"
    SUITECRM_URL="http://${SUITECRM_PUBLIC_IP}:8081"
    log_info "SuiteCRM running at $SUITECRM_URL (admin/bitnami). May take 1-2 min to be ready."
    fi
fi

# Use SUITECRM_URL or fallback for .env
SUITECRM_URL_FINAL="${SUITECRM_URL:-}"
[[ -z "$SUITECRM_URL_FINAL" && -n "$HOSTNAME" ]] && SUITECRM_URL_FINAL="http://${HOSTNAME}:8081"
SHOPPING_ADMIN_URL_VAL=""
[[ -n "$HOSTNAME" ]] && SHOPPING_ADMIN_URL_VAL="http://${HOSTNAME}:7780/admin"
ENV_FILE="$SCRIPT_DIR/.env.provisioned"
cat > "$ENV_FILE" << ENVEOF
# ST-WebAgentBench AWS provisioned - $(date +%Y-%m-%dT%H:%M:%S)

GITLAB_URL=${GITLAB_URL_FINAL}
SHOPPING_ADMIN_URL=${SHOPPING_ADMIN_URL_VAL}
SUITECRM_URL=${SUITECRM_URL_FINAL}

# Copy to .env and add OPENAI_API_KEY, credentials:
# cp $ENV_FILE .env
ENVEOF

log_info ""
log_info "=== Provisioning complete ==="
[[ -n "$INSTANCE_ID" ]] && log_info "Main instance: $INSTANCE_ID (${HOSTNAME})"
log_info ""
log_info "Add to your .env:"
log_info "  GITLAB_URL=${GITLAB_URL_FINAL}"
log_info "  SHOPPING_ADMIN_URL=${SHOPPING_ADMIN_URL_VAL}"
log_info "  SUITECRM_URL=${SUITECRM_URL_FINAL}"
log_info ""
log_info "Config saved to: $ENV_FILE"
log_info "Teardown: ./provision_aws_teardown.sh --tag $TAG_NAME"
