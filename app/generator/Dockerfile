FROM python:3.11.9-slim-bookworm

WORKDIR /app

# Install runtime dependencies from pinned requirements.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the event generator source code
COPY main.py .

# Run Python in unbuffered mode to ensure logs are immediately visible in Docker output
CMD ["python", "-u", "main.py"]
