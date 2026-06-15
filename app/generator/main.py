#!/usr/bin/env python
import os
import sys
import json
import time
import random
import uuid
import logging
import re
import requests
from confluent_kafka import Producer

# Setup Logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("event-generator")

# Load environment configs
BOOTSTRAP_SERVERS = os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "redpanda:29092")
GENERATOR_PROFILE = os.environ.get("GENERATOR_PROFILE", "demo").strip().lower()
if GENERATOR_PROFILE not in ["demo", "load"]:
    logger.warning(f"Unknown GENERATOR_PROFILE '{GENERATOR_PROFILE}'. Falling back to demo.")
    GENERATOR_PROFILE = "demo"

def env_value(name, demo_default, load_default=None):
    if name in os.environ and str(os.environ[name]).strip() != "":
        return os.environ[name]
    return load_default if GENERATOR_PROFILE == "load" and load_default is not None else demo_default

def parse_bool(value):
    return str(value).strip().lower() in ["1", "true", "yes", "y", "on"]

def parse_int(name, demo_default, load_default=None, minimum=None):
    try:
        value = int(env_value(name, demo_default, load_default))
    except ValueError:
        logger.warning(f"Invalid {name} value; using default {demo_default}")
        value = int(demo_default)
    return max(minimum, value) if minimum is not None else value

def parse_float(name, demo_default, load_default=None, minimum=None):
    try:
        value = float(env_value(name, demo_default, load_default))
    except ValueError:
        logger.warning(f"Invalid {name} value; using default {demo_default}")
        value = float(demo_default)
    return max(minimum, value) if minimum is not None else value

def parse_probability(name, demo_default, load_default=None):
    return min(1.0, max(0.0, parse_float(name, demo_default, load_default)))

GEN_INTERVAL = parse_float("GENERATOR_INTERVAL_SECONDS", "5.0", "0", minimum=0.0)
EVENTS_PER_BATCH = parse_int("GENERATOR_EVENTS_PER_BATCH", "1", "5000", minimum=1)
OTEL_DEMO_URL = os.environ.get("OTEL_DEMO_URL", "http://otel-demo:5000")
ENABLE_OTEL_CALLS = parse_bool(env_value("GENERATOR_ENABLE_OTEL_CALLS", "true", "false"))
NEW_CUSTOMER_PROBABILITY = parse_probability("GENERATOR_NEW_CUSTOMER_PROBABILITY", "0.2", "1.0")
TICKET_PROBABILITY = parse_probability("GENERATOR_TICKET_PROBABILITY", "0.25", "1.0")
UNIQUE_METRIC_DOCS = parse_bool(env_value("GENERATOR_UNIQUE_METRIC_DOCS", "false", "true"))
ENABLE_METRICS = parse_bool(env_value("GENERATOR_ENABLE_METRICS", "true", "true"))
ENABLE_INCIDENT_UPDATES = parse_bool(env_value("GENERATOR_ENABLE_INCIDENT_UPDATES", "true", "true"))
LOG_EVERY_N_EVENTS = parse_int("GENERATOR_LOG_EVERY_N_EVENTS", "1", "10000", minimum=0)
INCIDENT_UPDATE_EVERY_N_EVENTS = parse_int("GENERATOR_INCIDENT_UPDATE_EVERY_N_EVENTS", "1", "1000", minimum=1)
FLUSH_EVERY_N_EVENTS = parse_int("GENERATOR_FLUSH_EVERY_N_EVENTS", str(EVENTS_PER_BATCH), "50000", minimum=0)
PRODUCER_LINGER_MS = parse_int("GENERATOR_PRODUCER_LINGER_MS", "5", "20", minimum=0)
PRODUCER_BATCH_NUM_MESSAGES = parse_int("GENERATOR_PRODUCER_BATCH_NUM_MESSAGES", "10000", "100000", minimum=1)
PRODUCER_QUEUE_MAX_MESSAGES = parse_int("GENERATOR_PRODUCER_QUEUE_MAX_MESSAGES", "100000", "1000000", minimum=1000)
PRODUCER_COMPRESSION = env_value("GENERATOR_PRODUCER_COMPRESSION", "lz4", "lz4")
GENERATOR_SCENARIO = re.sub(r"[\s-]+", "_", env_value("GENERATOR_SCENARIO", "normal").strip().lower())
GENERATOR_INCIDENT_ID = os.environ.get("GENERATOR_INCIDENT_ID", "").strip()
GENERATOR_RANDOM_SEED = os.environ.get("GENERATOR_RANDOM_SEED", "").strip()

