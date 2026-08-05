#!/usr/bin/env python3
"""hc-storage — tier-transparent Swift client CLI (TempAuth).

Commands:
  upload   FILE [OBJECT_NAME]   — always stores in Hot
  download OBJECT_NAME [OUT]    — finds Hot or Cold automatically
  stat     OBJECT_NAME          — show metadata (tier only with --verbose)
  list                          — merged names from Hot+Cold (+ index)
  locate   OBJECT_NAME          — print tier (hot|cold|missing)

Hides Hot vs Cold for normal upload/download/list.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

try:
    import requests
except ImportError:
    print("error: install python3-requests", file=sys.stderr)
    sys.exit(2)


def die(msg: str, code: int = 1) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


class Client:
    def __init__(self, auth_url: str, user: str, key: str, hot: str, cold: str, index: Path):
        self.auth_url = auth_url
        self.user = user
        self.key = key
        self.hot = hot
        self.cold = cold
        self.index = index
        self.session = requests.Session()
        self.storage = None
        self.token = None

    def connect(self) -> None:
        r = self.session.get(
            self.auth_url,
            headers={"X-Auth-User": self.user, "X-Auth-Key": self.key},
            timeout=30,
        )
        if r.status_code != 200:
            die(f"auth failed HTTP {r.status_code}")
        self.storage = r.headers["X-Storage-Url"].rstrip("/")
        self.token = r.headers["X-Auth-Token"]

    def _hdr(self) -> dict:
        return {"X-Auth-Token": self.token}

    def head(self, container: str, name: str):
        return self.session.head(f"{self.storage}/{container}/{name}", headers=self._hdr(), timeout=30)

    def read_index(self) -> dict:
        out = {}
        if not self.index.exists():
            return out
        for line in self.index.read_text().splitlines():
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
                out[obj["name"]] = obj.get("tier")
            except json.JSONDecodeError:
                continue
        return out

    def write_index(self, name: str, tier: str) -> None:
        data = self.read_index()
        data[name] = tier
        self.index.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.index.with_suffix(".tmp")
        with tmp.open("w") as f:
            for n in sorted(data):
                f.write(json.dumps({"name": n, "tier": data[n]}) + "\n")
        tmp.replace(self.index)

    def locate(self, name: str) -> str | None:
        idx = self.read_index()
        if name in idx and idx[name] in ("hot", "cold"):
            cont = self.hot if idx[name] == "hot" else self.cold
            h = self.head(cont, name)
            if h.status_code == 200:
                return idx[name]
        for tier, cont in (("hot", self.hot), ("cold", self.cold)):
            h = self.head(cont, name)
            if h.status_code == 200:
                self.write_index(name, tier)
                return tier
        return None

    def upload(self, path: Path, name: str | None) -> None:
        from datetime import datetime, timezone

        name = name or path.name
        ingested = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        headers = {
            **self._hdr(),
            "Content-Type": "application/octet-stream",
            "X-Object-Meta-Tier": "hot",
            "X-Object-Meta-Ingested-At": ingested,
            "X-Object-Meta-Upload-Method": "cli-client",
        }
        with path.open("rb") as f:
            r = self.session.put(
                f"{self.storage}/{self.hot}/{name}",
                data=f,
                headers=headers,
                timeout=300,
            )
        if r.status_code not in (201, 202):
            die(f"upload failed HTTP {r.status_code}")
        self.write_index(name, "hot")
        print(f"uploaded {name}")

    def download(self, name: str, out: Path | None) -> None:
        tier = self.locate(name)
        if not tier:
            die(f"object not found: {name}")
        cont = self.hot if tier == "hot" else self.cold
        r = self.session.get(
            f"{self.storage}/{cont}/{name}",
            headers=self._hdr(),
            timeout=300,
            stream=True,
        )
        if r.status_code != 200:
            die(f"download failed HTTP {r.status_code}")
        dest = out or Path(name).name
        dest = Path(dest)
        with dest.open("wb") as f:
            for chunk in r.iter_content(1024 * 1024):
                if chunk:
                    f.write(chunk)
        print(f"downloaded {name} -> {dest}")

    def stat(self, name: str, verbose: bool) -> None:
        tier = self.locate(name)
        if not tier:
            die(f"object not found: {name}")
        cont = self.hot if tier == "hot" else self.cold
        h = self.head(cont, name)
        size = h.headers.get("Content-Length", "?")
        etag = (h.headers.get("Etag") or "").strip('"')
        if verbose:
            print(f"name={name} tier={tier} size={size} etag={etag} container={cont}")
            for k, v in sorted(h.headers.items()):
                if k.lower().startswith("x-object-meta-"):
                    print(f"  {k}: {v}")
        else:
            print(f"name={name} size={size} etag={etag}")

    def list_all(self) -> None:
        names = set(self.read_index())
        for cont in (self.hot, self.cold):
            marker = ""
            while True:
                params = {"format": "json", "limit": 1000}
                if marker:
                    params["marker"] = marker
                r = self.session.get(
                    f"{self.storage}/{cont}",
                    headers=self._hdr(),
                    params=params,
                    timeout=60,
                )
                if r.status_code not in (200, 204) or not r.content:
                    break
                batch = r.json()
                if not batch:
                    break
                for item in batch:
                    names.add(item["name"])
                marker = batch[-1]["name"]
        for n in sorted(names):
            print(n)


def build_parser() -> argparse.ArgumentParser:
    home = Path.home()
    p = argparse.ArgumentParser(prog="hc-storage", description="Tier-transparent object storage CLI")
    p.add_argument("--auth-url", default=os.environ.get("ST_AUTH", "http://172.30.201.247:8080/auth/v1.0"))
    p.add_argument("--user", default=os.environ.get("ST_USER", "test:tester"))
    p.add_argument("--key", default=os.environ.get("ST_KEY", "testing"))
    p.add_argument("--hot", default=os.environ.get("HOT_CONTAINER", "hot-objects"))
    p.add_argument("--cold", default=os.environ.get("COLD_CONTAINER", "cold-objects"))
    p.add_argument(
        "--index",
        default=os.environ.get("HC_LOCATION_INDEX", str(home / "HC_storage_data" / "location_index.jsonl")),
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    u = sub.add_parser("upload", help="upload file to Hot storage")
    u.add_argument("file")
    u.add_argument("name", nargs="?", help="object name (default: basename)")

    d = sub.add_parser("download", help="download from Hot or Cold")
    d.add_argument("name")
    d.add_argument("out", nargs="?", help="output path")

    s = sub.add_parser("stat", help="show object info")
    s.add_argument("name")
    s.add_argument("--verbose", "-v", action="store_true")

    sub.add_parser("list", help="list object names (merged)")

    loc = sub.add_parser("locate", help="show which tier holds the object")
    loc.add_argument("name")
    return p


def main() -> int:
    args = build_parser().parse_args()
    client = Client(args.auth_url, args.user, args.key, args.hot, args.cold, Path(os.path.expanduser(args.index)))
    try:
        client.connect()
    except requests.RequestException as e:
        die(f"cannot reach Swift: {e}")

    if args.cmd == "upload":
        path = Path(args.file)
        if not path.is_file():
            die(f"not a file: {path}")
        client.upload(path, args.name)
    elif args.cmd == "download":
        client.download(args.name, Path(args.out) if args.out else None)
    elif args.cmd == "stat":
        client.stat(args.name, args.verbose)
    elif args.cmd == "list":
        client.list_all()
    elif args.cmd == "locate":
        tier = client.locate(args.name)
        print(tier or "missing")
        return 0 if tier else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
