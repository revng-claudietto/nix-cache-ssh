#!/usr/bin/env python3
"""Fetch .narinfo files from a Nix binary cache, in parallel, over HTTP/2.

Reads Nix store paths (one per line) from the file given as the second CLI
argument. For each path it tries to download ``<hash>.narinfo`` from the binary
cache into the output directory (first CLI argument). Paths whose narinfo is
already present (e.g. pulled from the remote) are left untouched.

Every store path whose narinfo could NOT be obtained -- i.e. the cache does not
serve it -- is printed to stdout; those are the paths the caller must copy
itself. Warnings go to stderr.

Downloads are capped at 8 concurrent requests (an asyncio semaphore) and
multiplexed over a shared HTTP/2 connection via niquests.

Usage:
    fetch-narinfos.py <output-dir> <paths-file> [<cache-url>]
"""
import asyncio
import os
import sys

import niquests

CONCURRENCY = 8
DEFAULT_CACHE = "https://cache.nixos.org"


def hash_part(store_path: str) -> str:
    """``/nix/store/<32-char-hash>-name`` -> ``<32-char-hash>``."""
    return os.path.basename(store_path)[:32]


async def fetch_one(session, sem, base_url, out_dir, store_path, missing):
    h = hash_part(store_path)
    target = os.path.join(out_dir, f"{h}.narinfo")
    if os.path.exists(target):  # already pulled from the remote; nothing to do
        return

    url = f"{base_url}/{h}.narinfo"
    try:
        async with sem:
            # In multiplexed mode get() returns a lazy response and gather()
            # resolves it. Holding the semaphore across both caps the number of
            # in-flight downloads to CONCURRENCY while they share (multiplex
            # over) the same HTTP/2 connection.
            resp = await session.get(url)
            await session.gather(resp)
    except Exception as exc:
        print(f"warning: failed to fetch {url}: {exc}", file=sys.stderr)
        missing.append(store_path)
        return

    if resp.status_code == 200:
        with open(target, "wb") as fh:
            fh.write(resp.content)
    else:
        # 404 (not on the cache) or otherwise unavailable: the caller copies it.
        if resp.status_code != 404:
            print(f"warning: {url} -> HTTP {resp.status_code}", file=sys.stderr)
        missing.append(store_path)


async def main():
    if len(sys.argv) < 3:
        sys.exit("usage: fetch-narinfos.py <output-dir> <paths-file> [<cache-url>]")
    out_dir = sys.argv[1]
    with open(sys.argv[2]) as fh:
        store_paths = [line.strip() for line in fh if line.strip()]
    base_url = (sys.argv[3] if len(sys.argv) > 3 else DEFAULT_CACHE).rstrip("/")

    if not store_paths:
        return

    missing: list[str] = []
    sem = asyncio.Semaphore(CONCURRENCY)
    async with niquests.AsyncSession(multiplexed=True) as session:
        await asyncio.gather(
            *(fetch_one(session, sem, base_url, out_dir, p, missing) for p in store_paths)
        )

    # The paths we could not fetch are the ones the caller still needs to copy.
    if missing:
        sys.stdout.write("\n".join(missing) + "\n")


if __name__ == "__main__":
    asyncio.run(main())
