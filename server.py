#!/usr/bin/env python3
# K.A.R.I Update/Control Server — Tailnet/LAN-aware auth + HEARTBEATS + TIME + JOBS
# Hardened: scoped file-serving, loopback allowance, security headers, configurable HOST.

import os, mimetypes, uuid, time, json as jsonlib, ipaddress
from pathlib import Path
from flask import Flask, request, send_from_directory, abort, Response, make_response

# ---- Config -----------------------------------------------------------------
AUTH_TOKEN    = os.environ.get("KARI_TOKEN", "").strip()            # empty => no token
AUTH_MODE     = os.environ.get("KARI_AUTH", "token").strip().lower()  # "token" | "none"
ALLOW_PRIVATE = os.environ.get("ALLOW_PRIVATE", "true").lower() in ("1","true","yes")
PORT          = int(os.environ.get("PORT", "13337"))
HOST          = os.environ.get("HOST", "127.0.0.1")  # use 0.0.0.0 only if you really want LAN

ROOT       = Path(__file__).resolve().parent
BASE_DIR   = ROOT

# Strict: only serve files under ./kari via /files/*
KARI_DIR   = ROOT / "kari"
STATIC_DIR = ROOT / "static"
DATA_DIR   = ROOT / "data"
DATA_DIR.mkdir(exist_ok=True)

JOBS_PATH    = DATA_DIR / "jobs.jsonl"
REPORTS_PATH = DATA_DIR / "reports.jsonl"
STATUS_PATH  = DATA_DIR / "status.jsonl"
DEVICES_PATH = DATA_DIR / "devices.jsonl"

# Add common lua mimetype (some systems miss it)
mimetypes.add_type("text/plain", ".lua")

# ---- App --------------------------------------------------------------------
app = Flask(__name__, static_folder=None)

# ---- Auth helpers -----------------------------------------------------------
def _client_ip(req) -> str:
    # Prefer proxy headers if present (tailscale/nginx), fall back to remote_addr
    xff = req.headers.get("X-Forwarded-For", "")
    if xff:
        return xff.split(",")[0].strip()
    xrip = req.headers.get("X-Real-IP")
    if xrip:
        return xrip.strip()
    return (req.remote_addr or "").strip()

def _is_private_net_or_loopback(ip_str: str) -> bool:
    try:
        ip = ipaddress.ip_address(ip_str)
    except Exception:
        return False
    if getattr(ip, "is_loopback", False):
        return True
    if getattr(ip, "is_private", False):
        return True
    # CGNAT 100.64/10 (common with Tailscale)
    try:
        return ip in ipaddress.ip_network("100.64.0.0/10")
    except Exception:
        return False

def _token_ok(req) -> bool:
    h = req.headers.get("X-KARI-TOKEN")
    q = req.args.get("t")
    c = req.cookies.get("kari_token")
    tok = AUTH_TOKEN
    return any([(h and h == tok), (q and q == tok), (c and c == tok)])

def authed(req) -> bool:
    # Mode: auth disabled OR no token set => allow if private/loopback (when ALLOW_PRIVATE), else allow all
    if AUTH_MODE == "none" or AUTH_TOKEN == "":
        if not ALLOW_PRIVATE:
            return True  # fully open (only for trusted environments)
        return _is_private_net_or_loopback(_client_ip(req))
    # Mode: token
    if _token_ok(req):
        return True
    # Also allow private nets when configured
    return ALLOW_PRIVATE and _is_private_net_or_loopback(_client_ip(req))

def within_base(p: Path, base: Path) -> bool:
    try:
        p.resolve().relative_to(base.resolve())
        return True
    except Exception:
        return False

def list_tree(root: Path):
    out = []
    for p in root.rglob("*"):
        if p.is_file():
            rel = p.relative_to(base_dir_exposed()).as_posix()
            try:
                st = p.stat()
                out.append({"path": rel, "bytes": st.st_size, "mtime": int(st.st_mtime)})
            except FileNotFoundError:
                pass
    return out

def base_dir_exposed() -> Path:
    # Only the repo root for manifest.json and KARI_DIR for /files/*
    return BASE_DIR

def j(obj, code=200):
    resp = app.response_class(
        response=jsonlib.dumps(obj, ensure_ascii=False),
        status=code,
        mimetype="application/json",
    )
    return resp

def jsonl_append(path: Path, rec: dict):
    with path.open("a", encoding="utf-8") as f:
        f.write(jsonlib.dumps(rec, ensure_ascii=False) + "\n")

def _jsonl_load_latest(path: Path, type_filter=None, key="id"):
    latest = {}
    if path.exists():
        with path.open("r", encoding="utf-8") as f:
            for line in f:
                try:
                    e = jsonlib.loads(line)
                except Exception:
                    continue
                if type_filter and e.get("type") != type_filter:
                    continue
                k = str(e.get(key, e.get("turtle_id", "")))
                if not k:
                    continue
                if k not in latest or e.get("ts", 0) > latest[k].get("ts", 0):
                    latest[k] = e
    return latest

