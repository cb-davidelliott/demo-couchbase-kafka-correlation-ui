FROM python:3.11.9-slim-bookworm

WORKDIR /app

# Install runtime dependencies from pinned requirements.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

CMD ["python", "-u", "main.py"]
