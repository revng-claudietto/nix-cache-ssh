#!/usr/bin/env bash
#
# Given a rsync remote and a list of nix package(s), push the incremental set of
# derivations to the remote as a binary cache. This is done with the following
# steps:
# 1. Generate the transitive closure of all the derivations from the specified
#    package(s) and compute the store path for each
# 2. From the remote, copy all the `*.narinfo` files into a scratch directory
# 3. For each store path, try and fetch the `.narinfo` from
#    `https://cache.nixos.org` into the scratch directory as well
# 4. Run the actual `nix copy` command, since the target directory already
#    contains a bunch of `.narinfo`s, all of these will be skipped and their
#    derivation's `.nar` archive will not be generated
# 5. Delete all the `.narinfo`s generated from step (2) and (3)
# 6. rsync the scratch directory to the remote
#
# Usage:
#   copy.sh <rsync-target> <package> [<package>...]
#
#   <rsync-target>  any rsync-compatible destination
#   <package>       One or more packages / flake refs, e.g. `nixpkgs#openssl`
#
# Environment variables:
#   SECRET_KEY_FILE   REQUIRED. This is the secret key that will be used for
#                     signing the new `.narinfo`s before uploading them to the
#                     remote.

set -euo pipefail

SCRIPT_DIR=$(realpath "$(dirname "${BASH_SOURCE[0]}")")

function nix_cmd() {
    nix --extra-experimental-features "nix-command flakes" "$@"
}

# Argument parsing
REMOTE="${1%/}"
shift
PACKAGES=("$@")

# Temporary files
SCRATCH_DIR="$(mktemp --tmpdir -d tmp.nix-cache-push.XXXXXXXXXX)"
CLOSURE_FILE="$(mktemp --tmpdir tmp.nix-cache-push.closure.XXXXXXXXXX)"
MISSING_CLOSURES="$(mktemp --tmpdir tmp.nix-cache-push.tocopy.XXXXXXXXXX)"
cleanup() {
  rm -rf "$SCRATCH_DIR" "$CLOSURE_FILE" "$MISSING_CLOSURES"
}
trap cleanup EXIT

# Given a list of desired packages, resolve them to the one or more store paths
# in the local system
readarray -t output_paths < <(
  for PACKAGE in "${PACKAGES[@]}"; do
    nix_cmd build --no-link --print-out-paths "$PACKAGE"
  done
)
nix_cmd path-info --recursive "${output_paths[@]}" > "$CLOSURE_FILE"

# Pull narinfos from the remote, so paths it already has are skipped below.
rsync \
  -a --include='/nix-cache-info' --include='/*.narinfo' --exclude='*' \
  "$REMOTE/" "$SCRATCH_DIR/"

# Run the `fetch-narinfos.py` script, which will fetch all the `.narinfos`
# it can from cache.nixos.org. The ones that cannot be fetched are printed to
# stdout.
nix-shell -p "python3.withPackages(ps: [ ps.niquests ])" \
    --run "'$SCRIPT_DIR/fetch-narinfos.py' '$SCRATCH_DIR' '$CLOSURE_FILE'" \
    > "$MISSING_CLOSURES"
readarray -t store_paths < "$MISSING_CLOSURES"

# Save which narinfos are present, these will be deleted before the scratch
# directory is re-pushed back to the remote
existing_narinfos=("$SCRATCH_DIR"/*.narinfo)

# Actually perform the copy of the store paths. All the packages for which the
# `.narinfo` is already present will be skipped.
if [[ ${#store_paths[@]} -gt 0 ]]; then
    nix_cmd copy \
      --to "file://$SCRATCH_DIR?secret-key=$(realpath "$SECRET_KEY_FILE")" \
      --no-recursive \
      "${store_paths[@]}"
fi

# Delete the narinfos which were present before `nix copy` was run
if [[ ${#existing_narinfos[@]} -gt 0 ]]; then
    rm "${existing_narinfos[@]}"
fi

# Push back the newly created files, in 2 phases:
# 1. Everything but narinfos
# 2. Only the narinfos
# This allows the data to be consistent mid-transfer, since narinfos are the
# source of truth of the binary cache
rsync -a --ignore-existing --exclude='*.narinfo' "$SCRATCH_DIR/" "$REMOTE/"
rsync -a --ignore-existing --include='/*.narinfo' --exclude='*' "$SCRATCH_DIR/" "$REMOTE/"
