# Deployment Guide

This guide is for demo users who need to get the environment running, verify it, and recover quickly if something is off.

## Security Posture

This project is a **short-lived demo tool**, not a production or hardened deployment. It is designed to be spun up before a customer demo and destroyed immediately after. The following apply by design:

- The VM's SSH port (22), Demo UI (3000), and Redpanda Console (8080) are open to the internet so the presenter and customer can access them during the session.
- Kafka Connect (8083) and the Kafka broker (9092) are **not** externally accessible. Use SSH port forwarding if local tooling is needed.
- The Couchbase password is never stored in Kafka Connect's REST API — it is resolved at runtime via environment variable only.
- No customer or production data should ever be loaded into this environment.

Before running a customer-facing demo:
- Use a **dedicated Couchbase Capella project**, not a shared or production one.
- Run `destroy.sh` / `destroy.ps1` as soon as the demo concludes — this removes both the Azure VM and the Capella cluster.

The current source of truth for settings is `.env.example`; this document describes the flow without duplicating every variable.

## Prerequisites

Install these tools on your local machine:

- Terraform
- Azure CLI 
    - Configured with your subscription
- Git
- PowerShell for Windows users, or Bash for macOS/Linux users

Verify:

```bash
terraform version
az version
git --version
```

You also need:

- An Azure subscription with quota for the VM size in `.env`.
- A Couchbase Capella organization and project (Terraform creates the cluster automatically).
- A Capella API v4 personal access token (create one in Capella UI under **Settings > API Keys**).
- A GitHub repository URL that the VM can clone (if you fork this repo, otherwise use this repo). For simplest testing, make the repo public while deploying.

## Configure

1. Get the repo onto your local machine.

If this is your first time using the project, clone it:

Windows:

```powershell
cd C:\your-git-repos
git clone https://github.com/cb-davidelliott/demo-couchbase-kafka-correlation-ui.git
cd demo-couchbase-kafka-correlation-ui
```

macOS/Linux:

```bash
mkdir -p ~/git
cd ~/git
git clone https://github.com/cb-davidelliott/demo-couchbase-kafka-correlation-ui.git
cd demo-couchbase-kafka-correlation-ui
```

If you already cloned it earlier, update your local copy:

```bash
git pull
```

2. Copy the example environment file:

```bash
cp .env.example .env
```

On Windows:

```powershell
Copy-Item .env.example .env
```

3. Edit `.env`.

Required values:

- `AZURE_SUBSCRIPTION_ID`
- `AZURE_LOCATION`
- `AZURE_VM_SIZE`
- `GITHUB_REPO_URL`
- `CAPELLA_AUTH_TOKEN` — Capella API v4 personal access token
- `CAPELLA_ORGANIZATION_ID` — visible in any Capella URL after `/organizations/`
- `CAPELLA_PROJECT_ID` — visible in the Capella project URL

Terraform creates the Capella cluster, bucket, scope, collections, and database credentials automatically. No manual Capella setup is required.

Load and scenario settings live in `.env.example`. Prefer changing that file/template instead of hard-coding settings in docs.

## Deploy

Windows:

```powershell
.\deploy.ps1
```

macOS/Linux:

```bash
./deploy.sh
```

The deployment creates the Capella cluster (~15 min), Azure infrastructure, writes a VM SSH key, runs cloud-init, clones the repo on the VM, starts Docker Compose, and registers the Couchbase Kafka connector. **First deploy takes approximately 20 minutes.**

When the script finishes, keep the public IP it prints.

## First Checks

Open:

- Demo UI: `http://<VM_PUBLIC_IP>:3000`
- Redpanda Console: `http://<VM_PUBLIC_IP>:8080`

Kafka Connect (8083) is internal — use SSH port forwarding to reach it: `ssh -L 8083:localhost:8083 -i <key.pem> azureuser@<VM_IP>`.

On a fresh deploy the UI may show a **"planning failure"** banner for 2-3 minutes while indexes build and the first events flow in. This clears on its own — refresh the page once the incident list appears.

Run validation from your local repo:

```powershell
.\scripts\validate.ps1
```

Or:

```bash
./scripts/validate.sh
```

If the UI is up but data is sparse, give the generator another minute and refresh the UI recommendations.

## Demo Flow After Deploy

Use [03_DEMO_RUNBOOK.md](03_DEMO_RUNBOOK.md) for the presenter path.

The fastest readiness check is in the UI:

1. Open the Demo UI.
2. Confirm an incident appears.
3. Click **Refresh Recommendations**.
4. Open the **Operator** tab.
5. Run **Recent data health** and **Incident blast radius**.

## VM Refresh During Development

When you change code and do not want to destroy/redeploy the VM:

```bash
cd /opt/couchbase-capella-kafka-demo
sudo ./scripts/refresh-vm.sh all
```

