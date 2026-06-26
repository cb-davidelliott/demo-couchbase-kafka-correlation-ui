# Enterprise Incident Demo Runbook

This runbook is the short presenter path for the enterprise incident investigation demo. Use it when you want a repeatable 7 to 10 minute story instead of wandering through whatever data happens to be visible first.

## Pre-Demo Readiness

1. Deploy the VM and open the UI at `http://<VM_PUBLIC_IP>:3000`.
2. The default `.env` values already use the payment outage scenario — no changes needed for a standard demo. If you customized the scenario before deploying, confirm these match in the VM's `.env`:

```
GENERATOR_SCENARIO="payment_outage"
GENERATOR_INCIDENT_ID="INC-DEMO-001"
DEMO_PREFERRED_INCIDENT_ID="INC-DEMO-001"
```

`DEMO_PREFERRED_INCIDENT_ID` tells the UI which incident to auto-select on load. It should always match `GENERATOR_INCIDENT_ID`.

3. Let the generator run until the UI shows incident, order, payment, account, customer, deployment, and support data.
4. Confirm the presenter recommendations in the UI by clicking **Refresh Recommendations**.
5. Open the **Operator** tab and run **Recent data health** and **Incident blast radius**. These checks replace most manual pre-demo SQL++.

For a scale-focused rehearsal, generate high-volume business data first with `GENERATOR_PROFILE="load"` and `GENERATOR_ENABLE_OTEL_CALLS="false"`, then switch back to `GENERATOR_PROFILE="demo"` with OTel calls enabled for the polished trace/log walkthrough. The load profile is for volume; the demo profile is for the richer incident story.

## Scenario Choices

| Scenario | Best Use |
|----------|----------|
| `payment_outage` | Main enterprise incident story: checkout latency, payment declines, customer escalation, root cause in `payment-gateway`. |
| `vip_customer_impact` | Executive escalation story: SEV1 impact on high-value Platinum accounts. |
| `regional_latency` | Geographic operations story: one region experiences checkout/shipping delays. |
| `inventory_mismatch` | Release/regression story: inventory reservation failures after a deployment. |
| `recovery` | Recovery story: lower failure rate after mitigation or rollback. |
| `normal` | Baseline story: healthy traffic for comparison, not the strongest incident demo. |

Hyphenated or spaced names are accepted too, for example `regional-latency` or `vip customer impact`.

## Presenter Flow

1. Start in **Command Center**.
   Say: "This is a live operational view across business transactions, customer impact, service telemetry, and incident context."

2. Use **Recommended Demo Path**.
   Click the first card to anchor the story on the recommended incident. This keeps the demo deterministic even after fresh data generation.

3. Show **Business Impact**.
   Click the business-impact recommendation or the **Business Impact** tab. Open the recommended account or customer and call out revenue at risk, SLA tier, affected orders, payment status, shipments, and support activity.

4. Show **Root Cause**.
   Click **Root Cause** and point to the suspected service, failed payment rate, latency evidence, recent deployment evidence, representative traces, correlated logs, slow spans, and metric evidence.

5. Show **Timeline**.
   Click **Timeline** and filter the investigation sequence. Use this to show how orders, payments, shipments, tickets, deployments, logs, and spans line up around one incident.

6. Open **Trace Detail**.
   Click the recommended trace or a trace/order link from the panels. Use it to connect one customer-facing order to raw logs, spans, and source documents.

7. Show **Operator**.
   Run **Incident blast radius**, **Payment latency by service**, **OpenTelemetry coverage**, or **Metrics coverage** to show that the presenter can inspect live business and observability data without leaving the demo UI.

8. Close with the Couchbase story.
   Say: "The same platform is holding operational documents, customer context, transaction state, and observability evidence. SQL++ lets the team investigate across that model without pre-flattening every relationship."

## Backup Path

If the recommended path says data is missing, keep the VM and restart only the generator:

```bash
cd /opt/couchbase-capella-kafka-demo
sudo docker compose --env-file .env -f app/docker-compose.yml up -d --force-recreate event-generator
```

Wait 60 to 90 seconds, then refresh the UI and click **Refresh Recommendations**.

If you have enough data and want to stop the load:

```bash
cd /opt/couchbase-capella-kafka-demo
sudo docker compose --env-file .env -f app/docker-compose.yml stop event-generator
```

## What Makes The Demo Land

- Start with the incident, not with infrastructure.
- Move quickly from technical symptoms to customer and revenue impact.
- Use the timeline to prove correlation rather than explaining correlation abstractly.
- Keep one trace as the final drill-in, not the whole story.
- If a panel has sparse optional data, say it plainly and move to the recommended next step.
