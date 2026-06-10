#!/usr/bin/env bash
# Run ON THE CACHE SERVER, once, to prepare the two static binary caches.
#
# Creates the cache directories, an unprivileged push user, and one signing
# key per cache. The push user writes the cache files over SSH; nginx reads
# them. Neither needs root, and no Nix daemon serves a live store.
#
#   sudo ./setup-server.sh
#
# Env overrides (all optional):
#   PUBLIC_HOST   PRIVATE_HOST   — used only to name the signing keys
#   PUBLIC_DIR    PRIVATE_DIR    — cache directories
#   KEYDIR        PUSH_USER      NGINX_USER
set -euo pipefail

PUBLIC_HOST=${PUBLIC_HOST:-cache.example.com}
PRIVATE_HOST=${PRIVATE_HOST:-cache-internal.example.com}
PUBLIC_DIR=${PUBLIC_DIR:-/srv/nix-cache/public}
PRIVATE_DIR=${PRIVATE_DIR:-/srv/nix-cache/private}
KEYDIR=${KEYDIR:-/etc/nix/cache-keys}
PUSH_USER=${PUSH_USER:-nixpush}
NGINX_USER=${NGINX_USER:-www-data}

command -v nix-store >/dev/null || { echo "nix must be installed on the server"; exit 1; }

# Unprivileged user that receives SSH pushes.
if ! id "$PUSH_USER" >/dev/null 2>&1; then
  useradd --system --create-home --shell /bin/bash "$PUSH_USER"
fi
install -d -m 700 -o "$PUSH_USER" -g "$PUSH_USER" "/home/$PUSH_USER/.ssh"
touch "/home/$PUSH_USER/.ssh/authorized_keys"
chown "$PUSH_USER:$PUSH_USER" "/home/$PUSH_USER/.ssh/authorized_keys"
chmod 600 "/home/$PUSH_USER/.ssh/authorized_keys"

# Cache dirs: push user writes, nginx reads.
for d in "$PUBLIC_DIR" "$PRIVATE_DIR"; do
  install -d -m 755 -o "$PUSH_USER" -g "$NGINX_USER" "$d"
done
# Private cache should not be world-readable on disk either.
chmod 750 "$PRIVATE_DIR"

# One signing key per cache. Public keys go to clients' trusted-public-keys.
install -d -m 750 -o "$PUSH_USER" -g "$PUSH_USER" "$KEYDIR"
gen_key() {
  local name=$1 secret=$2 public=$3
  if [ ! -f "$secret" ]; then
    nix-store --generate-binary-cache-key "$name" "$secret" "$public"
    chown "$PUSH_USER:$PUSH_USER" "$secret" "$public"
    chmod 600 "$secret"
  fi
}
gen_key "${PUBLIC_HOST}-1"  "$KEYDIR/public.secret"  "$KEYDIR/public.pub"
gen_key "${PRIVATE_HOST}-1" "$KEYDIR/private.secret" "$KEYDIR/private.pub"

cat <<EOF

Server prepared.

  push user        : $PUSH_USER  (add client public keys to ~/.ssh/authorized_keys)
  public cache dir : $PUBLIC_DIR
  private cache dir: $PRIVATE_DIR
  signing keys     : $KEYDIR/{public,private}.secret

Add these to your Nix clients' nix.settings.trusted-public-keys:
  $(cat "$KEYDIR/public.pub")
  $(cat "$KEYDIR/private.pub")

Point client/push.sh at this server with:
  CACHE_SSH=$PUSH_USER@$PUBLIC_HOST
  PUBLIC_CACHE_DIR=$PUBLIC_DIR   PUBLIC_SIGN_KEY=$KEYDIR/public.secret
  PRIVATE_CACHE_DIR=$PRIVATE_DIR PRIVATE_SIGN_KEY=$KEYDIR/private.secret
EOF