try:
    ENTERPRISE_ACCOUNT_COUNT = max(10, int(env_value("GENERATOR_ENTERPRISE_ACCOUNT_COUNT", "30")))
except ValueError:
    logger.warning("Invalid GENERATOR_ENTERPRISE_ACCOUNT_COUNT value; defaulting to 30")
    ENTERPRISE_ACCOUNT_COUNT = 30

if GENERATOR_RANDOM_SEED:
    random.seed(GENERATOR_RANDOM_SEED)

# Static mock data lists
FIRST_NAMES = ["Alice", "Bob", "Charlie", "David", "Emma", "Frank", "Grace", "Henry", "Ivy", "Jack", "Karl", "Lily", "Mia", "Noah", "Olivia", "Peter", "Ryan", "Sophia", "Tom", "Zoe"]
LAST_NAMES = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez", "Wilson", "Anderson", "Thomas", "Taylor", "Moore"]
COUNTRIES = ["US", "CA", "GB", "DE", "FR", "AU", "JP", "BR", "IN", "ZA"]
REGIONS = ["us-east", "us-west", "eu-central", "ap-south", "ap-northeast"]
INDUSTRIES = ["Financial Services", "Retail", "Healthcare", "Manufacturing", "Telecommunications", "Travel"]
SLA_TIERS = ["Platinum", "Gold", "Silver"]
ACCOUNT_NAMES = [
    "Apex Global Bank", "Northstar Retail Group", "Meridian Health Network",
    "Summit Manufacturing", "Brightline Telecom", "Pioneer Logistics",
    "BluePeak Insurance", "Vertex Energy", "Atlas Travel Holdings", "Crescent Media"
]
SERVICE_CATALOG = [
    {"serviceName": "checkout-api", "ownerTeam": "Digital Commerce", "sloTargetMs": 250, "dependencies": ["payment-gateway", "inventory-service", "identity-service"]},
    {"serviceName": "payment-gateway", "ownerTeam": "Payments Platform", "sloTargetMs": 180, "dependencies": ["fraud-scoring", "identity-service"]},
    {"serviceName": "inventory-service", "ownerTeam": "Supply Chain", "sloTargetMs": 220, "dependencies": ["catalog-service"]},
    {"serviceName": "shipping-service", "ownerTeam": "Fulfillment", "sloTargetMs": 300, "dependencies": ["inventory-service"]},
    {"serviceName": "identity-service", "ownerTeam": "Core Platform", "sloTargetMs": 120, "dependencies": []},
    {"serviceName": "support-portal", "ownerTeam": "Customer Experience", "sloTargetMs": 350, "dependencies": ["identity-service"]},
    {"serviceName": "observability-ingest", "ownerTeam": "SRE", "sloTargetMs": 500, "dependencies": ["kafka-connect"]},
    {"serviceName": "kafka-connect", "ownerTeam": "Data Platform", "sloTargetMs": 400, "dependencies": ["redpanda"]}
]
SCENARIO_PROFILES = {
    "normal": {
        "title": "Normal enterprise traffic baseline",
        "severity": "SEV4",
        "status": "MONITORING",
        "affectedServices": [],
        "attachProbability": 0.02,
        "paymentFailureProbability": 0.02,
        "ticketProbabilityBoost": 0.0,
        "orderStatus": "CREATED",
        "paymentLatencyRange": (80, 320),
        "shipmentDelayReason": None,
        "estimatedRevenueImpact": 0
    },
    "payment_outage": {
        "title": "Elevated checkout payment latency",
        "severity": "SEV2",
        "status": "ACTIVE",
        "affectedServices": ["checkout-api", "payment-gateway"],
        "attachProbability": 0.72,
        "paymentFailureProbability": 0.78,
        "ticketProbabilityBoost": 0.45,
        "orderStatus": "PAYMENT_REVIEW",
        "paymentLatencyRange": (1100, 3200),
        "shipmentDelayReason": "payment_authorization_pending",
        "estimatedRevenueImpact": 275000
    },
    "regional_latency": {
        "title": "Regional checkout latency spike",
        "severity": "SEV2",
        "status": "ACTIVE",
        "affectedServices": ["checkout-api", "inventory-service", "shipping-service"],
        "attachProbability": 0.62,
        "paymentFailureProbability": 0.18,
        "ticketProbabilityBoost": 0.35,
        "orderStatus": "DELAYED",
        "paymentLatencyRange": (350, 900),
        "shipmentDelayReason": "regional_fulfillment_latency",
        "estimatedRevenueImpact": 180000
    },
    "inventory_mismatch": {
        "title": "Inventory reservation mismatch after deployment",
        "severity": "SEV2",
        "status": "ACTIVE",
        "affectedServices": ["checkout-api", "inventory-service"],
        "attachProbability": 0.68,
        "paymentFailureProbability": 0.08,
        "ticketProbabilityBoost": 0.4,
        "orderStatus": "INVENTORY_REVIEW",
        "paymentLatencyRange": (90, 360),
        "shipmentDelayReason": "inventory_reservation_failed",
        "estimatedRevenueImpact": 210000
    },
    "vip_customer_impact": {
        "title": "High-value account checkout degradation",
        "severity": "SEV1",
        "status": "ACTIVE",
        "affectedServices": ["checkout-api", "payment-gateway", "support-portal"],
        "attachProbability": 0.86,
        "paymentFailureProbability": 0.52,
        "ticketProbabilityBoost": 0.55,
        "orderStatus": "ESCALATED",
        "paymentLatencyRange": (800, 2400),
        "shipmentDelayReason": "vip_order_escalated",
        "estimatedRevenueImpact": 550000,
        "vipOnly": True
    },
    "recovery": {
        "title": "Payment incident recovery in progress",
        "severity": "SEV3",
        "status": "RECOVERING",
        "affectedServices": ["checkout-api", "payment-gateway"],
        "attachProbability": 0.28,
        "paymentFailureProbability": 0.12,
        "ticketProbabilityBoost": 0.12,
        "orderStatus": "RECOVERING",
        "paymentLatencyRange": (250, 800),
        "shipmentDelayReason": None,
        "estimatedRevenueImpact": 95000
    }
}
if GENERATOR_SCENARIO not in SCENARIO_PROFILES:
    logger.warning(f"Unknown GENERATOR_SCENARIO '{GENERATOR_SCENARIO}'. Falling back to normal.")
    GENERATOR_SCENARIO = "normal"
