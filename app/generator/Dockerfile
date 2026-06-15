FROM python:3.11-slim

WORKDIR /app

# Install runtime dependencies.
RUN pip install --no-cache-dir \
    confluent-kafka \
    requests

# Copy the event generator source code
COPY main.py .

# Run Python in unbuffered mode to ensure logs are immediately visible in Docker output
CMD ["python", "-u", "main.py"]
