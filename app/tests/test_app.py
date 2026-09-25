import main
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "t1")
    monkeypatch.setenv("ERROR_RATE", "0")
    return TestClient(main.app)


def test_health_and_version(client):
    assert client.get("/healthz").json() == {"ok": True}
    assert client.get("/readyz").json() == {"ready": True}
    assert client.get("/version").json()["version"] == "t1"


def test_products_and_checkout(client):
    assert len(client.get("/api/products").json()) == 3
    r = client.post("/api/checkout?work=10")
    assert r.status_code == 200 and len(r.json()["order"]) == 12


def test_metrics_exposed_with_bounded_cardinality(client):
    client.get("/api/products")
    client.get("/does/not/exist/123")
    body = client.get("/metrics").text
    assert 'http_requests_total{code="200",method="GET",path="/api/products"}' in body
    assert 'path="other"' in body and "/does/not/exist" not in body


def test_fault_injection_never_touches_probes(client, monkeypatch):
    monkeypatch.setenv("ERROR_RATE", "1")
    assert client.get("/api/products").status_code == 500
    assert client.post("/api/checkout?work=1").status_code == 500
    assert client.get("/healthz").status_code == 200
    assert client.get("/readyz").status_code == 200
