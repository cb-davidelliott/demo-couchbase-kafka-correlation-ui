#!/usr/bin/env bash
# ==============================================================================
# Setup Connectors Script
# Automatically registers the Couchbase Kafka Sink Connector with Kafka Connect.
# With retry logic and detailed error reporting.
# ==============================================================================

set -euo pipefail

CONNECT_URL="http://localhost:8083"
CONFIG_FILE="/opt/couchbase-capella-kafka-demo/app/connect/couchbase-sink.json"
ENV_FILE="/opt/couchbase-capella-kafka-demo/.env"
MAX_RETRIES=30
RETRY_INTERVAL=5

echo "[INFO] Waiting for Kafka Connect to start at $CONNECT_URL..."
RETRIES=0
until curl -s -f "$CONNECT_URL/" > /dev/null 2>&1; do
    RETRIES=$((RETRIES + 1))
    if [ "$RETRIES" -ge "$MAX_RETRIES" ]; then
        echo "[ERROR] Kafka Connect failed to start after ${MAX_RETRIES} retries"
        exit 1
    fi
    sleep "$RETRY_INTERVAL"
    echo "[INFO] Still waiting for Kafka Connect... (attempt $RETRIES/$MAX_RETRIES)"
done
echo "[SUCCESS] Kafka Connect REST API is up!"

# Wait an additional 5 seconds to ensure plugin registry is loaded
echo "[INFO] Waiting for plugin registry to load..."
sleep 5

# Validate config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] Config file not found: $CONFIG_FILE"
    exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "[ERROR] Environment file not found: $ENV_FILE"
    exit 1
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

if [ -z "${COUCHBASE_SEED_NODES:-}" ]; then
    COUCHBASE_SEED_NODES="${COUCHBASE_CONN_STR#couchbases://}"
    COUCHBASE_SEED_NODES="${COUCHBASE_SEED_NODES#couchbase://}"
    COUCHBASE_SEED_NODES="${COUCHBASE_SEED_NODES%%/*}"
fi

for required_var in COUCHBASE_SEED_NODES COUCHBASE_USERNAME COUCHBASE_PASSWORD COUCHBASE_BUCKET COUCHBASE_SCOPE; do
    if [ -z "${!required_var:-}" ]; then
        echo "[ERROR] Required environment variable is missing: $required_var"
        exit 1
    fi
done

RENDERED_CONFIG=$(mktemp)
trap 'rm -f "$RENDERED_CONFIG"' EXIT

# The password is substituted here at registration time. The connector config is
# protected from external access by the NSG (port 8083 is not publicly exposed)
# and by docker-compose binding kafka-connect to loopback only (127.0.0.1:8083).
jq \
    --arg seed_nodes "$COUCHBASE_SEED_NODES" \
    --arg username "$COUCHBASE_USERNAME" \
    --arg password "$COUCHBASE_PASSWORD" \
    --arg bucket "$COUCHBASE_BUCKET" \
    --arg scope "$COUCHBASE_SCOPE" \
    '.config
     | .["couchbase.seed.nodes"] = $seed_nodes
     | .["couchbase.username"] = $username
     | .["couchbase.password"] = $password
     | .["couchbase.bucket"] = $bucket
     | .["couchbase.default.collection[logs]"] = ($scope + ".logs")
     | .["couchbase.default.collection[traces]"] = ($scope + ".traces")
     | .["couchbase.default.collection[metrics]"] = ($scope + ".metrics")
     | .["couchbase.default.collection[customers]"] = ($scope + ".customers")
     | .["couchbase.default.collection[orders]"] = ($scope + ".orders")
     | .["couchbase.default.collection[support_tickets]"] = ($scope + ".support_tickets")
     | .["couchbase.default.collection[accounts]"] = ($scope + ".accounts")
     | .["couchbase.default.collection[services]"] = ($scope + ".services")
     | .["couchbase.default.collection[incidents]"] = ($scope + ".incidents")
     | .["couchbase.default.collection[payments]"] = ($scope + ".payments")
     | .["couchbase.default.collection[shipments]"] = ($scope + ".shipments")
     | .["couchbase.default.collection[deployments]"] = ($scope + ".deployments")
     | del(.["couchbase.topic.to.collection"])' \
    "$CONFIG_FILE" > "$RENDERED_CONFIG"

echo "[INFO] Registering Couchbase Sink Connector..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
    -H "Content-Type: application/json" \
    --data-binary @"$RENDERED_CONFIG" \
    "$CONNECT_URL/connectors/couchbase-sink-connector/config" 2>&1)

# Split response and HTTP code
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n-1)

echo "[DEBUG] HTTP Code: $HTTP_CODE"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    echo "[SUCCESS] Couchbase Sink Connector registered successfully!"
    echo "[INFO] Waiting 5 seconds for connector to initialize..."
    sleep 5
    
    # Verify connector is running
    echo "[INFO] Verifying connector status..."
    STATUS_RESPONSE=$(curl -s "$CONNECT_URL/connectors/couchbase-sink-connector/status" 2>&1)
    CONNECTOR_STATE=$(echo "$STATUS_RESPONSE" | jq -r '.connector.state // empty')
    
    if [ "$CONNECTOR_STATE" = "RUNNING" ]; then
        echo "[SUCCESS] Connector is RUNNING!"
        exit 0
    else
        echo "[WARNING] Connector state is: $CONNECTOR_STATE"
        echo "[INFO] Connector may still be initializing. Check logs later."
        exit 0
    fi
elif [ "$HTTP_CODE" = "409" ]; then
    echo "[INFO] Connector already exists (409 Conflict). This is OK."
    exit 0
else
    echo "[ERROR] Failed to register Couchbase Sink Connector"
    echo "[ERROR] HTTP Code: $HTTP_CODE"
    echo "[ERROR] Response: $RESPONSE_BODY"
    exit 1
fi
