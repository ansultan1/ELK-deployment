"""Tiny demo service that emits structured JSON logs to stdout (one event per request)."""
import json
import logging
import random
import sys
import time
import uuid
from datetime import datetime, timezone

from flask import Flask, g, request

app = Flask(__name__)
log = logging.getLogger("sample-app")
log.setLevel(logging.INFO)
log.addHandler(logging.StreamHandler(sys.stdout))
log.propagate = False


def emit(level, msg, **fields):
    log.info(json.dumps({
        "ts": datetime.now(timezone.utc).isoformat(),
        "level": level, "msg": msg, **fields,
    }))


@app.before_request
def start():
    g.t0 = time.perf_counter()


@app.after_request
def done(resp):
    ms = round((time.perf_counter() - g.t0) * 1000, 1)
    level = "ERROR" if resp.status_code >= 500 else "WARN" if resp.status_code >= 400 else "INFO"
    emit(level, "request", method=request.method, route=request.path,
         status=resp.status_code, duration_ms=ms)
    return resp


@app.route("/")
def index():
    return {"service": "sample-app", "ok": True}


@app.route("/health")
def health():
    return {"status": "up"}


@app.route("/order")
def order():
    time.sleep(random.uniform(0.01, 0.15))
    if random.random() < 0.1:
        emit("WARN", "payment declined", order_id=str(uuid.uuid4()))
        return {"error": "payment declined"}, 402
    return {"order_id": str(uuid.uuid4()), "amount": round(random.uniform(5, 200), 2)}


@app.route("/slow")
def slow():
    time.sleep(random.uniform(0.5, 2.0))
    return {"slow": True}


@app.route("/error")
def error():
    emit("ERROR", "unhandled exception", exception="ZeroDivisionError: division by zero")
    return {"error": "internal"}, 500
