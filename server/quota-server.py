#!/usr/bin/env python3
"""Plan-limit report for the accounts in CLIProxyAPI's auth dir.

GET /quota returns a text table, GET /quota.json the same data as JSON. Both
need one of the proxy's client keys (access.api-keys in config.yaml), sent as
"Authorization: Bearer <key>" or "x-api-key: <key>". Results are cached for
CACHE_SECONDS. Responses carry percentages and reset times, never the OAuth tokens.

Each account also gets a health verdict. The proxy's own view of it comes from
its management API on localhost (its key in MGMT_KEY_FILE). When the provider
rejects an account's access token, the proxy is asked to refresh that account,
at most once per REFRESH_EVERY seconds, and writes the new token itself; a
refresh token the provider no longer accepts marks the account dead.
"""
import glob
import json
import os
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.expanduser("~/.local/share/cliproxyapi")
CONFIG = os.path.join(BASE, "config.yaml")
AUTH_DIR = os.path.join(BASE, "oauth")
PORT = int(os.environ.get("QUOTA_PORT", "8318"))
CACHE_SECONDS = 60
SERVER_NAME = "khoakomlem-internal"
MGMT = "http://127.0.0.1:8317/v0/management"
MGMT_KEY_FILE = os.path.expanduser("~/.config/cliproxyapi-management.key")
REFRESH_EVERY = 600
RECENT_BUCKETS = 6  # the proxy counts requests in 10-minute buckets

# The server has an IPv6 default route that goes nowhere: every IPv6 connect
# hangs until the timeout. Resolve IPv4 only.
_getaddrinfo = socket.getaddrinfo
socket.getaddrinfo = lambda host, port, family=0, *a, **kw: _getaddrinfo(host, port, socket.AF_INET, *a, **kw)

_cache = {"at": 0.0, "data": None}
_lock = threading.Lock()
_refreshed = {}  # auth file name -> (time tried, error or None)


def client_keys():
    keys, inside = set(), False
    with open(CONFIG) as f:
        for line in f:
            if line.rstrip() == "  api-keys:":
                inside = True
                continue
            if inside:
                if line.startswith("    - "):
                    keys.add(line[6:].strip().strip("\"'"))
                else:
                    break
    return keys


