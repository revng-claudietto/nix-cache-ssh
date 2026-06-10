# nix-cache-ssh

Two Nix binary caches — one **public**, one **private** — that are:

- **pushed to over SSH**, and **prepared (signed, compressed) on upload** —
  the cache files are ready to serve the instant a push finishes;
- **served as plain static files by nginx** — no cache daemon, nothing reads a
  live `/nix/store`;
- the **private** one is gated by nginx, which validates a **GitLab token**
  before serving — using only stock nginx (no proxy, no njs/Lua, no decoding).

```
 client                         cache server                         gitlab
 ──────                         ────────────                         ──────
 push.sh public  .#x ─ ssh ─▶  nix writes+signs ─▶ /srv/nix-cache/public ─┐
 push.sh private .#y ─ ssh ─▶  nix writes+signs ─▶ /srv/nix-cache/private │
                                                                          │ nginx
 read public  ─────────────────────────────────────▶ static files ◀──────┘ (no auth)

 read private ─ netrc(Basic) ─▶ nginx ─ auth_request, header forwarded as-is ─▶
                                  git: /repo.git/info/refs ─▶ 200/401 ─▶ allow/deny
```

## Why this shape

- **Push = SSH, serve = static.** `nix copy` can target an *SSH store whose
  remote store is a `file://` binary cache*. The remote Nix writes the
  `nix-cache-info` + `*.narinfo` + `nar/*.nar.zst` layout directly into the
  cache directory and **signs each narinfo with a key held on the server**.
  nginx then just serves those files — no harmonia/nix-serve, no daemon, no
  live store.
- **Two caches = two directories**, two signing keys, so a private path can
  never be served from the public cache.
- **Routing is explicit at push time:** `push.sh public …` vs `push.sh private …`.

## How the private cache is authenticated (the key detail)

A vanilla `nix` client authenticates to a substituter with **netrc only**,
i.e. HTTP **Basic**: `Authorization: Basic base64(user:TOKEN)`. (Verified in
the Nix 2.32 source: the HTTP binary-cache store sets no `Authorization`
header and only enables `CURLOPT_NETRC_FILE`. `access-tokens` is for flake
*input* fetchers, not substituters.)

GitLab's **REST API rejects Basic** — but GitLab's **git-over-HTTPS** endpoint
**accepts a GitLab token as the Basic password** (that's how
`git clone https://user:TOKEN@gitlab/...` works, with any non-empty username).

So nginx forwards the client's `Authorization` header **unchanged** to a git
endpoint and lets GitLab decide:

```
auth_request -> GET https://gitlab.example.com/grp/nix-cache-acl.git/info/refs?service=git-upload-pack
   200       -> valid token with read access  -> serve
   401 / 403 -> missing / invalid / no access -> deny
```

No proxy, no JavaScript, no Lua, no base64 decoding. The chosen repo
(`grp/nix-cache-acl`) **is the ACL**: grant it `read_repository` access to
whoever may read the private cache. Personal, project, and group access
tokens all work; so does `$CI_JOB_TOKEN` (use `login gitlab-ci-token`).

## The one push command

`client/push.sh` wraps a single `nix copy` that writes the signed static cache
on the server:

```bash
export CACHE_SSH=nixpush@cache.example.com
export PUBLIC_CACHE_DIR=/srv/nix-cache/public   PUBLIC_SIGN_KEY=/etc/nix/cache-keys/public.secret
export PRIVATE_CACHE_DIR=/srv/nix-cache/private PRIVATE_SIGN_KEY=/etc/nix/cache-keys/private.secret

./client/push.sh public  .#hello
./client/push.sh private /nix/store/xxxx-internal-tool
```

> Signing-key paths are **on the server** — `push.sh` only names them; the key
> material never leaves the cache host.

## Server setup

On the cache host (needs `nix` installed and an `sshd`):

```bash
sudo ./server/setup-server.sh        # creates push user, cache dirs, 2 signing keys
# add each developer's / CI's SSH public key to ~nixpush/.ssh/authorized_keys
```

Then install `server/nginx.conf` (replace `cache.example.com`,
`cache-internal.example.com`, `gitlab.example.com`, `grp/nix-cache-acl`, and
the cache paths) and reload nginx. **Use TLS in production** — the GitLab token
travels as the Basic password and must not be sent in cleartext. The config
has the `listen 443 ssl` lines ready to uncomment. Stock nginx is enough — no
extra modules.

## Consuming the caches

**Public** — nothing special:

```
substituters = https://cache.example.com
trusted-public-keys = cache.example.com-1:...
```

**Private** — point nix at it directly and supply the token via netrc; see
`examples/client-nix.conf` and `examples/netrc.example`:

```
# /etc/nix/nix.conf
substituters = https://cache.example.com https://cache-internal.example.com
trusted-public-keys = cache.example.com-1:...  cache-internal.example.com-1:...
netrc-file = /etc/nix/netrc

# /etc/nix/netrc   (mode 600)
machine cache-internal.example.com
  login nixcache
  password glpat-...        # a read_repository token, or $CI_JOB_TOKEN with login gitlab-ci-token
```

## What was validated

Verified locally with real `nix` + `nginx` (stock build, no modules):

- `nix copy --to ssh-ng://…?remote-store=file://…` pushes over SSH and writes a
  complete, **server-side-signed** static cache (`Sig: …-1:…`).
- nginx serves the public cache as static files (`nix-cache-info`, narinfo, nar).
- **A real `nix` pull with netrc** succeeds with a valid token and is denied
  with an invalid one — the Basic header is forwarded as-is to a (mock) git
  `info/refs` endpoint that returns 200/401, gating both narinfo and nar.
- the auth-verdict cache collapses a multi-object pull into a couple of
  upstream calls; empty-credential requests are rejected without calling GitLab.

Not exercised here: TLS termination and a live GitLab instance (the
`info/refs` Basic behavior is GitLab's documented git-over-HTTPS auth).

## Files

| path | purpose |
|---|---|
| `client/push.sh` | build + push a closure to the public/private cache over SSH (signed server-side) |
| `server/setup-server.sh` | create push user, cache dirs, the two signing keys |
| `server/nginx.conf` | public static vhost + private vhost gated by a GitLab token |
| `examples/client-nix.conf` | substituters + trusted-public-keys + netrc-file |
| `examples/netrc.example` | how nix supplies the GitLab token to the private cache |

## Housekeeping

The caches are plain directories: prune them with `find` by age, or treat them
as disposable and re-push from CI. Because pushes go straight to the `file://`
cache, the server needs **no populated `/nix/store`** and no GC of a serving
store.