SCENARIO = SCENARIO_PROFILES[GENERATOR_SCENARIO]
PRODUCT_CATALOG = [
    {"product_name": "Premium Cloud Database Subscription", "price": 199.99, "category": "software"},
    {"product_name": "Developer Support Plan - Monthly", "price": 49.99, "category": "support"},
    {"product_name": "Enterprise Analytics Dashboard", "price": 899.99, "category": "software"},
    {"product_name": "Couchbase Capella Quickstart Guide eBook", "price": 14.99, "category": "education"},
    {"product_name": "High-Throughput Kafka Connector License", "price": 120.00, "category": "software"},
    {"product_name": "Custom Professional Services Pack (5 Hours)", "price": 750.00, "category": "consulting"}
]
PAYMENT_PROCESSORS = ["Adyen", "Stripe", "Worldpay", "Fiserv"]
PAYMENT_DECLINE_REASONS = ["insufficient_funds", "processor_timeout", "fraud_review", "card_expired"]
FULFILLMENT_CENTERS = ["DFW-01", "PHX-02", "ATL-03", "AMS-01", "SIN-01"]
SHIPPING_CARRIERS = ["FedEx", "UPS", "DHL", "USPS"]
TICKET_ISSUES = [
    "Unable to connect to database using SDK",
    "Latency spikes observed during queries",
    "Billing credit not showing in account",
    "Failed to configure custom Kafka Sink Connector",
    "Access denied on Default Scope",
    "Documentation link returns 404 error"
]

active_customers = []
customer_profiles = {}
enterprise_accounts = []
enterprise_services = []
enterprise_incidents = []
scenario_state = {
    "affectedOrders": 0,
    "affectedCustomers": set(),
    "revenueAtRisk": 0.0,
    "activeRegion": None
}
metrics_counters = {
    "orders_created": 0,
    "tickets_created": 0,
    "total_revenue": 0.0
}
runtime_counters = {
    "events_generated": 0,
    "messages_produced": 0,
    "last_log_time": time.time()
}

def now_ms():
    return int(time.time() * 1000)

def delivery_report(err, msg):
    """ Callback for message delivery reports. """
    if err is not None:
        logger.error(f"Message delivery failed: {err}")
    else:
        logger.debug(f"Published to {msg.topic()} [partition {msg.partition()}] with key: {msg.key().decode('utf-8') if msg.key() else 'None'}")

def produce_message(producer, topic, key, value):
    """Produce with backpressure handling so high-volume mode does not fail on a full local queue."""
    while True:
        try:
            producer.produce(topic=topic, key=key, value=value, callback=delivery_report)
            runtime_counters["messages_produced"] += 1
            return
        except BufferError:
            producer.poll(0.1)

