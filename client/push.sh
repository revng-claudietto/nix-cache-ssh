#!/usr/bin/env bash
# Push a closure to the public or private cache OVER SSH.
#
# The remote Nix writes a signed, static binary cache directly into the cache
# directory on the server (remote-store=file://...&secret-key=...), so the
# cache is ready for nginx to serve the moment the push finishes. Signing
# happens on the server; the secret key never leaves it.
#
#   ./push.sh public  .#hello
#   ./push.sh private /nix/store/xxxxxxxx-internal-tool
#   ./push.sh public  .#pkgA .#pkgB        # any number of installables/paths
#
# Required env (typically from a .env or your shell profile):
#   CACHE_SSH            user@cache-host  (the push user from setup-server.sh)
# Per-cache, as printed by setup-server.sh (paths are ON THE SERVER):
#   PUBLIC_CACHE_DIR  PUBLIC_SIGN_KEY
#   PRIVATE_CACHE_DIR PRIVATE_SIGN_KEY
# Optional:
#   COMPRESSION         nar compression (default: zstd)
set -euo pipefail

usage() { echo "usage: $0 <public|private> <installable-or-store-path>..." >&2; exit 2; }

cache=${1:-}; [ -n "$cache" ] || usage; shift
[ $# -ge 1 ] || usage
: "${CACHE_SSH:?set CACHE_SSH=user@cache-host}"
compression=${COMPRESSION:-zstd}

case "$cache" in
  public)  cache_dir=${PUBLIC_CACHE_DIR:?};  sign_key=${PUBLIC_SIGN_KEY:?} ;;
  private) cache_dir=${PRIVATE_CACHE_DIR:?}; sign_key=${PRIVATE_SIGN_KEY:?} ;;
  *) usage ;;
esac

# Percent-encode a string for safe nesting inside the ssh-ng store URI.
urlencode() {
  local s=$1 i c out=
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) out+=$c ;;
      *) printf -v c '%%%02X' "'$c"; out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

# Realise the closure locally so we push something concrete.
echo ">> building locally: $*" >&2
mapfile -t paths < <(nix build --no-link --print-out-paths "$@")
[ "${#paths[@]}" -gt 0 ] || { echo "nothing built"; exit 1; }

# The destination store, evaluated on the server: a file:// binary cache that
# signs every narinfo with the server-held key as it is written.
remote_store="file://${cache_dir}?secret-key=${sign_key}&compression=${compression}"
to="ssh-ng://${CACHE_SSH}?remote-store=$(urlencode "$remote_store")"

echo ">> pushing ${#paths[@]} path(s) to the ${cache} cache on ${CACHE_SSH}" >&2
nix copy --to "$to" "${paths[@]}"
echo ">> done — ${cache} cache updated and signed on the server" >&2
