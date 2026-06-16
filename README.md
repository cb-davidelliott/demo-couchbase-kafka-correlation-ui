# Couchbase Capella + Kafka + OpenTelemetry Demo

> **This is a demo tool, not a hardened implementation.**
> It is designed to be deployed for a short customer demo session and torn down immediately after.
> The VM, its services, and the Couchbase cluster it connects to should be treated as ephemeral.
>
> Before running a customer-facing demo:
> - Use a dedicated Couchbase demo cluster, not a shared or production cluster.
> - Set a strong, unique password in `.env` — do not use the example value.
> - Run `destroy.sh` / `destroy.ps1` as soon as the demo is complete.
>
> See [docs/01_DEPLOYMENT.md](docs/01_DEPLOYMENT.md) for the full security posture note.

This repo deploys a runnable enterprise incident investigation demo.

Business, support, payment, shipment, deployment, trace, log, and metric events flow through Kafka-compatible Redpanda into Couchbase Capella. The UI then shows how a demo operator can move from an incident to customer impact, root cause evidence, timeline context, trace detail, and curated live queries.

## Quick Start

1. Copy `.env.example` to `.env`.
2. Fill in Azure, Couchbase Capella, and GitHub repository values.
3. Create the Capella bucket/scope/collections from [docs/01_DEPLOYMENT.md](docs/01_DEPLOYMENT.md).
4. Deploy:

```powershell
.\deploy.ps1
```

Or on macOS/Linux:

```bash
./deploy.sh
```

5. Wait for the VM to finish bootstrapping. This may take 5-10 minutes.
6. Open:
   - Demo UI: `http://<VM_PUBLIC_IP>:3000`
   - Redpanda Console: `http://<VM_PUBLIC_IP>:8080`
   - Kafka Connect REST: `http://<VM_PUBLIC_IP>:8083`

For the full deployment path, use [docs/01_DEPLOYMENT.md](docs/01_DEPLOYMENT.md).

## What The Demo Shows

The business scenario is a customer-impacting incident in a large digital commerce environment. Multiple systems publish data independently, and Couchbase becomes the operational layer where teams can investigate the impact quickly:

- Which accounts, customers, and orders are affected?
- Which payments, shipments, and support tickets are tied to the incident?
- Which services or deployments look suspicious?
- Which traces, logs, spans, and metrics provide supporting technical evidence?
- What is the business impact and what should the operator inspect next?

## Architecture

```text
event-generator + otel-demo
        |
        v
Redpanda Kafka topics
        |
        v
Kafka Connect Couchbase Sink
        |
        v
Couchbase Capella bucket/scope/collections
        |
        v
Demo UI and Operator Queries
```

The source of truth for runtime behavior is the code:

- Docker services: [app/docker-compose.yml](app/docker-compose.yml)
- Kafka connector mapping: [app/connect/couchbase-sink.json](app/connect/couchbase-sink.json)
- Event generator: [app/generator/main.py](app/generator/main.py)
- UI/API queries: [app/ui/server.js](app/ui/server.js)
- Azure VM bootstrap: [infra/cloud-init.yaml](infra/cloud-init.yaml)

## Demo User Docs

| Document | Purpose |
| --- | --- |
| [docs/01_DEPLOYMENT.md](docs/01_DEPLOYMENT.md) | Start here: deploy, refresh, stop, and destroy the demo. |
| [docs/02_TESTING.md](docs/02_TESTING.md) | Short validation checklist after deployment or refresh. |
| [docs/03_DEMO_RUNBOOK.md](docs/03_DEMO_RUNBOOK.md) | Presenter flow for a 7 to 10 minute customer demo. |
| [docs/04_QUERIES.md](docs/04_QUERIES.md) | Query/index concepts and where to run live query checks in the UI. |
| [docs/05_ENTERPRISE_INCIDENT_DEMO_PLAN.md](docs/05_ENTERPRISE_INCIDENT_DEMO_PLAN.md) | Historical implementation checkpoint, not the daily runbook. |

## Common Operations

Validate a deployment:

```powershell
.\scripts\validate.ps1
```

Or:

```bash
./scripts/validate.sh
```

Stop data generation without destroying the VM:

```bash
cd /opt/couchbase-capella-kafka-demo
sudo docker compose --env-file .env -f app/docker-compose.yml stop event-generator
```

Refresh a running VM after pulling code changes:

```bash
cd /opt/couchbase-capella-kafka-demo
sudo ./scripts/refresh-vm.sh all
```

Destroy Azure resources:

```powershell
.\destroy.ps1
```

Or:

```bash
./destroy.sh
```

## Notes

- The demo VM is intentionally simple and inspectable. It is not a production Kafka or Couchbase sizing reference.
- Use the UI Operator tab for live query checks instead of manually copying SQL++ from docs.
- Use `.env.example` for the current list of supported deployment and generator settings.
