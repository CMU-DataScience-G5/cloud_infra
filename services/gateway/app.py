"""Gateway: API-key authentication and routing in front of the controller.

Public API (behind the GKE external HTTP(S) load balancer):
  POST /v1/segment            {"volume_b64": "<base64 .nii/.nii.gz>", "task": "lung_cancer"}
  GET  /v1/results/{job_id}   -> previously computed mask
  GET  /v1/tasks              -> available tasks and their labels
  GET  /healthz, /metrics
"""

import hmac
import os
import time

import httpx
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

CONTROLLER_URL = os.environ["CONTROLLER_URL"]
API_KEYS = [k.strip() for k in os.environ.get("API_KEYS", "").split(",") if k.strip()]
MAX_UPLOAD_BYTES = int(float(os.environ.get("MAX_UPLOAD_MB", "1024")) * 1024 * 1024)
UPSTREAM_TIMEOUT_S = float(os.environ.get("UPSTREAM_TIMEOUT_S", "840"))
# Origins allowed to call the API from a browser (the web frontend), comma-separated. Empty = no CORS.
CORS_ALLOW_ORIGINS = [o.strip() for o in os.environ.get("CORS_ALLOW_ORIGINS", "").split(",") if o.strip()]

REQUESTS = Counter("gateway_http_requests_total", "HTTP requests", ["route", "method", "status"])
LATENCY = Histogram(
    "gateway_http_request_duration_seconds",
    "HTTP request latency",
    ["route"],
    buckets=(0.1, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600, 900),
)
REQUEST_BYTES = Counter("gateway_http_request_bytes_total", "Request body bytes received", ["route"])

UNMETERED = {"/healthz", "/metrics"}

# Create the per-route series at 0 on startup. Otherwise a series first appears already
# incremented, and Prometheus rate()/histogram_quantile() never see that first request.
for _route in ("/v1/segment", "/v1/results/{job_id}", "/v1/tasks"):
    LATENCY.labels(_route)
    REQUEST_BYTES.labels(_route)

app = FastAPI(title="CT Segmentation Gateway")
client = httpx.AsyncClient(base_url=CONTROLLER_URL, timeout=httpx.Timeout(UPSTREAM_TIMEOUT_S, connect=5))


@app.middleware("http")
async def metrics_and_auth(request: Request, call_next):
    route = request.url.path
    if route in UNMETERED:
        return await call_next(request)
    if route.startswith("/v1/results/"):
        route = "/v1/results/{job_id}"

    start = time.perf_counter()
    status = 500
    try:
        if not _authorized(request):
            status = 401
            return Response('{"detail":"invalid or missing API key"}', status_code=401, media_type="application/json")
        length = int(request.headers.get("content-length") or 0)
        if length > MAX_UPLOAD_BYTES:
            status = 413
            return Response('{"detail":"request body too large"}', status_code=413, media_type="application/json")
        REQUEST_BYTES.labels(route).inc(length)
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        REQUESTS.labels(route, request.method, str(status)).inc()
        LATENCY.labels(route).observe(time.perf_counter() - start)


# Added after the auth middleware so it wraps it: CORS preflight (OPTIONS, no API key) is
# answered here before auth runs.
if CORS_ALLOW_ORIGINS:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=CORS_ALLOW_ORIGINS,
        allow_methods=["GET", "POST"],
        allow_headers=["X-API-Key", "Authorization", "Content-Type"],
        max_age=3600,
    )


def _authorized(request: Request) -> bool:
    key = request.headers.get("x-api-key") or ""
    if not key:
        auth = request.headers.get("authorization", "")
        key = auth[7:] if auth.lower().startswith("bearer ") else ""
    return any(hmac.compare_digest(key, k) for k in API_KEYS)


async def _forward(method: str, path: str, body: bytes | None = None) -> Response:
    try:
        upstream = await client.request(
            method, path, content=body, headers={"content-type": "application/json"} if body else None
        )
    except httpx.TimeoutException:
        raise HTTPException(504, "controller timed out")
    except httpx.HTTPError as e:
        raise HTTPException(502, f"controller unavailable: {e.__class__.__name__}")
    return Response(upstream.content, status_code=upstream.status_code, media_type="application/json")


@app.post("/v1/segment")
async def segment(request: Request):
    return await _forward("POST", "/segment", await request.body())


@app.get("/v1/results/{job_id}")
async def results(job_id: str):
    return await _forward("GET", f"/results/{job_id}")


@app.get("/v1/tasks")
async def tasks():
    return await _forward("GET", "/tasks")


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/")
async def root():
    return {"service": "ct-segmentation-gateway"}


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
