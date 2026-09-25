"""shop: a small storefront service used to exercise the platform.

It is deliberately boring business logic with production-grade operational surface:
health/readiness probes, RED metrics for Managed Prometheus, graceful shutdown, and a
fault-injection switch so canary analysis and rollback can be demonstrated for real.
"""

import hashlib
import os
import random
import time

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import HTMLResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest


def version_string() -> str:
    return os.environ.get("APP_VERSION", "dev")


def error_rate() -> float:
    """Fraction (0..1) of /api/* requests that fail with 500. A "bad release" is the same code
    shipped with ERROR_RATE>0, which is exactly what a canary must catch. Read per request so
    tests (and, if you like, a ConfigMap reload) can change it without a restart."""
    return float(os.environ.get("ERROR_RATE", "0"))


app = FastAPI(title="shop", docs_url=None, redoc_url=None)

REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "path", "code"])
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5),
)
BUILD = Gauge("shop_build_info", "Build info", ["version"])
BUILD.labels(version=version_string()).set(1)

PRODUCTS = [
    {"id": 1, "name": "Mechanical keyboard", "price_eur": 129.0},
    {"id": 2, "name": "USB-C dock", "price_eur": 89.5},
    {"id": 3, "name": '27" monitor', "price_eur": 249.0},
]
KNOWN_PATHS = {"/", "/healthz", "/readyz", "/version", "/metrics", "/api/products", "/api/checkout"}


@app.middleware("http")
async def observe(request: Request, call_next):
    started = time.perf_counter()
    path = request.url.path if request.url.path in KNOWN_PATHS else "other"  # bound cardinality
    try:
        response = await call_next(request)
        code = response.status_code
    except Exception:
        code = 500
        raise
    finally:
        LATENCY.labels(path).observe(time.perf_counter() - started)
        REQUESTS.labels(request.method, path, str(code)).inc()
    return response


def maybe_fail() -> None:
    rate = error_rate()
    if rate and random.random() < rate:  # noqa: S311 (not security relevant)
        raise HTTPException(status_code=500, detail="injected failure")


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True}


@app.get("/readyz")
def readyz() -> dict:
    return {"ready": True}


@app.get("/version")
def version() -> dict:
    return {
        "version": version_string(),
        "error_rate": error_rate(),
        "pod": os.environ.get("HOSTNAME", ""),
    }


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/api/products")
def products() -> list[dict]:
    maybe_fail()
    return PRODUCTS


@app.post("/api/checkout")
def checkout(work: int = 200_000) -> dict:
    """`work` burns CPU (hash rounds) so HPA scaling can be demonstrated with plain HTTP load."""
    maybe_fail()
    digest = b"shop"
    for _ in range(min(max(work, 1), 2_000_000)):
        digest = hashlib.sha256(digest).digest()
    return {"order": digest.hex()[:12], "version": version_string()}


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    rows = "".join(f"<li>{p['name']} - EUR {p['price_eur']:.2f}</li>" for p in PRODUCTS)
    return (
        "<!doctype html><meta charset=utf-8><title>shop</title>"
        "<body style='font:16px system-ui;max-width:640px;margin:48px auto;padding:0 16px'>"
        f"<h1>shop <small style='color:#666'>v{version_string()}</small></h1><ul>{rows}</ul>"
        "<p style='color:#666'>Served from GKE Autopilot behind a Cloud Armor Gateway.</p>"
        "</body>"
    )
