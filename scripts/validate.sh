#!/usr/bin/env bash
# ==============================================================================
# Validation Script (macOS/Linux)
# Verifies that core demo services are reachable and the Couchbase connector runs.
# ==============================================================================

set -u

log_info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $*"; }
log_failure() { echo -e "\033[1;31m[FAIL]\033[0m $*"; }

for cmd in terraform curl jq ssh; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
        log_failure "Missing prerequisite command: $cmd"
        exit 1
    fi
done

FAILURES=0
test_step() {
    local name="$1"
    shift
    log_info "$name"
    if "$@"; then
        log_success "$name"
    else
        FAILURES=$((FAILURES + 1))
        log_failure "$name"
    fi
}

http_ok() {
    local url="$1"
    curl -s -f --connect-timeout 5 "$url" > /dev/null
}

tcp_ok() {
    local host="$1"
    local port="$2"
    if command -v nc > /dev/null 2>&1; then
        nc -z -w 5 "$host" "$port"
    else
        curl -s --connect-timeout 5 "http://$host:$port" > /dev/null
    fi
}

# Derive SSH key path from .env so connector checks can tunnel through SSH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$REPO_ROOT/.env"
    set +a
fi
RESOURCE_PREFIX="${RESOURCE_PREFIX:-cb-otel-demo}"
VM_ADMIN_USERNAME="${VM_ADMIN_USERNAME:-azureuser}"
KEY_PATH="$REPO_ROOT/${RESOURCE_PREFIX}-vm.pem"

ssh_vm() {
    if [ ! -f "$KEY_PATH" ]; then
        log_failure "SSH key not found at $KEY_PATH — cannot reach Kafka Connect REST API."
        return 1
    fi
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o BatchMode=yes \
        -o ConnectTimeout=10 "${VM_ADMIN_USERNAME}@${VM_IP}" "$@"
}

# 1. Retrieve VM Public IP from Terraform
log_info "Retrieving VM Public IP from Terraform output..."
if [ -d "infra" ]; then
    pushd infra > /dev/null || exit 1
    VM_IP=$(terraform output -raw vm_public_ip 2>/dev/null || echo "")
    popd > /dev/null || exit 1
else
    log_failure "infra/ directory not found. Please run this script from the repository root."
    exit 1
fi

if [ -z "$VM_IP" ]; then
    log_failure "Could not fetch VM IP. Has the environment been deployed?"
    exit 1
fi
log_success "VM Public IP detected: $VM_IP"

# 2. Verify externally exposed ports (8083 is loopback-only on the VM; checked via SSH below)
for port in 3000 8080; do
    test_step "Checking TCP port $port" tcp_ok "$VM_IP" "$port"
done

# 3. Verify HTTP services
test_step "Checking Redpanda Console HTTP" http_ok "http://$VM_IP:8080/"
test_step "Checking Demo UI HTTP" http_ok "http://$VM_IP:3000/"

# 4. Verify Kafka Connect via SSH (port 8083 is loopback-only on the VM)
log_info "Checking Kafka Connect API (via SSH)"
CONNECT_STATUS=$(ssh_vm "curl -s http://localhost:8083/" 2>/dev/null || echo "")
if echo "$CONNECT_STATUS" | jq -e '.version' > /dev/null 2>&1; then
    log_success "Checking Kafka Connect API (via SSH)"
else
    FAILURES=$((FAILURES + 1))
    log_failure "Checking Kafka Connect API (via SSH)"
fi

# 5. Verify Couchbase Sink Connector is Registered
log_info "Checking connector registration"
CONNECTOR_CHECK=$(ssh_vm "curl -s http://localhost:8083/connectors/couchbase-sink-connector" 2>/dev/null || echo "")
if echo "$CONNECTOR_CHECK" | jq -e '.name == "couchbase-sink-connector"' > /dev/null 2>&1; then
    log_success "Checking connector registration"
else
    CONNECTORS=$(ssh_vm "curl -s http://localhost:8083/connectors" 2>/dev/null || echo "[]")
    FAILURES=$((FAILURES + 1))
    log_failure "Checking connector registration - registered connectors: $CONNECTORS"
fi

# 6. Verify Connector Target Collections
log_info "Checking connector target collections"
CONFIG=$(ssh_vm "curl -s http://localhost:8083/connectors/couchbase-sink-connector/config" 2>/dev/null || echo "{}")
MAPPING_ERRORS=""
for topic in logs traces metrics customers orders support_tickets accounts services incidents payments shipments deployments; do
    key="couchbase.default.collection[$topic]"
    value=$(echo "$CONFIG" | jq -r --arg key "$key" '.[$key] // empty' 2>/dev/null)
    if [ -z "$value" ]; then
        MAPPING_ERRORS="$MAPPING_ERRORS missing:$key"
    elif echo "$value" | grep -q '\${env:' || ! echo "$value" | grep -Eq '^[^.]+\.[^.]+$'; then
        MAPPING_ERRORS="$MAPPING_ERRORS $key=$value"
    fi
