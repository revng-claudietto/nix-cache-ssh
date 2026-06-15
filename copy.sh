#!/usr/bin/env bash
#
# incremental-cache-push.sh
#
# Incrementally push store paths to a *remote* `file://` Nix binary cache that
# is reachable over rsync (ssh/rsyncd/local path), WITHOUT downloading the whole
# cache first.
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
#     3. run `nix copy --to file://$tmp?secret-key=... ...`; nix sees those
#        narinfos and skips every already-cached path, writing (and signing)
#        only NEW paths' nar + narinfo,
#     4. rsync only the new files back up.
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

# Arguments
remote="${1%/}"          # strip a single trailing slash for consistent rsync semantics
shift
packages=("$@")          # inputs are package / flake refs, e.g. nixpkgs#openssl

function nix_cmd() {
    nix --extra-experimental-features "nix-command flakes" "$@"
}

# Convert package names into derivation paths
installables=()
for PACKAGE in "${packages[@]}"; do
    installables+=$(nix_cmd build --no-link --print-out-paths "$package")
done

# --- temp dir with guaranteed cleanup ----------------------------------------
tmp="$(mktemp --tmpdir -d tmp.nix-cache-push.XXXXXXXXXX)"
cleanup() {
  rm -rf "$tmp";
}
trap cleanup EXIT

# Pull narinfos from the remote, so that only the needed derivations are
# packaged into new nars
rsync -a --include='/nix-cache-info' --include='/*.narinfo' --exclude='*' \
    "$remote/" "$tmp/"

# Create new narinfos and nars
nix_cmd copy --to "file://$tmp?secret-key=$SECRET_KEY_FILE" "${installables[@]}"

# Push back the newly created files, in 2 phases:
# 1. Everything but narinfos
# 2. Only the narinfos
# This allows the data to be consistent mid-transfer, since narinfos are the
# source of truth of the binary cache
rsync -a --ignore-existing --exclude='*.narinfo' "$tmp" "$remote/"
rsync -a --ignore-existing --include='/*.narinfo' --exclude='*' "$tmp" "$remote/"