def get_json(url, headers):
    req = urllib.request.Request(url, headers={**headers, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def epoch(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return int(value)
    return int(datetime.fromisoformat(value).timestamp())


def window_name(seconds):
    return {18000: "5-hour", 604800: "weekly"}.get(seconds, f"{round(seconds / 3600)}h")


def claude_windows(d):
    u = get_json(
        "https://api.anthropic.com/api/oauth/usage",
        {
            "Authorization": "Bearer " + d["access_token"],
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-cli/2.1.296 (external, cli)",
        },
    )
    names = [("five_hour", "5-hour"), ("seven_day", "weekly"), ("seven_day_opus", "weekly Opus"), ("seven_day_sonnet", "weekly Sonnet")]
    return [
        {"name": label, "used": float(u[key]["utilization"]), "resets_at": epoch(u[key].get("resets_at"))}
        for key, label in names
        if isinstance(u.get(key), dict) and u[key].get("utilization") is not None
    ]


def codex_windows(d):
    u = get_json(
        "https://chatgpt.com/backend-api/wham/usage",
        {
            "Authorization": "Bearer " + d["access_token"],
            "chatgpt-account-id": d.get("account_id", ""),
            "User-Agent": "codex_cli_rs/0.80.0",
        },
    )
    rl = u.get("rate_limit") or {}
    return [
        {"name": window_name(w["limit_window_seconds"]), "used": float(w["used_percent"]), "resets_at": epoch(w.get("reset_at"))}
        for w in (rl.get("primary_window"), rl.get("secondary_window"))
        if w
    ]


FETCHERS = {"claude": claude_windows, "codex": codex_windows}


def mgmt(method, path):
    with open(MGMT_KEY_FILE) as f:
        key = f.read().strip()
    req = urllib.request.Request(MGMT + path, method=method, headers={"Authorization": "Bearer " + key})
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.load(e)
        except ValueError:
            return e.code, {}


def proxy_states():
    """The proxy's runtime view of each auth file, by file name, or None when unreachable."""
    try:
        code, body = mgmt("GET", "/auth-files")
    except Exception:
        return None
    return {f["name"]: f for f in body.get("files", [])} if code == 200 else None


def refresh(name):
    """Has the proxy refresh one account. Returns None on success, else the error."""
    tried, error = _refreshed.get(name, (0.0, None))
    if time.time() - tried < REFRESH_EVERY:
        return error
    try:
        # The success body carries the new tokens; only the error text is kept.
        code, body = mgmt("POST", "/auth-files/refresh?name=" + urllib.parse.quote(name))
        error = None if 200 <= code < 300 else str(body.get("error") or f"HTTP {code}")
    except Exception as e:
        error = type(e).__name__
    _refreshed[name] = (time.time(), error)
    return error


def is_invalid_grant(text):
    text = (text or "").lower()
    return "invalid_grant" in text or "invalid grant" in text


def read_auth(path):
    with open(path) as f:
        return json.load(f)


def usage(path, d, kind):
    """Plan windows for one account, asking the proxy for a refresh once on a 401."""
    try:
        return FETCHERS[kind](d), None
    except urllib.error.HTTPError as e:
        if e.code != 401:
            return [], ("unavailable", f"usage endpoint answered HTTP {e.code}")
    error = refresh(os.path.basename(path))
    if error:
        return [], ("dead", "log in again") if is_invalid_grant(error) else ("refresh failed", error[:160])
    try:
        return FETCHERS[kind](read_auth(path)), None
    except urllib.error.HTTPError as e:
        return [], ("dead", "token rejected after a refresh") if e.code == 401 else ("unavailable", f"HTTP {e.code}")


def proxy_verdict(state):
    if state is None:
        return "not loaded", "the proxy has no such account"
    if state.get("disabled"):
        return "disabled", None
    message = state.get("status_message") or ""
    if is_invalid_grant(message):
        return "dead", "log in again"
    # A credential resting after a 429 also reads as status "error"; the cooldown is the real answer.
    rests = [c for c in state.get("cooldowns") or [] if isinstance(c, dict) and c.get("scope") == "credential"]
    if rests:
        left = max(int(c.get("remaining_seconds") or 0) for c in rests)
        return "cooling down", f"the proxy skips it for {until(int(time.time()) + left, int(time.time()))}"
    if state.get("status") == "error" or state.get("unavailable"):
        return "unavailable", message or state.get("status")
    models = [c for c in state.get("cooldowns") or [] if isinstance(c, dict) and c.get("model_key")]
    if models:
        return "cooling down", ", ".join(sorted({str(c["model_key"]) for c in models}))
    recent = (state.get("recent_requests") or [])[-RECENT_BUCKETS:]
    failed, ok = sum(b.get("failed", 0) for b in recent), sum(b.get("success", 0) for b in recent)
    if failed and not ok:
        return "failing", f"{failed} failed requests in the last hour, none succeeded"
    return None


SEVERITY = ["dead", "disabled", "not loaded", "unavailable", "refresh failed", "limit reached", "cooling down", "failing", "ok"]


def account(path, states):
    name = os.path.basename(path)
    try:
        d = read_auth(path)
    except (OSError, ValueError):
        return {"provider": "?", "email": name, "plan": None, "windows": [], "health": "unavailable", "detail": "unreadable auth file"}
    kind = d.get("type", "?")
    entry = {"provider": kind, "email": d.get("email", name), "plan": d.get("plan_type"), "windows": []}
    verdicts = []
    if d.get("disabled"):
        verdicts.append(("disabled", None))
    elif kind not in FETCHERS:
        verdicts.append(("unavailable", "no usage endpoint known for this provider"))
    else:
        try:
            entry["windows"], verdict = usage(path, d, kind)
        except Exception as e:
            entry["windows"], verdict = [], ("unavailable", type(e).__name__)
        if verdict:
            verdicts.append(verdict)
    if states is not None:
        verdict = proxy_verdict(states.get(name))
        if verdict:
            verdicts.append(verdict)
    full = [w for w in entry["windows"] if w["used"] >= 100]
    if full:
        verdicts.append(("limit reached", ", ".join(w["name"] for w in full)))
    entry["health"], entry["detail"] = min(verdicts or [("ok", None)], key=lambda v: SEVERITY.index(v[0]))
    return entry


def report():
    with _lock:
        if _cache["data"] and time.time() - _cache["at"] < CACHE_SECONDS:
            return _cache["data"]
        files = sorted(f for f in glob.glob(os.path.join(AUTH_DIR, "*.json")))
        states = proxy_states()
        with ThreadPoolExecutor(8) as pool:
            accounts = list(pool.map(lambda f: account(f, states), files))
        data = {"server": SERVER_NAME, "fetched_at": int(time.time()), "proxy_state": states is not None, "accounts": accounts}
        _cache.update(at=time.time(), data=data)
        return _cache["data"]


def short_email(email):
    user, _, domain = email.partition("@")
    return (user[:6] + "…" if len(user) > 7 else user) + ("@" + domain if domain else "")


def until(ts, now):
    s = max(0, ts - now)
    d, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
    return f"{d}d {h}h" if d else f"{h}h {m}m" if h else f"{m}m"


def bar(pct, width=10):
    filled = min(width, max(0, round(pct / 100 * width)))
    return "█" * filled + "░" * (width - filled)


def as_text(data):
    now = int(time.time())
    lines = [f"Quota on {data['server']} (checked {now - data['fetched_at']}s ago)"]
    if not data["proxy_state"]:
        lines.append("The proxy's management API did not answer; health covers the usage endpoints only.")
    lines.append("")
    for a in data["accounts"]:
        plan = f" ({a['plan']})" if a.get("plan") else ""
        health = a["health"].upper() if a["health"] in ("dead", "disabled", "not loaded") else a["health"]
        lines.append(f"{a['provider'].capitalize():<7} {short_email(a['email'])}{plan}  [{health}]")
        if a["detail"] and a["health"] != "limit reached":  # the full bar already says which window
            lines.append(f"  {a['detail']}")
        for w in a["windows"]:
            reset = f"  resets in {until(w['resets_at'], now)}" if w["resets_at"] and w["used"] > 0 else ""
            lines.append(f"  {w['name']:<13} {bar(w['used'])} {w['used']:>4.0f}%{reset}")
    return "\n".join(lines)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path not in ("/quota", "/quota.json"):
            return self.reply(404, "not found")
        auth = self.headers.get("Authorization", "")
        key = auth[7:] if auth.startswith("Bearer ") else self.headers.get("x-api-key", "")
        if not key or key not in client_keys():
            return self.reply(401, "invalid key")
        data = report()
        if path == "/quota.json":
            return self.reply(200, json.dumps(data), "application/json")
        self.reply(200, as_text(data))

    def reply(self, code, body, ctype="text/plain; charset=utf-8"):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
