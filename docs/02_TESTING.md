# Testing Checklist

Use this checklist after a fresh deploy, after a VM refresh, or before a customer demo.

The goal is not to manually retest every query. The app and validation scripts should do most of the work.

## 1. Automated Validation

From your local repo:

```powershell
.\scripts\validate.ps1
```

Or:

```bash
./scripts/validate.sh
```

Expected result:

- Public IP resolves.
- Demo UI responds on port `3000`.
- Redpanda Console responds on port `8080`.
- Kafka Connect responds on port `8083`.
- Connector is registered and running.

## 2. UI Readiness

Open `http://<VM_PUBLIC_IP>:3000`.

Check:

- Incident list loads.
- Recommended Demo Path appears.
- Command Center has incident summary data.
- Business Impact has affected accounts/customers/orders.
- Root Cause shows suspected service, traces/logs/spans, and metric evidence when metrics are enabled.
- Timeline shows multiple event types.
- Search can open a trace/order detail.
- Operator tab can run **Recent data health**.

If the UI is sparse, wait 60 to 90 seconds and click **Refresh Recommendations**.

If the UI loads but shows a database connection error, wait 30 seconds — the server runs a heartbeat that reconnects automatically if the Couchbase connection drops. A UI restart is not required for transient connectivity issues.

## 3. Operator Query Checks

In the UI, open **Operator** and run:

- **Recent data health**
- **Incident blast radius**
- **Payment latency by service**
- **Trace drill-in candidates**
- **OpenTelemetry coverage**
- **Metrics coverage**
- **High-value account impact**

These checks replace most manual SQL++ copy/paste from older docs.

## 4. Data API Query Validation

If the Capella Data API is enabled, validate the UI query shapes directly from your local repo:

```powershell
$env:COUCHBASE_DATA_API_ENDPOINT="https://<your-data-api-endpoint>"
$env:COUCHBASE_DATA_API_USERNAME="<data-api-user>"
$env:COUCHBASE_DATA_API_PASSWORD="<data-api-password>"
.\scripts\validate-data-api-queries.ps1
```

Add `-RunSamples` when you also want a few small bounded executions:

```powershell
.\scripts\validate-data-api-queries.ps1 -RunSamples
```

The script uses `EXPLAIN` for the main UI/API query shapes, discovers sample IDs from the cluster, and prints a compact pass/fail report. A missing index usually appears as `No index available on keyspace`.

## 5. VM-Level Checks

SSH to the VM only if the UI or validation script shows a problem.

```bash
cd /opt/couchbase-capella-kafka-demo
sudo docker compose --env-file .env -f app/docker-compose.yml ps
```

Connector:

```bash
curl -s http://localhost:8083/connectors | jq .
curl -s http://localhost:8083/connectors/couchbase-sink-connector/status | jq .
```

Generator:

```bash
sudo docker compose --env-file .env -f app/docker-compose.yml logs --tail=80 event-generator
```

Kafka topics:

```bash
sudo docker exec redpanda rpk topic list
```

## 5. Trace And Log Checks

Trace/log data is optional for the business story but useful for the final drill-in.

Check from the UI first:

1. Open **Search** or **Trace Detail** from the Recommended Demo Path.
2. Open **Spans Waterfall**.
3. Open **Correlated Logs**.

If spans/logs are empty but business data exists:

```bash
sudo docker logs otel-demo --tail=80
sudo docker logs otel-collector --tail=80
sudo docker exec redpanda rpk topic consume traces --num 1
sudo docker exec redpanda rpk topic consume logs --num 1
```

## 6. Load Checks

Load settings are controlled by `.env` and documented inline in `.env.example`.

For high document growth:

- Set `GENERATOR_PROFILE="load"`.
- Increase `GENERATOR_EVENTS_PER_BATCH`.
- Lower `GENERATOR_INTERVAL_SECONDS`; use `0` for continuous generation.
- Set `GENERATOR_ENABLE_OTEL_CALLS="false"` when you want high-volume business docs.
- Set `GENERATOR_NEW_CUSTOMER_PROBABILITY="1.0"` when you want many unique customers.
- Set `GENERATOR_MAX_ACTIVE_CUSTOMERS` to cap the active customer pool size (default `500` in demo mode, `2000` in load mode). Lower values reduce memory use and keep the pool cycling through a smaller set of customers; higher values spread events across more unique customers.
- Set `GENERATOR_TICKET_PROBABILITY="1.0"` when you want a ticket per event.
- Set `GENERATOR_UNIQUE_METRIC_DOCS="true"` when you want metric document counts to grow.
- Set `GENERATOR_LOG_EVERY_N_EVENTS` and `GENERATOR_FLUSH_EVERY_N_EVENTS` to larger values to reduce generator overhead.
- Set `GENERATOR_INCIDENT_UPDATE_EVERY_N_EVENTS` to a larger value so the incident summary doc is not rewritten for every event.
- Set `GENERATOR_ENABLE_INCIDENT_UPDATES="false"` for multi-replica load runs if you only need raw volume and not live incident counters.

After changing VM `.env` values:

```bash
cd /opt/couchbase-capella-kafka-demo
sudo docker compose --env-file .env -f app/docker-compose.yml build event-generator
sudo docker compose --env-file .env -f app/docker-compose.yml up -d --no-deps --force-recreate event-generator
```

To scale generation with multiple producers:

```bash
sudo docker compose --env-file .env -f app/docker-compose.yml up -d --scale event-generator=2 event-generator
sudo docker compose --env-file .env -f app/docker-compose.yml logs -f event-generator
```

Stopping the generator stops new Kafka messages, but Kafka Connect may keep draining existing topic backlog into Couchbase. For load tests where you need Couchbase document counts to stop immediately:

```bash
sudo docker compose --env-file .env -f app/docker-compose.yml stop event-generator
sudo docker compose --env-file .env -f app/docker-compose.yml stop kafka-connect
```

Resume Couchbase writes after inspection:

```bash
sudo docker compose --env-file .env -f app/docker-compose.yml up -d kafka-connect
```

## Success Criteria

Before a customer demo, you should be able to say yes to these:

- The Demo UI loads quickly.
- The selected incident has affected orders.
- Business Impact shows account/customer context.
- Root Cause shows at least one useful service or payment signal.
- Timeline has more than one event type.
- At least one trace detail opens from the UI.
- Operator tab returns live rows for the key checks.
- You know how to stop the generator without destroying the VM.
