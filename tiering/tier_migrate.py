#!/usr/bin/env python3
"""Hot → Cold tiering worker for OpenStack Swift (TempAuth).

Lists objects in the Hot container, migrates those older than TIER_AGE_THRESHOLD
minutes to Cold: COPY/PUT → HEAD verify (etag+size) → DELETE from Hot.

Age source (first available):
  1) X-Object-Meta-Ingested-At (ISO8601 UTC from uploaders)
  2) X-Timestamp (Swift)

Usage:
  python3 tier_migrate.py --dry-run
  python3 tier_migrate.py --threshold-minutes 30
  set -a; source ~/.hc_storage.env; set +a; python3 tier_migrate.py
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    import requests
except ImportError:
    print("error: install python3-requests", file=sys.stderr)
    sys.exit(2)


def die(msg: str, code: int = 2) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def auth(session: requests.Session, auth_url: str, user: str, key: str) -> tuple[str, str]:
    r = session.get(auth_url, headers={"X-Auth-User": user, "X-Auth-Key": key}, timeout=30)
    if r.status_code != 200:
        die(f"auth failed HTTP {r.status_code}")
    storage = r.headers.get("X-Storage-Url")
    token = r.headers.get("X-Auth-Token")
    if not storage or not token:
        die("missing X-Storage-Url or X-Auth-Token")
    return storage.rstrip("/"), token


def parse_ingested_at(value: str | None) -> datetime | None:
    if not value:
        return None
    v = value.strip()
    # Accept 2026-08-05T06:00:00Z or with offset
    if v.endswith("Z"):
        v = v[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(v)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def object_age_seconds(headers: dict, now: datetime) -> float | None:
    meta = {}
    for k, v in headers.items():
        lk = k.lower()
        if lk.startswith("x-object-meta-"):
            meta[lk[len("x-object-meta-") :]] = v
    ingested = parse_ingested_at(meta.get("ingested-at"))
    if ingested is not None:
        return (now - ingested).total_seconds()
    # Swift X-Timestamp is epoch float as string
    ts = headers.get("X-Timestamp") or headers.get("x-timestamp")
    if ts:
        try:
            return now.timestamp() - float(ts)
        except ValueError:
            return None
    return None


def list_objects(session: requests.Session, storage: str, token: str, container: str):
    """Yield object name strings (paginated)."""
    marker = ""
    while True:
        params = {"format": "json", "limit": 1000}
        if marker:
            params["marker"] = marker
        r = session.get(
            f"{storage}/{container}",
            headers={"X-Auth-Token": token},
            params=params,
            timeout=60,
        )
        if r.status_code == 204 or r.status_code == 200 and not r.content:
            return
        if r.status_code != 200:
            die(f"list {container} failed HTTP {r.status_code}")
        batch = r.json()
        if not batch:
            return
        for item in batch:
            yield item["name"]
        marker = batch[-1]["name"]


def head(session, storage, token, container, name):
    return session.head(
        f"{storage}/{container}/{name}",
        headers={"X-Auth-Token": token},
        timeout=30,
    )


def copy_to_cold(session, storage, token, hot, cold, name, hot_headers) -> requests.Response:
    """Server-side COPY within the same account when possible."""
    dest = f"/{cold}/{name}"
    headers = {
        "X-Auth-Token": token,
        "Destination": dest,
        "X-Object-Meta-Tier": "cold",
    }
    # Preserve useful metadata
    for k, v in hot_headers.items():
        lk = k.lower()
        if lk.startswith("x-object-meta-") and lk != "x-object-meta-tier":
            headers[k] = v
        if lk == "content-type":
            headers["Content-Type"] = v
    return session.request(
        "COPY",
        f"{storage}/{hot}/{name}",
        headers=headers,
        timeout=300,
    )


def put_via_get(session, storage, token, hot, cold, name, hot_headers) -> requests.Response:
    """Fallback: GET from hot and PUT to cold (preserves body; copies meta)."""
    g = session.get(
        f"{storage}/{hot}/{name}",
        headers={"X-Auth-Token": token},
        timeout=300,
        stream=True,
    )
    if g.status_code != 200:
        return g
    headers = {"X-Auth-Token": token, "X-Object-Meta-Tier": "cold"}
    for k, v in hot_headers.items():
        lk = k.lower()
        if lk.startswith("x-object-meta-") and lk != "x-object-meta-tier":
            headers[k] = v
        if lk == "content-type":
            headers["Content-Type"] = v
    return session.put(
        f"{storage}/{cold}/{name}",
        data=g.iter_content(1024 * 1024),
        headers=headers,
        timeout=300,
    )


def update_index(index_path: Path, name: str, tier: str) -> None:
    index_path.parent.mkdir(parents=True, exist_ok=True)
    records = {}
    if index_path.exists():
        for line in index_path.read_text().splitlines():
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
                records[obj["name"]] = obj
            except json.JSONDecodeError:
                continue
    records[name] = {
        "name": name,
        "tier": tier,
        "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    tmp = index_path.with_suffix(".tmp")
    with tmp.open("w") as f:
        for obj in sorted(records.values(), key=lambda x: x["name"]):
            f.write(json.dumps(obj) + "\n")
    tmp.replace(index_path)


def main() -> int:
    home = Path.home()
    p = argparse.ArgumentParser(description="Migrate aged Hot objects to Cold")
    p.add_argument("--auth-url", default=os.environ.get("ST_AUTH", "http://172.30.201.247:8080/auth/v1.0"))
    p.add_argument("--user", default=os.environ.get("ST_USER", "test:tester"))
    p.add_argument("--key", default=os.environ.get("ST_KEY", "testing"))
    p.add_argument("--hot", default=os.environ.get("HOT_CONTAINER", "hot-objects"))
    p.add_argument("--cold", default=os.environ.get("COLD_CONTAINER", "cold-objects"))
    p.add_argument(
        "--threshold-minutes",
        type=int,
        default=int(os.environ.get("TIER_AGE_THRESHOLD_MINUTES", "30")),
    )
    p.add_argument("--max-objects", type=int, default=int(os.environ.get("TIER_MAX_OBJECTS", "50")))
    p.add_argument(
        "--index",
        default=os.environ.get("HC_LOCATION_INDEX", str(home / "HC_storage_data" / "location_index.jsonl")),
    )
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--retries", type=int, default=3)
    args = p.parse_args()

    threshold_s = args.threshold_minutes * 60
    now = datetime.now(timezone.utc)
    session = requests.Session()

    try:
        storage, token = auth(session, args.auth_url, args.user, args.key)
    except requests.RequestException as e:
        die(f"cannot reach Swift auth: {e}")

    scanned = migrated = skipped = failed = 0
    index_path = Path(os.path.expanduser(args.index))

    for name in list_objects(session, storage, token, args.hot):
        if migrated + failed >= args.max_objects and not args.dry_run:
            print(f"STOP max-objects={args.max_objects}")
            break
        scanned += 1
        h = head(session, storage, token, args.hot, name)
        if h.status_code != 200:
            print(f"SKIP head-failed {name} HTTP {h.status_code}")
            skipped += 1
            continue
        age = object_age_seconds(h.headers, now)
        if age is None:
            print(f"SKIP no-age-metadata {name}")
            skipped += 1
            continue
        if age < threshold_s:
            print(f"KEEP {name} age_seconds={int(age)} (< {args.threshold_minutes}m)")
            skipped += 1
            continue

        print(f"MIGRATE_CANDIDATE {name} age_seconds={int(age)}")
        if args.dry_run:
            migrated += 1
            continue

        ok = False
        last_err = ""
        for attempt in range(1, args.retries + 1):
            try:
                # Prefer server-side COPY
                resp = copy_to_cold(session, storage, token, args.hot, args.cold, name, h.headers)
                if resp.status_code not in (201, 202):
                    resp = put_via_get(session, storage, token, args.hot, args.cold, name, h.headers)
                if resp.status_code not in (201, 202):
                    last_err = f"copy/put HTTP {resp.status_code}"
                    time.sleep(min(2**attempt, 8))
                    continue

                cold_h = head(session, storage, token, args.cold, name)
                if cold_h.status_code != 200:
                    last_err = f"cold HEAD HTTP {cold_h.status_code}"
                    time.sleep(min(2**attempt, 8))
                    continue

                hot_etag = (h.headers.get("Etag") or h.headers.get("ETag") or "").strip('"').lower()
                cold_etag = (cold_h.headers.get("Etag") or cold_h.headers.get("ETag") or "").strip('"').lower()
                hot_len = h.headers.get("Content-Length")
                cold_len = cold_h.headers.get("Content-Length")
                if hot_etag and cold_etag and hot_etag != cold_etag:
                    last_err = f"etag mismatch hot={hot_etag} cold={cold_etag}"
                    time.sleep(min(2**attempt, 8))
                    continue
                if hot_len and cold_len and hot_len != cold_len:
                    last_err = f"size mismatch hot={hot_len} cold={cold_len}"
                    time.sleep(min(2**attempt, 8))
                    continue

                # Only delete Hot after verify
                d = session.delete(
                    f"{storage}/{args.hot}/{name}",
                    headers={"X-Auth-Token": token},
                    timeout=60,
                )
                if d.status_code not in (204, 200):
                    last_err = f"hot DELETE HTTP {d.status_code} (cold object kept)"
                    time.sleep(min(2**attempt, 8))
                    continue

                update_index(index_path, name, "cold")
                print(f"MIGRATE_OK {name} etag={cold_etag}")
                ok = True
                break
            except requests.RequestException as e:
                last_err = str(e)
                time.sleep(min(2**attempt, 8))

        if ok:
            migrated += 1
        else:
            print(f"MIGRATE_FAIL {name} {last_err}")
            failed += 1

    print(
        f"scanned={scanned} migrated={migrated} skipped={skipped} failed={failed} "
        f"threshold_minutes={args.threshold_minutes} dry_run={int(args.dry_run)}"
    )
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
