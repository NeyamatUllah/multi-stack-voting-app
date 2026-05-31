# base defines a base stage that uses the official python runtime base image
FROM python:3.11.15-slim-bookworm AS base

# Add curl for healthcheck; upgrade first to pick up patched OS packages
# hadolint ignore=DL3005,DL3008
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# Set the application directory
WORKDIR /usr/local/app

# Upgrade pip toolchain to pick up patched wheel and setuptools vendored packages
RUN pip install --no-cache-dir --upgrade pip setuptools wheel

# Install our requirements.txt
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Set environment variables for Redis configuration (can be overridden at runtime)
ENV REDIS_HOST=redis
ENV REDIS_PORT=6379

# dev defines a stage for development, where it'll watch for filesystem changes
FROM base AS dev
RUN pip install --no-cache-dir watchdog==6.0.0
ENV FLASK_ENV=development

CMD ["python", "app.py"]

# final defines the stage that will bundle the application for production
FROM base AS final

# Create non-root user before COPY so --chown can reference it
RUN addgroup --system appgroup && \
    adduser --system --ingroup appgroup appuser

# Copy code with ownership set at write time — avoids a separate chown layer
COPY --chown=appuser:appgroup . .

USER appuser

# Make port 80 available for links and/or publish
EXPOSE 80

# Define our command to be run when launching the container
CMD ["gunicorn", "app:app", "-b", "0.0.0.0:80", "--log-file", "-", "--access-logfile", "-", "--workers", "4", "--keep-alive", "0"]
