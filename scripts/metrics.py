#!/usr/bin/env python3
"""Yorick's numbers, in one place, without anyone's dashboard.

Pulls from two sources today, with room for a third:

  1. TelemetryDeck usage counts, via their Query API — daily active users
     and signals-by-type. Needs a personal access token in
     TELEMETRYDECK_TOKEN (dashboard.telemetrydeck.com → user menu →
     Personal Access Tokens; tokens start with "tdpat_"). Skipped with a
     note when the token is absent, so the script never half-fails.
  2. GitHub release download counts (public API, no auth).
  3. (Placeholder) marketing-site analytics — wire in once heyyorick.com
     has a stats source worth reading.

Prints a human table by default; --json emits one machine-readable blob
for feeding whatever the real analytics store ends up being.

Usage:
  TELEMETRYDECK_TOKEN=tdpat_... scripts/metrics.py [--days 14] [--json]
"""

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request

TD_ENDPOINT = "https://api.telemetrydeckapi.com/api/v4/query/tql"
GITHUB_REPO = "damianr/yorick"


def http_json(url, body=None, token=None, timeout=60):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def td_query(token, query):
    return http_json(TD_ENDPOINT, body=query, token=token)


def interval(days):
    today = dt.date.today()
    start = today - dt.timedelta(days=days)
    # Druid-style ISO interval; end is exclusive, so run through tomorrow
    # to include today's partial data.
    return [f"{start.isoformat()}/{(today + dt.timedelta(days=1)).isoformat()}"]


def telemetry(token, days):
    """Two queries: DAU per day, and signal counts by type per day.

    No appID filter: the org has one app. When a second app exists, add
      "filter": {"type": "selector", "dimension": "appID", "value": "<id>"}
    to both queries.
    """
    dau = td_query(token, {
        "queryType": "timeseries",
        "granularity": "day",
        "intervals": interval(days),
        "aggregations": [{"type": "userCount", "name": "users"}],
    })
    by_type = td_query(token, {
        "queryType": "groupBy",
        "granularity": "all",
        "intervals": interval(days),
        "dimensions": [{"type": "default", "dimension": "type", "outputName": "signal"}],
        "aggregations": [{"type": "eventCount", "name": "count"}],
    })
    return {"dau": dau.get("result", dau), "signals_by_type": by_type.get("result", by_type)}


def downloads():
    rels = http_json(f"https://api.github.com/repos/{GITHUB_REPO}/releases")
    out, total = [], 0
    for r in rels:
        for a in r.get("assets", []):
            out.append({
                "release": r["tag_name"],
                "asset": a["name"],
                "downloads": a["download_count"],
            })
            total += a["download_count"]
    return {"assets": out, "total": total}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--days", type=int, default=14, help="telemetry window (default 14)")
    ap.add_argument("--json", action="store_true", help="emit one JSON blob instead of tables")
    args = ap.parse_args()

    report = {"generated": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")}

    token = os.environ.get("TELEMETRYDECK_TOKEN")
    if token:
        try:
            report["telemetry"] = telemetry(token, args.days)
        except urllib.error.HTTPError as e:
            report["telemetry_error"] = f"HTTP {e.code}: {e.read().decode(errors='replace')[:300]}"
    else:
        report["telemetry_skipped"] = "TELEMETRYDECK_TOKEN not set"

    try:
        report["downloads"] = downloads()
    except urllib.error.HTTPError as e:
        report["downloads_error"] = f"HTTP {e.code}"

    if args.json:
        json.dump(report, sys.stdout, indent=2)
        print()
        return

    print(f"Yorick metrics · {report['generated']}")
    if "telemetry" in report:
        print(f"\n— Usage (last {args.days} days, TelemetryDeck)")
        for row in report["telemetry"]["dau"]:
            stamp = str(row.get("timestamp", ""))[:10]
            users = (row.get("result") or {}).get("users", row.get("users"))
            print(f"  {stamp}  {users} active")
        print("\n— Signals by type")
        for row in report["telemetry"]["signals_by_type"]:
            ev = row.get("event", row)
            print(f"  {ev.get('signal', '?'):28} {ev.get('count', '?')}")
    elif "telemetry_error" in report:
        print(f"\n— Usage: query failed — {report['telemetry_error']}")
    else:
        print(f"\n— Usage: skipped ({report['telemetry_skipped']})")

    if "downloads" in report:
        print("\n— Downloads (GitHub releases)")
        for a in report["downloads"]["assets"]:
            print(f"  {a['release']:12} {a['asset']:34} {a['downloads']:6}")
        print(f"  TOTAL: {report['downloads']['total']}")


if __name__ == "__main__":
    main()
