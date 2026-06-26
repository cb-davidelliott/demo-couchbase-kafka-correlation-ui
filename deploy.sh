#!/usr/bin/env bash
# ==============================================================================
# Deploy Script (macOS/Linux)
# Couchbase Capella + Kafka + OpenTelemetry Demo Project
# ==============================================================================

set -euo pipefail

# Print with styling
log_info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $*"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

# 1. Verify Prerequisites
log_info "Verifying prerequisites..."
for cmd in git az terraform; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Missing prerequisite command: $cmd. Please install it before proceeding."
    fi
done
log_success "Prerequisites verified."

# 2. Check for .env file
if [ ! -f .env ]; then
    log_info "Copying .env.example to .env..."
    cp .env.example .env
    log_info "Please edit .env with your Azure and Couchbase Capella details, then re-run this script."
    exit 0
fi

# Load environment variables
# Exclude commented lines and empty lines
set -a
# shellcheck disable=SC1091
. .env
set +a

# 3. Verify Azure Login
log_info "Verifying Azure login..."
if ! az account show &> /dev/null; then
    log_error "Not logged into Azure CLI. Please run 'az login' first."
fi
log_success "Logged into Azure. Active subscription: $(az account show --query name -o tsv)"

# Set target subscription if provided
if [ -n "${AZURE_SUBSCRIPTION_ID:-}" ] && [ "$AZURE_SUBSCRIPTION_ID" != "your-azure-subscription-id" ]; then
    log_info "Setting Azure subscription to: $AZURE_SUBSCRIPTION_ID"
    az account set --subscription "$AZURE_SUBSCRIPTION_ID"
fi

# Verify repository is reachable by the VM's unauthenticated cloud-init clone
if [ -z "${GITHUB_REPO_URL:-}" ]; then
    log_error "GITHUB_REPO_URL is not configured. Set it to a public or otherwise unauthenticated clone URL."
fi

log_info "Verifying repository is publicly reachable: $GITHUB_REPO_URL"
if ! GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c credential.useHttpPath=true ls-remote "$GITHUB_REPO_URL" HEAD > /dev/null 2>&1; then
    log_error "Repository is not reachable without credentials. Make the repo public or provide an unauthenticated clone URL before deploying."
fi
log_success "Repository reachability verified."

# 4. Terraform Initialization & Apply
log_info "Initializing Terraform..."
cd infra
terraform init

log_info "Validating Terraform configuration..."
terraform validate

log_info "Applying Terraform configuration..."
for required in CAPELLA_AUTH_TOKEN CAPELLA_ORGANIZATION_ID CAPELLA_PROJECT_ID; do
    eval "val=\${$required:-}"
    if [ -z "$val" ]; then
        log_error "$required is required for deployment."
    fi
done

