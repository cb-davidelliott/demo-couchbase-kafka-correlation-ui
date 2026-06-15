# Query And Index Notes

The preferred place to run demo-supporting queries is the **Operator** tab in the UI. It executes curated read-only checks through the app API and shows the SQL++ used for each check.

This file keeps the durable concepts: which indexes matter, why the queries work, and where to change them in code.

## Where Queries Live

Current API and UI query logic lives in:

- [../app/ui/server.js](../app/ui/server.js)
- [../app/ui/public/index.html](../app/ui/public/index.html)

The Operator tab currently includes:

- Recent data health
- Incident blast radius
- Payment latency by service
- Trace drill-in candidates
- OpenTelemetry coverage
- Metrics coverage
- High-value account impact

Add or change curated queries in `app/ui/server.js`, not by adding long manual SQL blocks to this doc.

## Collections

The demo writes to one bucket and one scope, normally:

```text
demo.app360
```

Collections are aligned to source concepts:

- `accounts`
- `customers`
- `orders`
- `payments`
- `shipments`
- `support_tickets`
- `incidents`
- `services`
- `deployments`
- `traces`
- `logs`
- `metrics`

The authoritative Kafka-to-collection mapping is [../app/connect/couchbase-sink.json](../app/connect/couchbase-sink.json).

Bucket, scope, and collection setup is intentionally outside Terraform. Use the setup SQL in [01_DEPLOYMENT.md](01_DEPLOYMENT.md) or your own Capella provisioning process.

## Correlation Keys

The UI relies on stable IDs that appear across documents:

- `incidentId`
- `accountId`
- `customerId`
- `orderId`
- `traceId`
- `serviceName`
- `region`

This lets the app move from business impact to root cause evidence without pre-flattening everything into one table.

## Indexes

The UI attempts to create the indexes it needs at startup unless `ENSURE_COUCHBASE_INDEXES="false"`.

The index definitions are in `ensureQueryIndexes()` in [../app/ui/server.js](../app/ui/server.js). Keep them there so the running app and documentation do not drift.

Do not use primary indexes as the normal fix for demo query issues. The demo is intended to model production-style access patterns, so each UI path should have a specific index that matches its predicates.

Important index groups:

- Orders by `traceId`, `customerId`, `accountId`, `incidentId`, and order time.
- Tickets by `traceId`, `status`, `accountId`, `customerId`, and `incidentId`.
- Payments and shipments by `orderId`, `incidentId`, `accountId`, and `customerId`.
- Incidents by `incidentId` and `startedAt`.
- Deployments by `incidentId` and `serviceName`.
- Nested OTel spans by `traceId`.
- Nested OTel log records by `traceId`.
- Nested OTel metric names from `resourceMetrics`.

## Query Patterns

The key SQL++ patterns are:

1. Start with an incident and aggregate affected business records.
2. Join orders to payments, shipments, tickets, customers, and accounts by stable IDs.
3. Use `UNNEST` to flatten OpenTelemetry `resourceSpans` and `resourceLogs`.
4. Use the trace ID from business documents to fetch spans and logs.
5. Keep high-cardinality demo lookup paths indexed.

Example trace span pattern:

```sql
SELECT s.traceId,
       s.name AS spanName,
       s.spanId,
       DIV(TONUMBER(s.endTimeUnixNano) - TONUMBER(s.startTimeUnixNano), 1000000) AS durationMs
FROM `demo`.`app360`.traces t
UNNEST t.resourceSpans AS rs
UNNEST rs.scopeSpans AS ss
UNNEST ss.spans AS s
WHERE s.traceId = $traceId
ORDER BY s.startTimeUnixNano ASC;
```

Example log pattern:

```sql
SELECT lr.traceId,
       lr.severityText AS severity,
       lr.body.stringValue AS logMessage,
       DIV(TONUMBER(lr.timeUnixNano), 1000000) AS timestampMs
FROM `demo`.`app360`.logs l
UNNEST l.resourceLogs AS rl
UNNEST rl.scopeLogs AS sl
UNNEST sl.logRecords AS lr
WHERE lr.traceId = $traceId
ORDER BY lr.timeUnixNano ASC;
```

These examples are intentionally generic. Use the UI Operator tab for live checks against the current demo data.
