#!/usr/bin/env python3

import json
import os
import sys
from base64 import b64decode
from hashlib import file_digest
from pathlib import Path
from subprocess import PIPE, Popen, run
from tempfile import TemporaryFile, mkstemp

NIX32_ALPHABET = "0123456789abcdfghijklmnpqrsvwxyz"


def nix32_encode(data: bytes) -> str:
    """Encode a bytes object into a Nix32 (Nix's Base32 variant) string."""
    length = (len(data) * 8 - 1) // 5 + 1
    result = ""
    for n in range(length - 1, -1, -1):
        i, j = divmod(n * 5, 8)
        c = data[i] >> j
        if i < len(data) - 1:
            c |= data[i + 1] << (8 - j)
        result += NIX32_ALPHABET[c & 0x1F]

    return result


def convert_hash(input_: str):
    """Convert SRI 'sha256-XXXX' hash into nix32"""
    assert input_.startswith("sha256-")
    hash_string = input_.removeprefix("sha256-")
    return nix32_encode(b64decode(hash_string))


def main():
    output_dir = Path(sys.argv[1])
    store_paths = sys.argv[2:]

    nar_dir = output_dir / "nar"
    nar_dir.mkdir(exist_ok=True)

    run(
        ["nix", "store", "sign", "--key-file", os.environ["SECRET_KEY_FILE"], *store_paths],
        check=True,
    )

    with TemporaryFile() as f:
        run(
            ["nix", "path-info", "--json", "--json-format", "2", *store_paths], stdout=f, check=True
        )
        f.seek(0)
        store_info = json.load(f)

    for store_path in store_paths:
        name = os.path.basename(store_path)
        derivation_info = store_info["info"][name]
        narinfo_path = output_dir / f"{name[:32]}.narinfo"

        if narinfo_path.exists():
            continue

        nar_fd, temp_nar_name = mkstemp(dir=nar_dir)
        with open(nar_fd, "wb+") as f:
            zstd_process = Popen(["zstd", "-zc", "-T0"], stdin=PIPE, stdout=f)
            run(["nix", "nar", "pack", store_path], stdout=zstd_process.stdin, check=True)
            zstd_process.stdin.close()
            assert zstd_process.wait() == 0

            f.seek(0)
            compressed_hash = nix32_encode(file_digest(f, "sha256").digest())
            compressed_size = f.seek(0, os.SEEK_END)

        Path(temp_nar_name).rename(nar_dir / f"{compressed_hash}.nar.zst")

        narinfo_path.write_text(
            f"""
StorePath: {store_path}
URL: nar/{compressed_hash}.nar.zst
Compression: zstd
FileHash: sha256:{compressed_hash}
FileSize: {compressed_size}
NarHash: sha256:{convert_hash(derivation_info["narHash"])}
NarSize: {derivation_info["narSize"]}
References: {" ".join(derivation_info["references"])}
Deriver: {derivation_info["deriver"]}
Sig: {" ".join(derivation_info["signatures"])}
""".strip() + "\n"
        )

    (output_dir / "nix-cache-info").write_text(f"StoreDir: {store_info["storeDir"]}\n")


if __name__ == "__main__":
    main()
