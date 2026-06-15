FROM python:3.11-slim

WORKDIR /app

# Install Flask and OpenTelemetry packages
RUN pip install --no-cache-dir \
    flask \
    requests \
    opentelemetry-api \
    opentelemetry-sdk \
    opentelemetry-instrumentation-flask \
    opentelemetry-exporter-otlp

COPY main.py .

CMD ["python", "-u", "main.py"]