def maybe_log_progress(force=False):
    if LOG_EVERY_N_EVENTS <= 0 and not force:
        return
    events = runtime_counters["events_generated"]
    if not force and events % LOG_EVERY_N_EVENTS != 0:
        return

    elapsed = max(0.001, time.time() - runtime_counters["last_log_time"])
    logger.info(
        "Generator progress: "
        f"events={events}, messages={runtime_counters['messages_produced']}, "
        f"orders={metrics_counters['orders_created']}, tickets={metrics_counters['tickets_created']}, "
        f"active_customers={len(active_customers)}, approx_recent_rate={LOG_EVERY_N_EVENTS / elapsed if LOG_EVERY_N_EVENTS > 0 else 0:.1f} events/sec"
    )
    runtime_counters["last_log_time"] = time.time()

def build_enterprise_accounts():
    accounts = []
    divisions = ["Commercial", "Digital", "Global", "Enterprise"]
    for index in range(1, ENTERPRISE_ACCOUNT_COUNT + 1):
        base_name = ACCOUNT_NAMES[(index - 1) % len(ACCOUNT_NAMES)]
        name = base_name if index <= len(ACCOUNT_NAMES) else f"{base_name} {random.choice(divisions)}"
        sla_tier = random.choices(SLA_TIERS, weights=[2, 4, 4], k=1)[0]
        arr_multiplier = {"Platinum": 12, "Gold": 6, "Silver": 2}[sla_tier]
        account_id = f"ACCT-{index:04d}"
        accounts.append({
            "accountId": account_id,
            "name": name,
            "industry": random.choice(INDUSTRIES),
            "region": random.choice(REGIONS),
            "slaTier": sla_tier,
            "annualRecurringRevenue": random.randint(250000, 900000) * arr_multiplier,
            "accountOwner": f"{random.choice(FIRST_NAMES)} {random.choice(LAST_NAMES)}",
            "supportPlan": "Enterprise" if sla_tier in ["Platinum", "Gold"] else "Business",
            "createdTime": now_ms()
        })
    if not any(account["slaTier"] == "Platinum" for account in accounts):
        accounts[0]["slaTier"] = "Platinum"
        accounts[0]["supportPlan"] = "Enterprise"
        accounts[0]["annualRecurringRevenue"] = max(accounts[0]["annualRecurringRevenue"], 9000000)
    return accounts

def build_enterprise_services():
    services = []
    for service in SERVICE_CATALOG:
        services.append({
            **service,
            "serviceId": f"SVC-{service['serviceName'].upper().replace('-', '_')}",
            "currentVersion": f"v{random.randint(2, 8)}.{random.randint(0, 9)}.{random.randint(0, 30)}",
            "region": random.choice(REGIONS),
            "status": "HEALTHY",
            "updatedTime": now_ms()
        })
    return services

def build_enterprise_incidents():
    active_region = random.choice(REGIONS)
    scenario_state["activeRegion"] = active_region
    incident_id = GENERATOR_INCIDENT_ID or f"INC-{GENERATOR_SCENARIO.upper().replace('-', '_')}"
    active_incident = {
        "incidentId": incident_id,
        "scenario": GENERATOR_SCENARIO,
        "title": SCENARIO["title"],
        "severity": SCENARIO["severity"],
        "status": SCENARIO["status"],
        "affectedServices": SCENARIO["affectedServices"],
        "affectedRegions": [active_region] if SCENARIO["affectedServices"] else [],
        "estimatedRevenueImpact": SCENARIO["estimatedRevenueImpact"],
        "actualRevenueAtRisk": 0,
        "affectedOrderCount": 0,
        "affectedCustomerCount": 0,
        "startedAt": now_ms() - 15 * 60 * 1000,
        "resolvedAt": now_ms() - 3 * 60 * 1000 if GENERATOR_SCENARIO == "recovery" else None,
        "ownerTeam": "Payments Platform" if "payment-gateway" in SCENARIO["affectedServices"] else "SRE"
    }

    return [
        active_incident,
        {
            "incidentId": "INC-OBS-BASELINE",
            "title": "Baseline observability reference incident",
            "severity": "SEV4",
            "status": "MONITORING",
            "affectedServices": ["observability-ingest"],
            "affectedRegions": [random.choice(REGIONS)],
            "estimatedRevenueImpact": 0,
            "startedAt": now_ms() - 60 * 60 * 1000,
            "resolvedAt": None,
            "ownerTeam": "SRE"
        }
    ]

