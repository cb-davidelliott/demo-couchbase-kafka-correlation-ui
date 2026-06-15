# Enterprise Incident Demo Plan History

This document is historical context. It explains how the current enterprise incident demo evolved, but it is not the runbook for operating the demo.

For current usage, start here:

- [../README.md](../README.md)
- [01_DEPLOYMENT.md](01_DEPLOYMENT.md)
- [02_TESTING.md](02_TESTING.md)
- [03_DEMO_RUNBOOK.md](03_DEMO_RUNBOOK.md)

## Original Goal

The demo started as a proof that multiple systems could publish data through Kafka into Couchbase, where that data could be queried and served by an application.

The use case became an enterprise incident investigation workflow:

1. Detect or select a customer-impacting incident.
2. Show affected accounts, customers, orders, payments, shipments, and support tickets.
3. Correlate business impact with service, deployment, trace, and log evidence.
4. Let the presenter drill into one rich trace/order/customer path.
5. Prove that Couchbase can serve the operational UI directly from JSON documents ingested through Kafka.

## Implemented Phases

The following phases have been folded into the running demo:

- Stabilized deploy and validation scripts.
- Added enterprise entities: accounts, services, incidents, deployments, payments, and shipments.
- Added repeatable incident scenarios in the generator.
- Added Incident Command Center UI.
- Added investigation timeline.
- Added Account and Customer 360 views.
- Added root cause evidence view.
- Added refresh workflow for VM development.
- Added Terraform-managed Capella schema option.
- Added demo operator queries in the UI.

## Current Operating Model

The current demo should be operated from the UI:

- **Command Center** for incident summary.
- **Business Impact** for affected account/customer context.
- **Root Cause** for suspected services, deployments, traces, and logs.
- **Timeline** for event sequence.
- **Search** for direct ID lookup.
- **Operator** for curated live query checks.

The old phase-by-phase implementation checklist is intentionally not preserved here because it duplicated code and became easy to misread as current setup guidance.

## If You Extend The Demo

Prefer changes in this order:

1. Add or adjust generated data in `app/generator/main.py`.
2. Map any new Kafka topic in `app/connect/couchbase-sink.json`.
3. Add the collection to Terraform only if it is part of the maintained schema.
4. Add API/UI behavior in `app/ui/server.js` and `app/ui/public/index.html`.
5. Add a short runbook note only when the presenter needs to know about it.

Avoid adding long query catalogs to Markdown. Put live checks in the Operator tab so they can evolve with the code.