def _devices_aliases():
    return _jsonl_load_latest(DEVICES_PATH, type_filter="alias", key="turtle_id")

# ---- Files & Manifest -------------------------------------------------------
@app.get("/manifest.json")
def manifest():
    if not authed(request):
        abort(401)
    mf = BASE_DIR / "manifest.json"
    if not mf.exists():
        return j({"version": "0.0.0", "files": {}})
    return send_from_directory(mf.parent, mf.name, as_attachment=False, mimetype="application/json")

@app.get("/files/<path:subpath>")
def get_file(subpath):
    """
    Serve ONLY files under ./kari/**

    Client usually requests paths that *begin with* "kari/..." or "/kari/...".
    We normalize and force resolution inside KARI_DIR.
    """
    if not authed(request):
        abort(401)

    # Normalize leading slash and ensure it starts with 'kari/'
    normalized = subpath.lstrip("/")
    if not (normalized == "kari" or normalized.startswith("kari/")):
        abort(404)  # anything outside ./kari is off-limits

    target = (BASE_DIR / normalized).resolve()
    if not within_base(target, KARI_DIR) or not target.exists() or not target.is_file():
        abort(404)

    return send_from_directory(target.parent, target.name, as_attachment=False, mimetype=mimetypes.guess_type(target.name)[0] or "application/octet-stream")

# ---- Repo tree (read-only, scoped) ------------------------------------------
@app.get("/api/tree")
def api_tree():
    if not authed(request):
        abort(401)
    # Only list within ./kari by default; allow ?subdir=kari/...
    sub = (request.args.get("subdir") or "kari").strip().strip("/")
    root = (BASE_DIR / sub).resolve()
    if not within_base(root, KARI_DIR) or not root.exists():
        abort(404)
    return j({"subdir": sub, "files": list_tree(root)})

# ---- Reports (files) --------------------------------------------------------
@app.post("/api/report/files")
def api_report_files():
    if not authed(request):
        abort(401)
    data = request.get_json(force=True, silent=True) or {}
    data.update({"type": "files", "ts": int(time.time()), "turtle_id": str(data.get("turtle_id", "unknown"))})
    jsonl_append(REPORTS_PATH, data)
    return j({"ok": True})

@app.get("/api/reports")
def api_reports():
    if not authed(request):
        abort(401)
    latest = {}
    if REPORTS_PATH.exists():
        with REPORTS_PATH.open("r", encoding="utf-8") as f:
            for line in f:
                try:
                    e = jsonlib.loads(line)
                except Exception:
                    continue
                if e.get("type") != "files":
                    continue
                tid = str(e.get("turtle_id", "unknown"))
                if tid not in latest or e["ts"] > latest[tid]["ts"]:
                    latest[tid] = e
    return j({"turtles": latest})

# ---- HEARTBEATS (status + alias mgmt) --------------------------------------
@app.post("/api/devices/<tid>/alias")
def api_set_alias(tid):
    if not authed(request):
        abort(401)
    body = request.get_json(force=True, silent=True) or {}
    rec = {"type": "alias", "ts": int(time.time()), "turtle_id": str(tid), "alias": str(body.get("alias", "")).strip()}
    jsonl_append(DEVICES_PATH, rec)
    return j({"ok": True, "alias": rec["alias"]})

@app.delete("/api/devices/<tid>")
def api_forget_device(tid):
    if not authed(request):
        abort(401)
    rec = {"type": "forget", "ts": int(time.time()), "turtle_id": str(tid)}
    jsonl_append(DEVICES_PATH, rec)
    return j({"ok": True})

@app.get("/api/devices")
def api_devices():
    if not authed(request):
        abort(401)
    latest_status = _jsonl_load_latest(STATUS_PATH, type_filter="status", key="turtle_id")
    aliases       = _devices_aliases()
    forgets       = _jsonl_load_latest(DEVICES_PATH, type_filter="forget", key="turtle_id")
    now = int(time.time())
    devices = []
    for tid, st in latest_status.items():
        if tid in forgets:  # skip forgotten
            continue
        alias = aliases.get(tid, {}).get("alias")
        last  = st.get("ts", 0)
        devices.append({
            "id": tid,
            "alias": alias,
            "label": st.get("label"),
            "role": st.get("role"),
            "version": st.get("version"),
            "fuel": st.get("fuel"),
            "pos": st.get("pos"),
            "programs": st.get("programs") or [],
            "last_seen": last,
            "last_seen_secs": max(0, now - last),
            "online": (now - last) < 30,
        })
    devices.sort(key=lambda d: (not d["online"], d["alias"] or d["label"] or d["id"]))
    return j({"count": len(devices), "devices": devices})