def update_incident_impact(producer, incident, order_total, customer_id):
    if not incident or incident["scenario"] == "normal":
        return

    scenario_state["affectedOrders"] += 1
    scenario_state["affectedCustomers"].add(customer_id)
    scenario_state["revenueAtRisk"] += order_total

    if not ENABLE_INCIDENT_UPDATES:
        return

    incident_update = {
        **incident,
        "actualRevenueAtRisk": round(scenario_state["revenueAtRisk"], 2),
        "affectedOrderCount": scenario_state["affectedOrders"],
        "affectedCustomerCount": len(scenario_state["affectedCustomers"]),
        "updatedTime": now_ms()
    }
    if scenario_state["affectedOrders"] == 1 or scenario_state["affectedOrders"] % INCIDENT_UPDATE_EVERY_N_EVENTS == 0:
        produce_message(producer, "incidents", incident_update["incidentId"], json.dumps(incident_update))

def publish_reference_data(producer):
    for account in enterprise_accounts:
        produce_message(producer, "accounts", account["accountId"], json.dumps(account))

    for service in enterprise_services:
        produce_message(producer, "services", service["serviceId"], json.dumps(service))
        linked_incident = next(
            (
                incident for incident in enterprise_incidents
                if service["serviceName"] in incident.get("affectedServices", [])
                and incident.get("scenario") == GENERATOR_SCENARIO
                and incident.get("scenario") != "normal"
            ),
            None
        )
        deployment = {
            "deploymentId": f"DEP-{service['serviceName'].upper().replace('-', '_')}-{uuid.uuid4().hex[:8].upper()}",
            "serviceName": service["serviceName"],
            "version": service["currentVersion"],
            "commit": uuid.uuid4().hex[:12],
            "deployedBy": service["ownerTeam"],
            "region": service["region"],
            "status": "ROLLED_BACK" if linked_incident and GENERATOR_SCENARIO == "recovery" else "SUCCESS",
            "incidentId": linked_incident["incidentId"] if linked_incident else None,
            "changeRisk": "HIGH" if linked_incident else random.choice(["LOW", "MEDIUM"]),
            "timestamp": (linked_incident["startedAt"] - 8 * 60 * 1000) if linked_incident else now_ms() - random.randint(10, 240) * 60 * 1000
        }
        produce_message(producer, "deployments", deployment["deploymentId"], json.dumps(deployment))

    for incident in enterprise_incidents:
        produce_message(producer, "incidents", incident["incidentId"], json.dumps(incident))
        logger.info(
            "Published incident reference: "
            f"{incident['incidentId']} scenario={incident.get('scenario', 'baseline')} "
            f"status={incident.get('status')}"
        )

    logger.info(
        f"Seeded enterprise reference data: {len(enterprise_accounts)} accounts, "
        f"{len(enterprise_services)} services, {len(enterprise_incidents)} incidents"
    )

def select_account():
    platinum = [account for account in enterprise_accounts if account["slaTier"] == "Platinum"]
    active_region = scenario_state.get("activeRegion")
    if GENERATOR_SCENARIO == "regional_latency" and active_region:
        regional_accounts = [account for account in enterprise_accounts if account["region"] == active_region]
        if regional_accounts:
            return random.choice(regional_accounts)
    if SCENARIO.get("vipOnly") and platinum:
        regional_platinum = [account for account in platinum if active_region and account["region"] == active_region]
        if regional_platinum:
            return random.choice(regional_platinum)
        return random.choice(platinum)
    if platinum and random.random() < 0.35:
        return random.choice(platinum)
    return random.choice(enterprise_accounts)

def maybe_active_incident(service_name, region):
    scenario_incident = next((incident for incident in enterprise_incidents if incident.get("scenario") == GENERATOR_SCENARIO), None)
    if not scenario_incident or scenario_incident["scenario"] == "normal":
        return None
    if SCENARIO.get("vipOnly") and service_name not in scenario_incident["affectedServices"]:
        return None
    if service_name in scenario_incident["affectedServices"] or region in scenario_incident["affectedRegions"]:
        return scenario_incident if random.random() < SCENARIO["attachProbability"] else None
    return scenario_incident if random.random() < min(0.12, SCENARIO["attachProbability"] / 4) else None

def generate_customer():
    cust_id = f"CUST-{uuid.uuid4().hex[:12].upper()}"
    account = select_account()
    customer = {
        "customerId": cust_id,
        "accountId": account["accountId"],
        "accountName": account["name"],
        "slaTier": account["slaTier"],
        "name": f"{random.choice(FIRST_NAMES)} {random.choice(LAST_NAMES)}",
        "email": f"{cust_id.lower()}@demo-observability.io",
        "country": random.choice(COUNTRIES),
        "region": account["region"],
        "createdTime": now_ms()
    }
    return cust_id, customer

