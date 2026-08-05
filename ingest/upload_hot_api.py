#!/usr/bin/env python3
"""Upload ready_for_hot/ files to Swift Hot via the REST API (TempAuth).

Same claim/verify semantics as upload_hot_cli.sh:
  ready_for_hot/ -> uploading_hot/ -> (PUT + HEAD verify) -> uploaded_hot/

Usage:
  python3 upload_hot_api.py
  python3 upload_hot_api.py --dry-run
  ST_AUTH=http://172.30.201.247:8080/auth/v1.0 python3 upload_hot_api.py
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    import requests
except ImportError:
    print("error: python3 module 'requests' is required (apt install python3-requests)", file=sys.stderr)
    sys.exit(2)


def die(msg: str, code: int = 2) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def expand(p: str) -> Path:
    return Path(os.path.expanduser(p)).resolve()


def md5_file(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def auth(session: requests.Session, auth_url: str, user: str, key: str) -> tuple[str, str]:
    """TempAuth: GET auth URL with X-Auth-User / X-Auth-Key -> storage URL + token."""
    r = session.get(
        auth_url,
        headers={"X-Auth-User": user, "X-Auth-Key": key},
        timeout=30,
    )
    if r.status_code != 200:
        die(f"auth failed HTTP {r.status_code}: {r.text[:200]}")
    storage_url = r.headers.get("X-Storage-Url")
    token = r.headers.get("X-Auth-Token")
    if not storage_url or not token:
        die("auth response missing X-Storage-Url or X-Auth-Token")
    return storage_url.rstrip("/"), token


def head_object(session: requests.Session, storage_url: str, token: str, container: str, name: str):
    url = f"{storage_url}/{container}/{name}"
    return session.head(url, headers={"X-Auth-Token": token}, timeout=30)


def put_object(
    session: requests.Session,
    storage_url: str,
    token: str,
    container: str,
    name: str,
    path: Path,
    meta: dict[str, str],
) -> requests.Response:
    url = f"{storage_url}/{container}/{name}"
    headers = {"X-Auth-Token": token, "Content-Type": "application/octet-stream"}
    for k, v in meta.items():
        headers[f"X-Object-Meta-{k}"] = v
    with path.open("rb") as f:
        return session.put(url, data=f, headers=headers, timeout=300)


def main() -> int:
    home = Path.home()
    parser = argparse.ArgumentParser(description="Upload to Hot Swift container via REST API")
    parser.add_argument("--ready-dir", default=os.environ.get("READY_FOR_HOT", str(home / "HC_storage_data" / "ready_for_hot")))
    parser.add_argument("--uploading-dir", default=os.environ.get("UPLOADING_HOT", str(home / "HC_storage_data" / "uploading_hot")))
    parser.add_argument("--uploaded-dir", default=os.environ.get("UPLOADED_HOT", str(home / "HC_storage_data" / "uploaded_hot")))
    parser.add_argument("--container", default=os.environ.get("HOT_CONTAINER", "hot-objects"))
    parser.add_argument("--auth-url", default=os.environ.get("ST_AUTH", "http://172.30.201.247:8080/auth/v1.0"))
    parser.add_argument("--user", default=os.environ.get("ST_USER", "test:tester"))
    parser.add_argument("--key", default=os.environ.get("ST_KEY", "testing"))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--retries", type=int, default=3)
    args = parser.parse_args()

    ready = expand(args.ready_dir)
    uploading = expand(args.uploading_dir)
    uploaded = expand(args.uploaded_dir)
    for d in (ready, uploading, uploaded):
        d.mkdir(parents=True, exist_ok=True)

    files = sorted(p for p in ready.iterdir() if p.is_file())
    scanned = uploaded_n = failed = skipped = 0

    if not files:
        print(f"scanned=0 uploaded=0 failed=0 skipped=0 ready_dir={ready}")
        print("nothing to upload")
        return 0

    session = requests.Session()
    storage_url = token = None
    if not args.dry_run:
        try:
            storage_url, token = auth(session, args.auth_url, args.user, args.key)
        except SystemExit:
            raise
        except requests.RequestException as e:
            die(f"cannot reach auth URL {args.auth_url}: {e}")

    for path in files:
        scanned += 1
        base = path.name
        local_md5 = md5_file(path)
        size = path.stat().st_size
        ingested_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        if args.dry_run:
            print(f"WOULD_UPLOAD {base} size={size} md5={local_md5} container={args.container}")
            uploaded_n += 1
            continue

        claim = uploading / base
        if claim.exists():
            print(f"SKIP already-claiming {base}")
            skipped += 1
            continue
        try:
            path.rename(claim)  # atomic claim on same filesystem
        except OSError as e:
            print(f"SKIP claim-failed {base}: {e}")
            skipped += 1
            continue

        print(f"UPLOAD_START {base} size={size} md5={local_md5}")
        meta = {
            "Tier": "hot",
            "Ingested-At": ingested_at,
            "Upload-Method": "api",
            "Original-Size": str(size),
        }

        ok = False
        last_err = ""
        for attempt in range(1, args.retries + 1):
            try:
                assert storage_url and token
                resp = put_object(session, storage_url, token, args.container, base, claim, meta)
                if resp.status_code not in (201, 202):
                    last_err = f"PUT HTTP {resp.status_code}"
                    time.sleep(min(2 ** attempt, 8))
                    continue
                head = head_object(session, storage_url, token, args.container, base)
                if head.status_code != 200:
                    last_err = f"HEAD HTTP {head.status_code}"
                    time.sleep(min(2 ** attempt, 8))
                    continue
                etag = (head.headers.get("Etag") or head.headers.get("ETag") or "").strip('"').lower()
                if etag != local_md5:
                    last_err = f"etag mismatch local={local_md5} remote={etag}"
                    time.sleep(min(2 ** attempt, 8))
                    continue
                ok = True
                remote_etag = etag
                break
            except requests.RequestException as e:
                last_err = str(e)
                time.sleep(min(2 ** attempt, 8))

        if not ok:
            print(f"UPLOAD_FAIL {base} {last_err} — returning to ready_for_hot")
            try:
                claim.rename(ready / base)
            except OSError:
                shutil.move(str(claim), str(ready / base))
            failed += 1
            continue

        dest = uploaded / base
        if dest.exists():
            dest.unlink()
        claim.rename(dest)
        print(f"UPLOAD_OK {base} etag={remote_etag} archived={dest}")
        uploaded_n += 1

    print(
        f"scanned={scanned} uploaded={uploaded_n} failed={failed} skipped={skipped} dry_run={int(args.dry_run)}"
    )
    print(f"ready={ready} uploading={uploading} uploaded={uploaded} container={args.container}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
