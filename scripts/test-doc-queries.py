#!/usr/bin/env python3
"""Run every query in docs/*.md against the live Mimir, Loki and Tempo.

Fenced blocks tagged promql, logql or traceql are executed. Add `allow-empty`
to the fence info string (```promql allow-empty) for queries that legitimately
return nothing when the demo is healthy (for example error-only queries).

Usage:
  kubectl port-forward -n lgtm svc/mimir-gateway 9009:80 &
  kubectl port-forward -n lgtm svc/loki 3100:3100 &
  kubectl port-forward -n lgtm svc/tempo 3200:3200 &
  python3 -I scripts/test-doc-queries.py [docs/file.md ...]

Environment overrides: MIMIR_URL, LOKI_URL, TEMPO_URL. Standard library only.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

MIMIR = os.environ.get("MIMIR_URL", "http://localhost:9009/prometheus")
LOKI = os.environ.get("LOKI_URL", "http://localhost:3100")
TEMPO = os.environ.get("TEMPO_URL", "http://localhost:3200")

ROOT = Path(__file__).resolve().parent.parent
FENCE = re.compile(r"^```(promql|logql|traceql)([^\n]*)\n(.*?)^```", re.M | re.S)


def get(url, params):
    req = urllib.request.Request(url + "?" + urllib.parse.urlencode(params))
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode(errors="replace")[:300]}
    except Exception as e:  # connection refused, timeout
        return 0, {"error": str(e)}


def run_promql(q, now):
    code, body = get(MIMIR + "/api/v1/query", {"query": q, "time": now})
    if code != 200 or body.get("status") != "success":
        return False, body.get("error", body)
    return True, len(body["data"]["result"])


def run_logql(q, now):
    code, body = get(LOKI + "/loki/api/v1/query_range", {
        "query": q, "start": (now - 3600) * 10**9, "end": now * 10**9,
        "step": 60, "limit": 20})
    if code != 200 or body.get("status") != "success":
        return False, body.get("message") or body.get("error", body)
    return True, len(body["data"]["result"])


def run_traceql(q, now):
    if re.search(r"\|\s*(rate|count_over_time|quantile_over_time|histogram_over_time|avg_over_time)\b", q):
        code, body = get(TEMPO + "/api/metrics/query_range", {
            "q": q, "start": now - 3600, "end": now, "step": "60s"})
        n = len(body.get("series", []))
    else:
        code, body = get(TEMPO + "/api/search", {
            "q": q, "limit": 20, "start": now - 3600, "end": now})
        n = len(body.get("traces", []))
    if code != 200:
        return False, body.get("error", body)
    return True, n


RUNNERS = {"promql": run_promql, "logql": run_logql, "traceql": run_traceql}


def main():
    files = [Path(a) for a in sys.argv[1:]] or sorted((ROOT / "docs").glob("*.md"))
    now = int(time.time())
    total = failed = 0
    for f in files:
        text = f.read_text()
        for m in FENCE.finditer(text):
            lang, flags, query = m.group(1), m.group(2), m.group(3).strip()
            line = text.count("\n", 0, m.start()) + 1
            ok, detail = RUNNERS[lang](query, now)
            if ok and detail == 0 and "allow-empty" not in flags:
                ok, detail = False, "returned no data (add allow-empty if expected)"
            total += 1
            failed += not ok
            shown = " ".join(query.split())[:90]
            status = "PASS" if ok else "FAIL"
            info = f"{detail} result(s)" if ok else detail
            print(f"{status}  {f.name}:{line}  [{lang}] {shown}")
            if not ok:
                print(f"      {info}")
    print(f"\n{total - failed}/{total} queries passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
