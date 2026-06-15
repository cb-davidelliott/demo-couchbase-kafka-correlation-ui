import os
import time
import logging
from flask import Flask, request, jsonify
import requests

# OpenTelemetry Imports
from opentelemetry import trace, metrics
from opentelemetry._logs import set_logger_provider
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

app = Flask(__name__)

# Configure Resource metadata for this service
resource = Resource.create(attributes={
    "service.name": "otel-demo-store",
    "service.version": "1.0.0",
    "host.id": os.environ.get("HOSTNAME", "otel-demo-host")
})

# 1. Setup Distributed Tracing
tracer_provider = TracerProvider(resource=resource)
otlp_trace_exporter = OTLPSpanExporter(endpoint="otel-collector:4317", insecure=True)
tracer_provider.add_span_processor(BatchSpanProcessor(otlp_trace_exporter))
trace.set_tracer_provider(tracer_provider)
tracer = trace.get_tracer("otel-demo-store-tracer")

# 2. Setup Metrics
metric_reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint="otel-collector:4317", insecure=True)
)
meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
metrics.set_meter_provider(meter_provider)
meter = meter_provider.get_meter("otel-demo-store-meter")

# Define mock business metrics
order_counter = meter.create_counter(
    "demo_orders_total",
    description="The total number of simulated orders placed",
    unit="1"
)
revenue_counter = meter.create_counter(
    "demo_revenue_usd",
    description="The total revenue generated in USD",
    unit="USD"
)
ticket_counter = meter.create_counter(
    "demo_support_tickets_total",
    description="The total number of support tickets created",
    unit="1"
)

# 3. Setup OTel Logging
logger_provider = LoggerProvider(resource=resource)
logger_provider.add_log_record_processor(
    BatchLogRecordProcessor(OTLPLogExporter(endpoint="otel-collector:4317", insecure=True))
)
set_logger_provider(logger_provider)

logger = logging.getLogger("otel-application-logger")
logger.setLevel(logging.INFO)
logger.propagate = False

stdout_handler = logging.StreamHandler()
stdout_handler.setFormatter(logging.Formatter("%(message)s"))
logger.addHandler(stdout_handler)
logger.addHandler(LoggingHandler(level=logging.INFO, logger_provider=logger_provider))

def emit_otel_log(severity, message, attributes=None):
    """
    Emit logs to stdout for Docker debugging and via OTLP for the collector.
    Trace/span context is attached by the OpenTelemetry logging handler.
    """
    import json
    current_span = trace.get_current_span()
    span_context = current_span.get_span_context() if current_span else None
    
    log_doc = {
        "timestamp": int(time.time() * 1000),
        "severity": severity,
        "body": message,
        "serviceName": "otel-demo-store",
        "attributes": attributes or {}
    }
    
    if span_context and span_context.is_valid:
        log_doc["traceId"] = trace.format_trace_id(span_context.trace_id)
        log_doc["spanId"] = trace.format_span_id(span_context.span_id)
        
    # Keep a readable JSON line in Docker logs, while also exporting an OTel log.
    otel_attributes = attributes or {}
    log_method = logger.warning if severity.upper() == "WARNING" else logger.info
    log_method(json.dumps(log_doc), extra=otel_attributes)

@app.route("/api/browse", methods=["GET"])
def browse():
    # Start a span for user browsing
    with tracer.start_as_current_span("user_browse_catalog") as span:
        session_id = request.args.get("sessionId", "SESS-UNKNOWN")
        span.set_attribute("app.sessionId", session_id)
        
        emit_otel_log("INFO", "User is browsing product catalog", {"app.sessionId": session_id})
        
        # Simulate db query child span
        with tracer.start_as_current_span("db_fetch_products") as child_span:
            child_span.set_attribute("db.system", "couchbase")
            child_span.set_attribute("db.operation", "SELECT")
            time.sleep(0.05) # simulate minor latency
            
        emit_otel_log("INFO", "Successfully fetched products from Couchbase", {"app.sessionId": session_id})
        return jsonify({"status": "success", "products_count": 6})

@app.route("/api/checkout", methods=["POST"])
def checkout():
    # Extract headers for trace context propagation
    carrier = {}
    for key, value in request.headers.items():
        carrier[key] = value
    
    # Extract trace context passed from business generator (if any)
    ctx = TraceContextTextMapPropagator().extract(carrier=carrier)
    
    # Start checkout transaction span
    with tracer.start_as_current_span("user_checkout_transaction", context=ctx) as span:
        cust_id = request.args.get("customerId", "CUST-UNKNOWN")
        order_id = request.args.get("orderId", "ORD-UNKNOWN")
        session_id = request.args.get("sessionId", "SESS-UNKNOWN")
        total_amount = float(request.args.get("totalAmount", "0.0"))
        
        span.set_attribute("app.customerId", cust_id)
        span.set_attribute("app.orderId", order_id)
        span.set_attribute("app.sessionId", session_id)
        span.set_attribute("app.checkout.amount", total_amount)
        
        emit_otel_log("INFO", f"Checkout started for Customer: {cust_id}", {
            "app.customerId": cust_id, "app.orderId": order_id, "app.sessionId": session_id
        })
        
        # Simulate payment validation child span
        with tracer.start_as_current_span("payment_gateway_authorization") as child_span:
            child_span.set_attribute("payment.provider", "stripe")
            time.sleep(0.1) # simulate payment processing API call
            
        emit_otel_log("INFO", f"Payment authorized for Order: {order_id}", {
            "app.orderId": order_id, "app.checkout.amount": total_amount
        })
        
        # Record OpenTelemetry Metrics
        order_counter.add(1, {"country": request.args.get("country", "US")})
        revenue_counter.add(total_amount, {"category": "all"})
        
        emit_otel_log("INFO", f"Order {order_id} completed successfully!", {
            "app.customerId": cust_id, "app.orderId": order_id
        })
        
        return jsonify({
            "status": "completed",
            "orderId": order_id,
            "traceId": trace.format_trace_id(span.get_span_context().trace_id)
        })

@app.route("/api/ticket", methods=["POST"])
def ticket():
    carrier = {}
    for key, value in request.headers.items():
        carrier[key] = value
        
    ctx = TraceContextTextMapPropagator().extract(carrier=carrier)
    
    with tracer.start_as_current_span("support_ticket_submission", context=ctx) as span:
        cust_id = request.args.get("customerId", "CUST-UNKNOWN")
        order_id = request.args.get("orderId", "ORD-UNKNOWN")
        ticket_id = request.args.get("ticketId", "TCK-UNKNOWN")
        issue_type = request.args.get("issueType", "General query")
        
        span.set_attribute("app.customerId", cust_id)
        span.set_attribute("app.orderId", order_id)
        span.set_attribute("app.ticketId", ticket_id)
        span.set_attribute("app.ticket.issue", issue_type)
        
        emit_otel_log("WARNING", f"Customer support ticket {ticket_id} opened for issue: {issue_type}", {
            "app.customerId": cust_id, "app.orderId": order_id, "app.ticketId": ticket_id
        })
        
        ticket_counter.add(1, {"status": "OPEN"})
        
        return jsonify({"status": "ticket_created", "ticketId": ticket_id})

if __name__ == "__main__":
    # Wait for collector to start up
    time.sleep(5)
    app.run(host="0.0.0.0", port=5000)