@app.post("/api/report/status")
def api_report_status():
    if not authed(request):
        abort(401)
    data = request.get_json(force=True, silent=True) or {}
    tid = str(data.get("turtle_id", "unknown"))
    prev = None
    if STATUS_PATH.exists():
        with STATUS_PATH.open("r", encoding="utf-8") as f:
            for line in f:
                try:
                    e = jsonlib.loads(line)
                    if e.get("type") == "status" and str(e.get("turtle_id", "")) == tid:
                        if not prev or e.get("ts", 0) > prev.get("ts", 0):
                            prev = e
                except Exception:
                    pass
    if "pos" not in data and prev and prev.get("pos"):
        data["pos"] = prev["pos"]
    data.update({"type": "status", "ts": int(time.time()), "turtle_id": tid})
    jsonl_append(STATUS_PATH, data)
    return j({"ok": True})

# ---- Jobs -------------------------------------------------------------------
def _jobs_load():
    jobs = {}
    if JOBS_PATH.exists():
        with JOBS_PATH.open("r", encoding="utf-8") as f:
            for line in f:
                try:
                    e = jsonlib.loads(line)
                except Exception:
                    continue
                jid = e.get("id")
                if not jid:
                    continue
                jobs[jid] = {**jobs.get(jid, {}), **e}
    return jobs

@app.post("/api/jobs")
def create_job():
    if not authed(request):
        abort(401)
    body = request.get_json(force=True)
    jid = str(uuid.uuid4())
    rec = {
        "id": jid,
        "ts": int(time.time()),
        "turtle_id": str(body["turtle_id"]),
        "cmd": body["cmd"],
        "args": body.get("args", {}),
        "state": "queued",
    }
    jsonl_append(JOBS_PATH, rec)
    return j(rec, 201)

@app.get("/api/jobs")
def list_jobs():
    if not authed(request):
        abort(401)
    return j({"jobs": list(_jobs_load().values())})

@app.get("/api/jobs/next")
def next_job():
    if not authed(request):
        abort(401)
    tid = str(request.args.get("turtle_id", ""))
    jobs = _jobs_load()
    q = [j for j in jobs.values() if j.get("state") == "queued" and j.get("turtle_id") == tid]
    if not q:
        return j({"job": None})
    job = sorted(q, key=lambda x: x["ts"])[0]
    jsonl_append(JOBS_PATH, {"id": job["id"], "state": "claimed", "claim_ts": int(time.time())})
    jobs = _jobs_load()
    return j({"job": jobs[job["id"]]})

@app.post("/api/jobs/<jid>/report")
def job_report(jid):
    if not authed(request):
        abort(401)
    body = request.get_json(force=True)
    jsonl_append(JOBS_PATH, {"id": jid, **body})
    if body.get("final"):
        jsonl_append(JOBS_PATH, {"id": jid, "state": body.get("status", "done"), "done_ts": int(time.time())})
    return j({"ok": True})

# ---- Time Sync / Health -----------------------------------------------------
@app.get("/api/time")
def api_time():
    if not authed(request):
        abort(401)
    now = time.time()
    return j({
        "epoch": int(now),
        "epoch_ms": int(now * 1000),
        "iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
    })

@app.get("/healthz")
def healthz():
    return ("ok", 200, {"Content-Type": "text/plain"})

# ---- Root / Static ----------------------------------------------------------
@app.get("/")
def index():
    idx = STATIC_DIR / "index.html"
    if idx.exists():
        return send_from_directory(STATIC_DIR, "index.html")
    return Response(
        (
            "<h1>K.A.R.I Server</h1>"
            f"<p>BASE_DIR: {BASE_DIR}</p>"
            f"<p>Auth mode: {AUTH_MODE!r}, allow_private={ALLOW_PRIVATE}, token_set={'yes' if AUTH_TOKEN else 'no'}</p>"
            "<p>Endpoints: <code>/manifest.json</code>, <code>/files/kari/...</code>, "
            "<code>/api/devices</code>, <code>/api/time</code>, <code>/healthz</code></p>"
        ),
        mimetype="text/html",
    )

# ---- CORS & Security Headers ------------------------------------------------
@app.after_request
def cors_and_security(r):
    origin = request.headers.get("Origin")
    if origin:
        r.headers["Access-Control-Allow-Origin"] = origin
        r.headers["Vary"] = "Origin"
        r.headers["Access-Control-Allow-Credentials"] = "true"
    else:
        r.headers["Access-Control-Allow-Origin"] = "*"
    r.headers["Access-Control-Allow-Headers"] = "Content-Type, X-KARI-TOKEN"
    r.headers["Access-Control-Allow-Methods"] = "GET, POST, DELETE, OPTIONS"

    # Security-ish headers
    r.headers["X-Content-Type-Options"] = "nosniff"
    r.headers["X-Frame-Options"] = "DENY"
    r.headers["Referrer-Policy"] = "no-referrer"
    return r

@app.route("/api/<path:_any>", methods=["OPTIONS"])
def preflight(_any):
    return ("", 200)

# ---- Main -------------------------------------------------------------------
if __name__ == "__main__":
    print(f"[KARI] Booting on {HOST}:{PORT} - BASE_DIR={BASE_DIR}")
    print(f"[KARI] Auth mode='{AUTH_MODE}', allow_private={ALLOW_PRIVATE}, token_set={'yes' if AUTH_TOKEN else 'no'}")
    app.run(host=HOST, port=PORT)
