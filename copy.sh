#!/usr/bin/env bash
#
# Given a rsync remote and a list of nix package(s), push the incremental set of
# derivations to the remote as a binary cache. This is done with the following
# steps:
# 1. Generate the transitive closure of all the derivations from the specified
#    package(s) and compute the store path for each
# 2. For each store path, check if it has been signed by `cache.nixos.org`, if
#    so, skip the store path
# 3. Copy all the `.narinfo`s from the rsync remote to a scratch directory
# 4. Run the remaning store paths with `nix-copy.py` which will create the
#    narinfos and nars just like `nix copy` in a scratch directory, skipping any
#    archive that's already present
# 5. rsync the scratch directory to the remote
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

# Argument parsing
REMOTE="${1%/}"
shift
PACKAGES=("$@")

SCRATCH_DIR="$(mktemp --tmpdir -d tmp.nix-cache-push.XXXXXXXXXX)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

# Given a list of desired packages, resolve them to the one or more store paths
# in the local system
readarray -t OUTPUT_PATHS < <(
  for PACKAGE in "${PACKAGES[@]}"; do
    nix build --no-link --print-out-paths "$PACKAGE"
  done
)
readarray -t STORE_PATHS < <(
  nix path-info --recursive --json --json-format 1 "${OUTPUT_PATHS[@]}" | \
  jq -r 'to_entries[] | .key + " " + (.value.signatures | join(" "))' | \
  grep -v ' cache\.nixos\.org-' | \
  cut -d' ' -f1
)

# Pull narinfos from the remote, so paths it already has are skipped below.
rsync \
  -a --include='/nix-cache-info' --include='/*.narinfo' --exclude='*' \
  "$REMOTE/" "$SCRATCH_DIR/"

# Copy only the needed store paths into the scratch dir
"$SCRIPT_DIR/nix-copy.py" "$SCRATCH_DIR" "${STORE_PATHS[@]}"

# Push back the newly created files, in 2 phases:
# 1. Everything but narinfos
# 2. Only the narinfos
# This allows the data to be consistent mid-transfer, since narinfos are the
# source of truth of the binary cache
rsync -a --ignore-existing --exclude='*.narinfo' "$SCRATCH_DIR/" "$REMOTE/"
rsync -a --ignore-existing --include='/*.narinfo' --exclude='*' "$SCRATCH_DIR/" "$REMOTE/"
