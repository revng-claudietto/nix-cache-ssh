#!/usr/bin/env python3

"""
Given a list of store paths, try and fetch the relative `.narinfo` file from
the supplied binary cache (by default `https://cache.nixos.org`) to the output
directory. Any file that cannot be fetched is printed to stdout.
This script leverages HTTP/2 multiplexing to be as efficient as possible when
fetching a possibly large amount of store paths.
"""

import argparse
import asyncio
from asyncio import Semaphore
from pathlib import Path

from niquests import AsyncSession


def hash_part(store_path: str) -> str:
    """/nix/store/<32-char-hash>-<name> -> <32-char-hash>"""
    return Path(store_path).name[:32]


async def fetch_one(
    session: AsyncSession, semaphore: Semaphore, base_url: str, out_dir: Path, store_path: str
) -> str | None:
    hash_ = hash_part(store_path)
    target_file = out_dir / f"{hash_}.narinfo"
    if target_file.exists():
        return None

    url = f"{base_url}/{hash_}.narinfo"
    try:
        async with semaphore:
            resp = await session.get(url)
            await session.gather(resp)
    except IOError:
        return store_path

    if resp.status_code != 200:
        return store_path

    with open(target_file, "wb") as f:
        f.write(resp.content)
    return None


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-u", "--url", default="https://cache.nixos.org", help="Upstream cache url")
    parser.add_argument("output_dir", type=Path, help="Output dir")
    parser.add_argument("paths_file")
    args = parser.parse_args()

    store_paths = [line.strip() for line in Path(args.paths_file).read_text().splitlines()]
    semaphore = asyncio.Semaphore(8)
    async with AsyncSession(multiplexed=True) as session:
        missing_elements = await asyncio.gather(
            *(fetch_one(session, semaphore, args.url, args.output_dir, p) for p in store_paths)
        )

    for element in missing_elements:
        if element is not None:
            print(element)


if __name__ == "__main__":
    asyncio.run(main())
