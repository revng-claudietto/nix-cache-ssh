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
#     3. run `nix copy --to file://$tmp ...`; nix sees those narinfos and skips
#        every already-cached path, writing only NEW paths' nar + narinfo,
#     4. rsync only the new files back up.
#
# The push is done in two passes (nars first, narinfos last) -- mirroring nix's
# own write ordering -- so that an interruption can only ever leave a nar
# without a narinfo (harmless: looks invalid, re-uploaded next run), never a
# narinfo without its nar (which would mask a missing blob forever).
#
# Usage:
#   incremental-cache-push.sh <rsync-target> <installable> [<installable>...]
#
#   <rsync-target>  Destination cache root as rsync understands it, e.g.
#                     user@host:/srv/nix-cache
#                     rsync://host/cache
#                     /mnt/nfs/nix-cache            (local path)
#   <installable>   One or more things `nix copy` understands: store paths,
#                   flake refs, etc. Their output closures are pushed.
#
# Optional environment variables:
#   SECRET_KEY_FILE   If set, sign uploaded paths with this key
#                     (passed as `nix copy --secret-key-files`).
#   NO_CHECK_SIGS=1   Pass `--no-check-sigs` to `nix copy`.
#   TMPDIR            Where the temp dir is created. It must have room for all
#                     the NEW nars, so point it at real disk for big closures.
#
set -euo pipefail

usage() {
    sed -n '2,/^set -euo/{/^set -euo/!p}' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage 0
[[ $# -ge 2 ]] || { echo "error: need a rsync target and at least one installable" >&2; usage 1; }

command -v rsync >/dev/null || { echo "error: rsync not found in PATH" >&2; exit 127; }
command -v nix   >/dev/null || { echo "error: nix not found in PATH" >&2; exit 127; }

# --- arguments ---------------------------------------------------------------
remote="${1%/}"          # strip a single trailing slash for consistent rsync semantics
shift

installables=()
for component in "$@"; do
  installables+=("$(nix-build '<nixpkgs>' -A "$component" --no-out-link)")
done

# --- temp dir with guaranteed cleanup ----------------------------------------
tmp="$(mktemp -d "${TMPDIR:-/tmp}/nix-cache-push.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

echo ">> staging cache metadata in $tmp"

# --- step 2: pull ONLY narinfos (+ nix-cache-info) ---------------------------
# Anchored includes match the flat top-level metadata; `--exclude='*'` both
# drops everything else and stops rsync from ever descending into nar/, log/,
# etc., so the big blobs are never enumerated or transferred.
# Non-fatal: a brand-new/empty remote simply yields an empty staging dir, which
# correctly makes every target path "new".
if ! rsync -av \
        --include='/nix-cache-info' \
        --include='/*.narinfo' \
        --exclude='*' \
        "$remote/" "$tmp/"; then
    echo ">> warning: could not pull narinfos (new or empty cache?); treating everything as new" >&2
fi

narinfos_before="$(find "$tmp" -maxdepth 1 -name '*.narinfo' | wc -l)"
echo ">> pulled $narinfos_before existing narinfo(s)"

# --- step 3: let nix copy write only the missing paths -----------------------
copy_args=(--to "file://$tmp" --extra-experimental-features "nix-command flakes")
[[ -n "${SECRET_KEY_FILE:-}" ]] && copy_args+=(--secret-key-files "$SECRET_KEY_FILE")
[[ "${NO_CHECK_SIGS:-0}" == "1" ]] && copy_args+=(--no-check-sigs)
copy_args+=("${installables[@]}")

echo ">> nix copy ${copy_args[*]}"
nix copy "${copy_args[@]}"

new_narinfos="$(($(find "$tmp" -maxdepth 1 -name '*.narinfo' | wc -l) - narinfos_before))"
new_nars="$(find "$tmp/nar" -type f 2>/dev/null | wc -l)"
echo ">> nix copy produced $new_narinfos new narinfo(s) and $new_nars nar file(s)"

if [[ "$new_narinfos" -eq 0 && "$new_nars" -eq 0 ]]; then
    echo ">> nothing new to push; remote already has everything"
    exit 0
fi

# --- step 4: push only the new files, blobs before narinfos ------------------
# `--ignore-existing` transfers only files absent on the remote, i.e. exactly
# the new ones; it never overwrites the narinfos we pulled or anything else.

# Pass 1: everything EXCEPT narinfos (new nars, realisations, logs, .ls,
#         nix-cache-info if we created it, ...).
echo ">> pushing new blobs (pass 1/2)"
rsync -av --ignore-existing \
    --exclude='*.narinfo' \
    "$tmp/" "$remote/"

# Pass 2: the narinfos last, so a path is only "published" once its nar is up.
echo ">> publishing narinfos (pass 2/2)"
rsync -av --ignore-existing \
    --include='/*.narinfo' --exclude='*' \
    "$tmp/" "$remote/"

echo ">> done: pushed $new_nars nar(s) and $new_narinfos narinfo(s) to $remote"