export TF_VAR_subscription_id="${AZURE_SUBSCRIPTION_ID:-}"
export TF_VAR_location="${AZURE_LOCATION:-eastus}"
export TF_VAR_prefix="${RESOURCE_PREFIX:-cb-otel-demo}"
export TF_VAR_vm_size="${AZURE_VM_SIZE:-Standard_D4s_v5}"
export TF_VAR_admin_username="${VM_ADMIN_USERNAME:-azureuser}"
export TF_VAR_github_repo_url="${GITHUB_REPO_URL:-}"
export TF_VAR_capella_auth_token="${CAPELLA_AUTH_TOKEN:-}"
export TF_VAR_capella_organization_id="${CAPELLA_ORGANIZATION_ID:-}"
export TF_VAR_capella_project_id="${CAPELLA_PROJECT_ID:-}"
export TF_VAR_capella_cluster_region="${CAPELLA_CLUSTER_REGION:-eastus}"
export TF_VAR_couchbase_bucket="${COUCHBASE_BUCKET:-demo}"
export TF_VAR_couchbase_scope="${COUCHBASE_SCOPE:-app360}"
export TF_VAR_demo_preferred_incident_id="${DEMO_PREFERRED_INCIDENT_ID:-INC-DEMO-001}"
export TF_VAR_generator_profile="${GENERATOR_PROFILE:-demo}"
export TF_VAR_generator_interval_seconds="${GENERATOR_INTERVAL_SECONDS:-5.0}"
export TF_VAR_generator_events_per_batch="${GENERATOR_EVENTS_PER_BATCH:-1}"
export TF_VAR_generator_enable_otel_calls="${GENERATOR_ENABLE_OTEL_CALLS:-true}"
export TF_VAR_generator_new_customer_probability="${GENERATOR_NEW_CUSTOMER_PROBABILITY:-0.2}"
export TF_VAR_generator_ticket_probability="${GENERATOR_TICKET_PROBABILITY:-0.25}"
export TF_VAR_generator_enable_metrics="${GENERATOR_ENABLE_METRICS:-true}"
export TF_VAR_generator_enable_incident_updates="${GENERATOR_ENABLE_INCIDENT_UPDATES:-true}"
export TF_VAR_generator_unique_metric_docs="${GENERATOR_UNIQUE_METRIC_DOCS:-false}"
export TF_VAR_generator_log_every_n_events="${GENERATOR_LOG_EVERY_N_EVENTS:-1}"
export TF_VAR_generator_flush_every_n_events="${GENERATOR_FLUSH_EVERY_N_EVENTS:-}"
export TF_VAR_generator_incident_update_every_n_events="${GENERATOR_INCIDENT_UPDATE_EVERY_N_EVENTS:-1}"
export TF_VAR_generator_producer_linger_ms="${GENERATOR_PRODUCER_LINGER_MS:-5}"
export TF_VAR_generator_producer_batch_num_messages="${GENERATOR_PRODUCER_BATCH_NUM_MESSAGES:-10000}"
export TF_VAR_generator_producer_queue_max_messages="${GENERATOR_PRODUCER_QUEUE_MAX_MESSAGES:-100000}"
export TF_VAR_generator_producer_compression="${GENERATOR_PRODUCER_COMPRESSION:-lz4}"
export TF_VAR_generator_enterprise_account_count="${GENERATOR_ENTERPRISE_ACCOUNT_COUNT:-30}"
export TF_VAR_generator_scenario="${GENERATOR_SCENARIO:-payment_outage}"
export TF_VAR_generator_incident_id="${GENERATOR_INCIDENT_ID:-}"
export TF_VAR_generator_random_seed="${GENERATOR_RANDOM_SEED:-}"
export TF_VAR_generator_max_active_customers="${GENERATOR_MAX_ACTIVE_CUSTOMERS:-500}"


terraform apply -auto-approve

# 6. Output VM Status and Info
VM_IP=$(terraform output -raw vm_public_ip)
SSH_KEY=$(terraform output -raw ssh_private_key)
cd ..

KEY_PATH="$(pwd)/${TF_VAR_prefix}-vm.pem"
printf '%s' "$SSH_KEY" > "$KEY_PATH"
chmod 600 "$KEY_PATH"

log_success "Terraform deployment complete!"
echo "---------------------------------------------------------"
echo " VM Public IP: $VM_IP"
echo " SSH Key: $KEY_PATH"
echo " SSH: ssh -i \"$KEY_PATH\" ${TF_VAR_admin_username}@$VM_IP"
echo " Redpanda Console: http://$VM_IP:8080"
echo " Demo UI: http://$VM_IP:3000"
echo "---------------------------------------------------------"
echo "NOTE: First deploy takes ~20 minutes — Terraform is creating the Capella cluster."
echo "Wait until cloud-init finishes before opening the Demo UI."
echo "Startup logs:"
echo " ssh -i \"$KEY_PATH\" ${TF_VAR_admin_username}@$VM_IP \"sudo tail -120 /var/log/cloud-init-output.log\""
echo " ssh -i \"$KEY_PATH\" ${TF_VAR_admin_username}@$VM_IP \"sudo tail -120 /var/log/cb-demo-compose.log\""
echo " ssh -i \"$KEY_PATH\" ${TF_VAR_admin_username}@$VM_IP \"sudo tail -120 /var/log/cb-connector-setup.log\""