def publish_metric(producer, metric_name, metric_value, metric_unit, attributes=None):
    """Publish a metric to the metrics topic."""
    if not ENABLE_METRICS:
        return

    metric_key = metric_name
    if UNIQUE_METRIC_DOCS:
        metric_key = f"{metric_name}-{int(time.time() * 1000)}-{uuid.uuid4().hex[:8]}"

    metric_doc = {
        "resourceMetrics": [{
            "scopeMetrics": [{
                "metrics": [{
                    "name": metric_name,
                    "gauge": {
                        "dataPoints": [{
                            "asInt": int(metric_value) if metric_unit == "1" else int(metric_value * 100),
                            "attributes": attributes or {},
                            "timeUnixNano": int(time.time() * 1e9)
                        }]
                    } if metric_unit == "1" else {
                        "sum": {
                            "dataPoints": [{
                                "asDouble": float(metric_value),
                                "attributes": attributes or {},
                                "timeUnixNano": int(time.time() * 1e9)
                            }]
                        }
                    },
                    "unit": metric_unit
                }]
            }]
        }]
    }
    produce_message(producer, "metrics", metric_key, json.dumps(metric_doc))

def trigger_otel_browse(session_id):
    """ Triggers a browse transaction in the OTel Demo app """
    try:
        requests.get(f"{OTEL_DEMO_URL}/api/browse", params={"sessionId": session_id}, timeout=3)
    except Exception as e:
        logger.warning(f"Failed to trigger OTel browse trace: {e}")

def trigger_otel_checkout(cust_id, order_id, session_id, total, country):
    """ Triggers a checkout transaction in the OTel Demo app and returns the traceId """
    try:
        res = requests.post(
            f"{OTEL_DEMO_URL}/api/checkout",
            params={
                "customerId": cust_id,
                "orderId": order_id,
                "sessionId": session_id,
                "totalAmount": total,
                "country": country
            },
            timeout=3
        )
        if res.status_code == 200:
            return res.json().get("traceId")
    except Exception as e:
        logger.warning(f"Failed to trigger OTel checkout trace: {e}")
    # Return placeholder trace ID if OTel demo app is unreachable
    return uuid.uuid4().hex

def trigger_otel_ticket(cust_id, order_id, ticket_id, issue):
    """ Triggers a ticket event trace in the OTel Demo app """
    try:
        requests.post(
            f"{OTEL_DEMO_URL}/api/ticket",
            params={
                "customerId": cust_id,
                "orderId": order_id,
                "ticketId": ticket_id,
                "issueType": issue
            },
            timeout=3
        )
    except Exception as e:
        logger.warning(f"Failed to trigger OTel ticket trace: {e}")