done

if [ -z "$MAPPING_ERRORS" ]; then
    log_success "Checking connector target collections"
else
    FAILURES=$((FAILURES + 1))
    log_failure "Checking connector target collections - expected literal scope.collection values:$MAPPING_ERRORS"
fi

# 7. Verify Connector Tasks are RUNNING
log_info "Checking connector task status"
STATUS=$(ssh_vm "curl -s http://localhost:8083/connectors/couchbase-sink-connector/status" 2>/dev/null || echo "")
CONNECTOR_STATE=$(echo "$STATUS" | jq -r '.connector.state // empty' 2>/dev/null)
NOT_RUNNING=$(echo "$STATUS" | jq -r '.tasks[]? | select(.state != "RUNNING") | "task \(.id): \(.state)"' 2>/dev/null)
if [ "$CONNECTOR_STATE" = "RUNNING" ] && [ -z "$NOT_RUNNING" ]; then
    log_success "Checking connector task status"
else
    FAILURES=$((FAILURES + 1))
    log_failure "Checking connector task status - connector: ${CONNECTOR_STATE:-unknown}; tasks: ${NOT_RUNNING:-unknown}"
fi

log_info "Checking end-to-end data search"
DATA_FLOWS=false
for i in 1 2 3 4 5 6; do
    BEST_RECORDS=$(curl -s -f --connect-timeout 10 "http://$VM_IP:3000/api/demo/best-records" 2>/dev/null || echo "{}")
    SEARCH_ID=$(echo "$BEST_RECORDS" | jq -r '.order.orderId // empty' 2>/dev/null)
    SEARCH_TYPE="orderId"
    if [ -z "$SEARCH_ID" ]; then
        SEARCH_ID=$(echo "$BEST_RECORDS" | jq -r '.customer.customerId // empty' 2>/dev/null)
        SEARCH_TYPE="customerId"
    fi
    if [ -z "$SEARCH_ID" ]; then
        sleep 10
        continue
    fi

    UI_RESPONSE=$(curl -s -f -G --connect-timeout 10 --data-urlencode "query=$SEARCH_ID" --data-urlencode "type=$SEARCH_TYPE" "http://$VM_IP:3000/api/search" 2>/dev/null || echo "[]")
    RESULT_COUNT=$(echo "$UI_RESPONSE" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null || echo "0")
    if [ "${RESULT_COUNT:-0}" -gt 0 ]; then
        DATA_FLOWS=true
        break
    fi
    sleep 10
done

if [ "$DATA_FLOWS" = true ]; then
    log_success "Checking end-to-end data search"
else
    FAILURES=$((FAILURES + 1))
    log_failure "Checking end-to-end data search - no customer/order data returned from the Demo UI search API yet."
fi

