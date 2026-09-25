FROM python:3.12-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /srv
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY main.py ./main.py
ARG APP_VERSION=dev
ARG ERROR_RATE=0
ENV APP_VERSION=${APP_VERSION} ERROR_RATE=${ERROR_RATE}
# Numeric non-root user: satisfies runAsNonRoot admission and Pod Security "restricted".
RUN useradd --system --uid 10001 --no-create-home app
USER 10001
EXPOSE 8080
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log", "--timeout-graceful-shutdown", "20"]
