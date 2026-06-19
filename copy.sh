#!/usr/bin/env bash
#
# Given a rsync remote and a list of nix package(s), push the incremental set of
# derivations to the remote as a binary cache. This is done with the following
# steps:
# 1. Generate the transitive closure of all the derivations from the specified
#    package(s) and compute the store path for each
# 2. For each store path, check if it has been signed by `cache.nixos.org`, if
#    so, skip the store path
# 3. Sift out store paths that have the `revngPrivate` attribute, if so it will
#    be sent to the private remote otherwise the public remote
# 4. Copy all the `.narinfo`s from the rsync remote to a scratch directory
# 5. Run the remaning store paths with `nix-copy.py` which will create the
#    narinfos and nars just like `nix copy` in a scratch directory, skipping any
#    archive that's already present
# 6. rsync the scratch directory to the remote
#
# Usage:
#   copy.sh <rsync-target-1> <rsync-target-2> <package> [<package>...]
#
#   <rsync-target-1>  any rsync-compatible destination, public remote
#   <rsync-target-2>  any rsync-compatible destination, private remote
#   <package>         One or more packages / flake refs, e.g. `nixpkgs#openssl`
#
# Environment variables:
#   SECRET_KEY_FILE   REQUIRED. This is the secret key that will be used for
#                     signing the new `.narinfo`s before uploading them to the
#                     remote.

set -euo pipefail

SCRIPT_DIR=$(realpath "$(dirname "${BASH_SOURCE[0]}")")

# Argument parsing
REMOTE_PUBLIC="${1%/}"
REMOTE_PRIVATE="${2%/}"
shift; shift;
PACKAGES=("$@")

# Given a list of (possibly failed) desired packages, resolve them to the one
# or more store paths in the local system, including both build and non-build
# dependencies
readarray -t ALL_STORE_PATHS < <(
  cat \
    <(
      nix derivation show -r "${PACKAGES[@]}" | \
        jq -r '.derivations[].inputs.drvs | keys[]' | \
        sed 's;^;/nix/store/;' | \
        nix derivation show -r --stdin
    ) \
    <(nix derivation show -r "${PACKAGES[@]}") | \
  jq -r '.derivations[].outputs[].path' | \
  grep -v '^null$' | sort | uniq | \
  sed 's;^;/nix/store/;'
)

# Filter away all derivations that are not signed with the nixos signing key
# This avoids copying derivations that were fetch from cache.nixos.org
readarray -t NON_NIXOS_STORE_PATHS < <(
  for STORE_PATH in "${ALL_STORE_PATHS[@]}"; do
    if [[ -d "$STORE_PATH" ]]; then
      echo "$STORE_PATH"
    fi
  done | \
  nix path-info --json --json-format 1 --stdin | \
  jq -r 'to_entries[] | .key + " " + (.value.signatures | join(" "))' | \
  grep -v ' cache\.nixos\.org-' | \
  cut -d' ' -f1
)

# Sort the store paths so that the ones with the `revngPrivate` record are
# pushed to the private remote and all the others to the public one
PUBLIC_STORE_PATHS=()
PRIVATE_STORE_PATHS=()
while IFS=' ' read -r STORE_PATH IS_PRIVATE; do
  if [[ "$IS_PRIVATE" -eq 0 ]]; then
    PUBLIC_STORE_PATHS+=("$STORE_PATH")
  else
    PRIVATE_STORE_PATHS+=("$STORE_PATH")
  fi
done < <(
  nix derivation show "${NON_NIXOS_STORE_PATHS[@]}" | \
    jq -r '.derivations[].env | (.out + " " + (.revngPrivate // "0"))'
)

function upload_stores() {
  local REMOTE="$1"
  shift;
  local STORE_PATHS=("$@")

  local SCRATCH_DIR
  SCRATCH_DIR="$(mktemp --tmpdir -d tmp.nix-cache-push.XXXXXXXXXX)"
  trap 'rm -rf "$SCRATCH_DIR"' EXIT

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

  rm -rf "$SCRATCH_DIR"
  trap - EXIT
}

upload_stores "$REMOTE_PUBLIC" "${PUBLIC_STORE_PATHS[@]}"
upload_stores "$REMOTE_PRIVATE" "${PRIVATE_STORE_PATHS[@]}"