def generate_event(producer):
    # 1. Select or create customer
    if len(active_customers) < 10 or random.random() < NEW_CUSTOMER_PROBABILITY:
        cust_id, customer_doc = generate_customer()
        active_customers.append(cust_id)
        customer_profiles[cust_id] = customer_doc
        produce_message(producer, "customers", cust_id, json.dumps(customer_doc))
        logger.debug(f"Created new customer: {cust_id}")
    else:
        cust_id = random.choice(active_customers)
        customer_doc = customer_profiles.get(cust_id)
        if not customer_doc:
            cust_id, customer_doc = generate_customer()
            active_customers.append(cust_id)
            customer_profiles[cust_id] = customer_doc

    # 2. Simulate Browsing (Triggers OTel browse trace)
    session_id = f"SESS-{uuid.uuid4().hex[:12].upper()}"
    logger.debug(f"Simulating browse session: {session_id}")
    if ENABLE_OTEL_CALLS:
        trigger_otel_browse(session_id)

    # 3. Simulate Checkout (Triggers OTel checkout trace, gets traceId)
    order_id = f"ORD-{uuid.uuid4().hex[:12].upper()}"
    items = random.sample(PRODUCT_CATALOG, k=random.randint(1, 3))
    total = sum(item["price"] for item in items)
    commerce_services = [svc for svc in enterprise_services if svc["serviceName"] in ["checkout-api", "payment-gateway", "inventory-service", "shipping-service"]]
    affected_services = [svc for svc in commerce_services if svc["serviceName"] in SCENARIO["affectedServices"]]
    if affected_services and GENERATOR_SCENARIO != "normal" and random.random() < 0.7:
        service = random.choice(affected_services)
    else:
        service = random.choice(commerce_services)
    incident = maybe_active_incident(service["serviceName"], customer_doc.get("region", "us-east"))
    order_status = SCENARIO["orderStatus"] if incident else "CREATED"
    
    # Hit OTel Demo app to generate trace and retrieve traceId
    if ENABLE_OTEL_CALLS:
        trace_id = trigger_otel_checkout(cust_id, order_id, session_id, total, customer_doc.get("country", "US"))
    else:
        trace_id = uuid.uuid4().hex
    
    order_doc = {
        "orderId": order_id,
        "customerId": cust_id,
        "accountId": customer_doc.get("accountId"),
        "accountName": customer_doc.get("accountName"),
        "sessionId": session_id,
        "traceId": trace_id,
        "incidentId": incident["incidentId"] if incident else None,
        "items": items,
        "totalAmount": round(total, 2),
        "currency": "USD",
        "channel": random.choice(["web", "mobile", "partner_api", "call_center"]),
        "status": order_status,
        "region": customer_doc.get("region"),
        "serviceName": service["serviceName"],
        "hostId": os.environ.get("HOSTNAME", "event-generator-host"),
        "orderTime": now_ms()
    }
    produce_message(producer, "orders", order_id, json.dumps(order_doc))
    logger.debug(f"Created order: {order_id} with traceId: {trace_id}")

    payment_id = f"PAY-{uuid.uuid4().hex[:12].upper()}"
    payment_failed = incident is not None and random.random() < SCENARIO["paymentFailureProbability"]
    latency_min, latency_max = SCENARIO["paymentLatencyRange"] if incident else (80, 320)
    payment_doc = {
        "paymentId": payment_id,
        "orderId": order_id,
        "customerId": cust_id,
        "accountId": customer_doc.get("accountId"),
        "traceId": trace_id,
        "incidentId": incident["incidentId"] if incident else None,
        "processor": random.choice(PAYMENT_PROCESSORS),
        "authorizationStatus": "DECLINED" if payment_failed else "AUTHORIZED",
        "declineReason": random.choice(PAYMENT_DECLINE_REASONS) if payment_failed else None,
        "amount": round(total, 2),
        "currency": "USD",
        "latencyMs": random.randint(latency_min, latency_max),
        "serviceName": "payment-gateway",
        "createdTime": now_ms()
    }
    produce_message(producer, "payments", payment_id, json.dumps(payment_doc))

    shipment_id = f"SHP-{uuid.uuid4().hex[:12].upper()}"
    shipment_doc = {
        "shipmentId": shipment_id,
        "orderId": order_id,
        "customerId": cust_id,
        "accountId": customer_doc.get("accountId"),
        "traceId": trace_id,
        "incidentId": incident["incidentId"] if incident and (payment_failed or random.random() < 0.55) else None,
        "fulfillmentCenter": random.choice(FULFILLMENT_CENTERS),
        "carrier": random.choice(SHIPPING_CARRIERS),
        "status": "PENDING_PAYMENT" if payment_failed else ("DELAYED" if incident and SCENARIO["shipmentDelayReason"] else random.choice(["QUEUED", "PICKING", "READY_TO_SHIP"])),
        "delayReason": SCENARIO["shipmentDelayReason"] if incident and (payment_failed or SCENARIO["shipmentDelayReason"]) else None,
        "region": customer_doc.get("region"),
        "serviceName": "shipping-service",
        "createdTime": now_ms()
    }
    produce_message(producer, "shipments", shipment_id, json.dumps(shipment_doc))
    update_incident_impact(producer, incident, total, cust_id)
    
    # Publish order metrics
    metrics_counters["orders_created"] += 1
    metrics_counters["total_revenue"] += total
    publish_metric(producer, "demo_orders_total", metrics_counters["orders_created"], "1", {"country": customer_doc.get("country", "US"), "accountId": customer_doc.get("accountId")})
    publish_metric(producer, "demo_revenue_usd", metrics_counters["total_revenue"], "USD", {"region": customer_doc.get("region", "unknown")})

    # 4. Simulate Random Ticket (25% chance)
    effective_ticket_probability = min(1.0, TICKET_PROBABILITY + (SCENARIO["ticketProbabilityBoost"] if incident else 0.0))
    if random.random() < effective_ticket_probability:
        ticket_id = f"TCK-{uuid.uuid4().hex[:12].upper()}"
        issue = random.choice(TICKET_ISSUES)
        
        # Trigger OTel ticket log/trace/metric
        if ENABLE_OTEL_CALLS:
            trigger_otel_ticket(cust_id, order_id, ticket_id, issue)
        
        ticket_doc = {
            "ticketId": ticket_id,
            "customerId": cust_id,
            "accountId": customer_doc.get("accountId"),
            "orderId": order_id,
            "traceId": trace_id,
            "incidentId": incident["incidentId"] if incident else None,
            "issueType": issue,
            "status": "OPEN",
            "severity": random.choice(["SEV2", "SEV3", "SEV4"]) if incident else random.choice(["SEV3", "SEV4"]),
            "sentiment": random.choice(["negative", "neutral", "urgent"]) if incident else random.choice(["neutral", "positive"]),
            "slaBreachRisk": incident is not None and customer_doc.get("slaTier") in ["Platinum", "Gold"],
            "region": customer_doc.get("region"),
            "serviceName": "support-portal",
            "hostId": os.environ.get("HOSTNAME", "event-generator-host"),
            "createdTime": now_ms()
        }
        produce_message(producer, "support_tickets", ticket_id, json.dumps(ticket_doc))
        logger.debug(f"Created support ticket: {ticket_id} for issue: {issue}")
        
        # Publish ticket metric
        metrics_counters["tickets_created"] += 1
        publish_metric(producer, "demo_support_tickets_total", metrics_counters["tickets_created"], "1", {"status": "OPEN"})

