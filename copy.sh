#!/usr/bin/env bash
#
# Incrementally push the closure of one or more packages to a *remote* `file://`
# Nix binary cache reachable over rsync, copying only the paths that need to be
# synced and omitting any package already served by `https://cache.nixos.org`.
#
# How it works (and why it is safe):
#
#   A `file://` binary cache considers a store path "already present" purely by
#   the existence of its `<hash>.narinfo` file -- it never checks whether the
#   referenced `nar/<filehash>.nar` actually exists
#   (libstore: BinaryCacheStore::isValidPathUncached -> fileExists(narinfo)).
#
#   So we:
#     1. make a temp dir,
#     2. rsync ONLY the `*.narinfo` files (+ nix-cache-info) down into it
#        -- cheap; the multi-GB `nar/` blobs stay on the remote,
#     3. list the closure with `nix path-info`, then fetch from cache.nixos.org
#        the narinfo of every closure path it serves (fetch-narinfos.py): those
#        get seeded into file://$tmp so the cache's reference check passes, and
#        the paths it could NOT fetch are the ones we must copy ourselves,
#     4. `nix copy --no-recursive` those paths into file://$tmp (signing them,
#        and skipping any already on the remote), then delete every narinfo that
#        was already present before the copy (the seeded + pulled ones),
#     5. rsync only the new files back up.
#
# The push is done in two passes (nars first, narinfos last) -- mirroring nix's
# own write ordering -- so that an interruption can only ever leave a nar
# without a narinfo (harmless: looks invalid, re-uploaded next run), never a
# narinfo without its nar (which would mask a missing blob forever).
#
# Usage:
#   incremental-cache-push.sh <rsync-target> <package> [<package>...]
#
#   <rsync-target>  Destination cache root as rsync understands it, e.g.
#                     user@host:/srv/nix-cache
#                     rsync://host/cache
#                     /mnt/nfs/nix-cache            (local path)
#   <package>       One or more packages / flake refs, e.g. `nixpkgs#openssl`.
#                   Each is realised to its output store path(s) and pushed
#                   together with its runtime closure.
#
# Environment variables:
#   SECRET_KEY_FILE   REQUIRED. Secret key used to sign the narinfos of newly
#                     copied paths (passed as the cache's `secret-key`
#                     parameter). Already-present paths are not re-signed, so if
#                     nothing new is copied, nothing is signed.
set -euo pipefail
shopt -s nullglob

# The signing key is required: every published narinfo is signed with it.
: "${SECRET_KEY_FILE:?SECRET_KEY_FILE must be set to the secret signing key}"

# Arguments
remote="${1%/}"          # strip a single trailing slash for consistent rsync semantics
shift
packages=("$@")          # inputs are package / flake refs, e.g. nixpkgs#openssl

function nix_cmd() {
    nix --extra-experimental-features "nix-command flakes" "$@"
}

# Directory holding this script (and fetch-narinfos.py), resolving any symlink.
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

tmp="$(mktemp --tmpdir -d tmp.nix-cache-push.XXXXXXXXXX)"
closure_file="$(mktemp --tmpdir tmp.nix-cache-push.closure.XXXXXXXXXX)"
tocopy_file="$(mktemp --tmpdir tmp.nix-cache-push.tocopy.XXXXXXXXXX)"
cleanup() {
  rm -rf "$tmp" "$closure_file" "$tocopy_file"
}
trap cleanup EXIT

# Resolve packages to their output store paths, then compute the full closure
# -- the set of store paths that might need to be pushed.
output_paths=()
readarray -t output_paths < <(
  for package in "${packages[@]}"; do
    nix_cmd build --no-link --print-out-paths "$package"
  done
)
nix_cmd path-info --recursive "${output_paths[@]}" > "$closure_file"

# Pull narinfos from the remote, so paths it already has are skipped below.
rsync -a --include='/nix-cache-info' --include='/*.narinfo' --exclude='*' \
    "$remote/" "$tmp/"

# (1) Fetch the narinfos cache.nixos.org serves for the closure straight into
#     $tmp (narinfos only, no nars). Seeding them lets the binary cache's
#     reference-validity check pass for the paths we copy that depend on them.
#     nix-shell does not forward our stdin, so the path list is passed as a file;
#     fetch-narinfos.py prints to stdout the paths it could NOT fetch -- the ones
#     not on cache.nixos.org, which we must copy ourselves.
nix-shell -p "python3.withPackages(ps: [ ps.niquests ])" \
    --run "python3 '$script_dir/fetch-narinfos.py' '$tmp' '$closure_file'" \
    > "$tocopy_file"
mapfile -t store_paths < "$tocopy_file"

# Snapshot the narinfos present before the copy (pulled from the remote +
# fetched from cache.nixos.org). Only the narinfos the copy adds should be
# pushed, so we delete these afterwards.
existing_narinfos=("$tmp"/*.narinfo)

# (2) Create new narinfos and nars for the paths we publish. A single batched
#     copy lets nix topologically sort them, so a kept path is never written
#     before a kept dependency it references.
if [[ ${#store_paths[@]} -gt 0 ]]; then
    nix_cmd copy --to "file://$tmp?secret-key=$SECRET_KEY_FILE" --no-recursive "${store_paths[@]}"
fi

# (3) Delete the narinfos that were already present before the copy: they belong
#     to cache.nixos.org or are already on the remote, so they must not be pushed.
if [[ ${#existing_narinfos[@]} -gt 0 ]]; then
    rm -f "${existing_narinfos[@]}"
fi

# Push back the newly created files, in 2 phases:
# 1. Everything but narinfos
# 2. Only the narinfos
# This allows the data to be consistent mid-transfer, since narinfos are the
# source of truth of the binary cache
rsync -a --ignore-existing --exclude='*.narinfo' "$tmp/" "$remote/"
rsync -a --ignore-existing --include='/*.narinfo' --exclude='*' "$tmp/" "$remote/"
