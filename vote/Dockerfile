# base defines a base stage that uses the official python runtime base image
FROM python:3.11.9-slim AS base

# Add curl for healthcheck & clean apt cache
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# Create unprivileged user
RUN groupadd -g 1000 appuser && \
    useradd -u 1000 -g appuser -m -s /bin/bash appuser

WORKDIR /usr/local/app

# Install dependencies as root to system python
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# dev stage for local file watching
FROM base AS dev
RUN pip install --no-cache-dir watchdog
ENV FLASK_ENV=development
USER appuser
CMD ["python", "app.py"]

# final stage for production bundle
FROM base AS final

# Copy code with non-root ownership
COPY --chown=appuser:appuser . .

EXPOSE 80

USER appuser
CMD ["gunicorn", "app:app", "-b", "0.0.0.0:80", "--log-file", "-", "--access-logfile", "-", "--workers", "4", "--keep-alive", "0"]
