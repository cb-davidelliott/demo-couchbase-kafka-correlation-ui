#!/usr/bin/env bash
# ==============================================================================
# Destroy Script (macOS/Linux)
# Couchbase Capella + Kafka + OpenTelemetry Demo Project
# ==============================================================================

set -euo pipefail

log_info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $*"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

# Check for .env file
if [ ! -f .env ]; then
    log_error "No .env file found. Please create one to ensure environment variables are configured."
fi

# Load environment variables
set -a
# shellcheck disable=SC1091
. .env
set +a

log_info "Verifying Azure login..."
if ! az account show &> /dev/null; then
    log_error "Not logged into Azure CLI. Please run 'az login' first."
fi

log_info "Running Terraform Destroy..."
cd infra

export TF_VAR_subscription_id="${AZURE_SUBSCRIPTION_ID:-}"
export TF_VAR_location="${AZURE_LOCATION:-eastus}"
export TF_VAR_prefix="${RESOURCE_PREFIX:-cb-otel-demo}"
export TF_VAR_vm_size="${AZURE_VM_SIZE:-Standard_D4s_v5}"
export TF_VAR_admin_username="${VM_ADMIN_USERNAME:-azureuser}"
export TF_VAR_capella_auth_token="${CAPELLA_AUTH_TOKEN:-}"

terraform destroy -auto-approve
log_success "Demo infrastructure has been successfully destroyed!"
cd ..

# Clean up SSH key file left by deploy.sh
KEY_FILE="${RESOURCE_PREFIX:-cb-otel-demo}-vm.pem"
if [ -f "$KEY_FILE" ]; then
    rm -f "$KEY_FILE"
    log_success "Removed SSH key: $KEY_FILE"
fi