log_info "Checking Incident Command Center API"
INCIDENTS=$(curl -s -f --connect-timeout 10 "http://$VM_IP:3000/api/incidents" 2>/dev/null || echo "[]")
INCIDENT_ID=$(echo "$INCIDENTS" | jq -r '([.[] | select(.incidentId == "INC-DEMO-001")][0].incidentId) // ([.[] | select((.affectedOrderCount // 0) > 0)][0].incidentId) // (.[0].incidentId) // empty' 2>/dev/null)
if [ -n "$INCIDENT_ID" ]; then
    SUMMARY=$(curl -s -f --connect-timeout 10 "http://$VM_IP:3000/api/incidents/$INCIDENT_ID/summary" 2>/dev/null || echo "{}")
    SUMMARY_ID=$(echo "$SUMMARY" | jq -r '.incident.incidentId // empty' 2>/dev/null)
    TIMELINE=$(curl -s -f --connect-timeout 10 "http://$VM_IP:3000/api/timeline?incidentId=$INCIDENT_ID" 2>/dev/null || echo "{}")
    TIMELINE_COUNT=$(echo "$TIMELINE" | jq -r '.count // 0' 2>/dev/null)
    ROOT_CAUSE=$(curl -s -f --connect-timeout 10 "http://$VM_IP:3000/api/incidents/$INCIDENT_ID/root-cause" 2>/dev/null || echo "{}")
    ROOT_CAUSE_ID=$(echo "$ROOT_CAUSE" | jq -r '.incident.incidentId // empty' 2>/dev/null)
    ROOT_CAUSE_SERVICE=$(echo "$ROOT_CAUSE" | jq -r '.suspectedService.serviceName // empty' 2>/dev/null)
    INCIDENT_ORDER_COUNT=$(echo "$INCIDENTS" | jq -r --arg id "$INCIDENT_ID" '.[] | select(.incidentId == $id) | (.affectedOrderCount // 0)' 2>/dev/null)
    BEST_RECORDS=$(curl -s -f --connect-timeout 10 "http://$VM_IP:3000/api/demo/best-records" 2>/dev/null || echo "{}")
    BEST_INCIDENT_ID=$(echo "$BEST_RECORDS" | jq -r '.incident.incidentId // empty' 2>/dev/null)
    BEST_READY=$(echo "$BEST_RECORDS" | jq -r '.ready // false' 2>/dev/null)
    BEST_PATH_COUNT=$(echo "$BEST_RECORDS" | jq -r '(.recommendedPath // []) | length' 2>/dev/null)
    ACCOUNT_ID=$(echo "$SUMMARY" | jq -r '.topAccounts[0].accountId // empty' 2>/dev/null)
    CUSTOMER_ID=$(echo "$SUMMARY" | jq -r '.recentOrders[0].customerId // empty' 2>/dev/null)
    ACCOUNT_OK=true
    CUSTOMER_OK=true
    ROOT_CAUSE_OK=true
    BEST_RECORDS_OK=true

    if [ "$ROOT_CAUSE_ID" != "$INCIDENT_ID" ]; then
        ROOT_CAUSE_OK=false
    elif [ "${INCIDENT_ORDER_COUNT:-0}" -gt 0 ] && [ -z "$ROOT_CAUSE_SERVICE" ]; then
        ROOT_CAUSE_OK=false
    fi

    if [ -z "$BEST_INCIDENT_ID" ]; then
        BEST_RECORDS_OK=false
    elif [ "$BEST_READY" = true ] && [ "${BEST_PATH_COUNT:-0}" -lt 3 ]; then
        BEST_RECORDS_OK=false
    fi

    if [ -n "$ACCOUNT_ID" ]; then
        ACCOUNT_IMPACT=$(curl -s -f --connect-timeout 10 "http://$VM_IP:3000/api/accounts/$ACCOUNT_ID/impact" 2>/dev/null || echo "{}")
        if ! echo "$ACCOUNT_IMPACT" | jq -e --arg id "$ACCOUNT_ID" '.account.accountId == $id and (.recommendedAction.priority // "") != ""' > /dev/null 2>&1; then
            ACCOUNT_OK=false
        fi
    fi

    if [ -n "$CUSTOMER_ID" ]; then
        CUSTOMER_IMPACT=$(curl -s -f --connect-timeout 10 "http://$VM_IP:3000/api/customers/$CUSTOMER_ID/impact" 2>/dev/null || echo "{}")
        if ! echo "$CUSTOMER_IMPACT" | jq -e --arg id "$CUSTOMER_ID" '.customer.customerId == $id and (.recommendedAction.priority // "") != ""' > /dev/null 2>&1; then
            CUSTOMER_OK=false
        fi
    fi

    if [ "$SUMMARY_ID" = "$INCIDENT_ID" ] && [ "$TIMELINE_COUNT" -gt 0 ] && [ "$ACCOUNT_OK" = true ] && [ "$CUSTOMER_OK" = true ] && [ "$ROOT_CAUSE_OK" = true ] && [ "$BEST_RECORDS_OK" = true ]; then
        log_success "Checking Incident Command Center API"
    else
        FAILURES=$((FAILURES + 1))
        log_failure "Checking Incident Command Center API - summary, timeline, 360 impact, root cause, or best demo records endpoint did not return expected data."
    fi
else
    FAILURES=$((FAILURES + 1))
    log_failure "Checking Incident Command Center API - no incidents returned."
fi

if [ "$FAILURES" -eq 0 ]; then
    echo "---------------------------------------------------------"
    echo "  Demo Status: CORE SERVICES REACHABLE"
    echo "  React UI: http://$VM_IP:3000"
    echo "  Redpanda Console: http://$VM_IP:8080"
  echo "  Kafka Connect (SSH): ssh -i \"$KEY_PATH\" -L 8083:localhost:8083 ${VM_ADMIN_USERNAME}@$VM_IP"
    echo "---------------------------------------------------------"
else
    log_failure "Validation completed with $FAILURES failure(s). Troubleshoot from the first failed layer above."
    exit 1
fi