The refresh script pulls from Git on the VM before rebuilding services. Use this after you have committed and pushed local changes.

Useful narrower refreshes:

```bash
sudo ./scripts/refresh-vm.sh generator
sudo ./scripts/refresh-vm.sh ui
sudo ./scripts/refresh-vm.sh connect
sudo ./scripts/refresh-vm.sh otel
sudo ./scripts/refresh-vm.sh status
```

The refresh script is for dev/debug speed. A clean destroy/deploy is still the best final demo rehearsal.

## Stop Or Resume Data Generation

Stop load without destroying the VM:

```bash
cd /opt/couchbase-capella-kafka-demo
sudo docker compose --env-file .env -f app/docker-compose.yml stop event-generator
```

This stops new messages from the generator, but Kafka Connect may continue writing existing Kafka backlog into Couchbase. To stop Couchbase writes immediately during a load test, stop Kafka Connect too:

```bash
sudo docker compose --env-file .env -f app/docker-compose.yml stop kafka-connect
```

Resume Couchbase writes:

```bash
sudo docker compose --env-file .env -f app/docker-compose.yml up -d kafka-connect
```

Start it again:

```bash
sudo docker compose --env-file .env -f app/docker-compose.yml up -d event-generator
```

Change scenario or load settings on the VM by editing `/opt/couchbase-capella-kafka-demo/.env`, then recreate the generator:

```bash
sudo docker compose --env-file .env -f app/docker-compose.yml up -d --force-recreate event-generator
```

For high-volume document generation, set the load profile in the VM `.env` before recreating the generator:

```bash
GENERATOR_PROFILE="load"
GENERATOR_SCENARIO="payment_outage"
GENERATOR_INCIDENT_ID="INC-DEMO-001"
GENERATOR_INTERVAL_SECONDS="0"
GENERATOR_EVENTS_PER_BATCH="5000"
GENERATOR_ENABLE_OTEL_CALLS="false"
GENERATOR_NEW_CUSTOMER_PROBABILITY="1.0"
GENERATOR_TICKET_PROBABILITY="1.0"
GENERATOR_UNIQUE_METRIC_DOCS="true"
GENERATOR_LOG_EVERY_N_EVENTS="10000"
GENERATOR_FLUSH_EVERY_N_EVENTS="50000"
GENERATOR_INCIDENT_UPDATE_EVERY_N_EVENTS="1000"
GENERATOR_MAX_ACTIVE_CUSTOMERS="500"
```

Set `DEMO_PREFERRED_INCIDENT_ID` to the same value as `GENERATOR_INCIDENT_ID` so the UI auto-selects the correct incident on load:

```bash
DEMO_PREFERRED_INCIDENT_ID="INC-DEMO-001"
```

Then restart:

```bash
sudo docker compose --env-file .env -f app/docker-compose.yml build event-generator
sudo docker compose --env-file .env -f app/docker-compose.yml up -d --no-deps --force-recreate event-generator
sudo docker compose --env-file .env -f app/docker-compose.yml logs -f event-generator
```

For more generation throughput from the VM, scale the generator service. This creates more source producers; it does not guarantee Couchbase ingest rate unless Redpanda, Kafka Connect, and Capella have enough capacity.

For multi-replica load runs, consider setting `GENERATOR_ENABLE_INCIDENT_UPDATES="false"` so each generator does not rewrite the same incident summary document with its own local counters.

```bash
sudo docker compose --env-file .env -f app/docker-compose.yml up -d --scale event-generator=2 event-generator
```

## Troubleshooting

Use these in order.

1. Check service status:

```bash
cd /opt/couchbase-capella-kafka-demo
sudo docker compose --env-file .env -f app/docker-compose.yml ps
```

2. Check bootstrap logs:

```bash
sudo tail -120 /var/log/cloud-init-output.log
sudo tail -120 /var/log/cb-demo-compose.log
sudo tail -120 /var/log/cb-connector-setup.log
```

3. Check the connector:

```bash
curl -s http://localhost:8083/connectors | jq .
curl -s http://localhost:8083/connectors/couchbase-sink-connector/status | jq .
````

4. Check generator and connector logs:

```bash
sudo docker compose --env-file .env -f app/docker-compose.yml logs --tail=80 event-generator
sudo docker logs kafka-connect --tail=120
```

Common causes:

- Capella cluster or allowedCIDR not yet ready (check `terraform output couchbase_connection_string`).
- Couchbase credentials or bucket/scope values are wrong (check `terraform output couchbase_username`).
- The GitHub repo is not accessible from the VM.
- The VM is temporarily resource constrained while Docker images build or containers start.

## Cleanup

Destroy Azure resources:

```powershell
.\destroy.ps1
```

Or:

```bash
./destroy.sh
```

The destroy script removes both Azure resources and the Capella cluster (it was created by Terraform, so it is destroyed by Terraform).