def main():
    global enterprise_accounts, enterprise_services, enterprise_incidents
    logger.info(
        f"Starting event generator. Broker: {BOOTSTRAP_SERVERS}, "
        f"profile: {GENERATOR_PROFILE}, OTel Demo App: {OTEL_DEMO_URL}, interval: {GEN_INTERVAL}s, "
        f"events per batch: {EVENTS_PER_BATCH}, OTel calls enabled: {ENABLE_OTEL_CALLS}, "
        f"new customer probability: {NEW_CUSTOMER_PROBABILITY}, "
        f"ticket probability: {TICKET_PROBABILITY}, metrics enabled: {ENABLE_METRICS}, "
        f"incident updates enabled: {ENABLE_INCIDENT_UPDATES}, unique metric docs: {UNIQUE_METRIC_DOCS}, flush every: {FLUSH_EVERY_N_EVENTS}, "
        f"log every: {LOG_EVERY_N_EVENTS}, incident update every: {INCIDENT_UPDATE_EVERY_N_EVENTS}, "
        f"scenario: {GENERATOR_SCENARIO}, incident id override: {GENERATOR_INCIDENT_ID or '(none)'}"
    )
    
    # Wait for Kafka Broker to become healthy
    conf = {
        'bootstrap.servers': BOOTSTRAP_SERVERS,
        'client.id': os.environ.get("GENERATOR_INSTANCE_ID", f"demo-generator-{os.environ.get('HOSTNAME', uuid.uuid4().hex[:8])}"),
        'compression.type': PRODUCER_COMPRESSION,
        'linger.ms': PRODUCER_LINGER_MS,
        'batch.num.messages': PRODUCER_BATCH_NUM_MESSAGES,
        'queue.buffering.max.messages': PRODUCER_QUEUE_MAX_MESSAGES
    }
    producer = None
    while True:
        try:
            producer = Producer(conf)
            producer.list_topics(timeout=5)
            logger.info("Successfully connected to Redpanda/Kafka broker!")
            break
        except Exception as e:
            logger.warning(f"Waiting for broker at {BOOTSTRAP_SERVERS}... Error: {e}")
            time.sleep(3)
            
    enterprise_accounts = build_enterprise_accounts()
    enterprise_services = build_enterprise_services()
    enterprise_incidents = build_enterprise_incidents()
    publish_reference_data(producer)
    producer.flush(timeout=10)
    runtime_counters["last_log_time"] = time.time()

    # Main simulation loop
    try:
        while True:
            for _ in range(EVENTS_PER_BATCH):
                generate_event(producer)
                runtime_counters["events_generated"] += 1
                producer.poll(0)
                maybe_log_progress()

                if FLUSH_EVERY_N_EVENTS > 0 and runtime_counters["events_generated"] % FLUSH_EVERY_N_EVENTS == 0:
                    logger.info(f"Flushing Kafka producer after {runtime_counters['events_generated']} generated events...")
                    producer.flush(timeout=30)

            if GEN_INTERVAL > 0:
                time.sleep(GEN_INTERVAL)
            
    except KeyboardInterrupt:
        logger.info("Simulation stopped by user.")
    finally:
        maybe_log_progress(force=True)
        logger.info("Flushing generator message queue...")
        producer.flush(timeout=30)
        logger.info("Generator stopped.")

if __name__ == "__main__":
    main()
