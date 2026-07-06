# id-didi-sh

**The identity plane for the didi.sh service family** — one small, owned
auth service behind `id.didi.sh`. Create an account once (from inside
whichever app invited you), and you're signed in across **memos**
(memopop-ai), **decks** (dididecks-ai), and **augment-it** via a single
`.didi.sh` session cookie.

> **Status: increment 1 shipped** — the walking skeleton is proven live; see
> the increments checklist below. The canonical spec lives in the parent
> pseudomonorepo:
> [`ai-labs/context-v/specs/Id-Didi-Sh-Identity-Service.md`](https://github.com/lossless-group/lossless-ai-labs/blob/main/context-v/specs/Id-Didi-Sh-Identity-Service.md)
>
> **Splash:** [lossless-group.github.io/id-didi-sh](https://lossless-group.github.io/id-didi-sh/) —
> the repo's Pages presence (`splash/`), carrying the platform pitch and the build log.
>
> **Landing:** `landing/` — the same pitch as a conversion surface for the
> apex **didi.sh**, deployed on Vercel (domain registered there); see
> `landing/README.md` for the one-time wiring.

## What it is

The didi.sh platform converges its three independently-built,
independently-deployed services on exactly two shared planes: this identity
service, and the didi agent. This repo is the first one.

The design follows a GTM constraint that shaped everything: **nobody
searches for a platform** — they search for a deck designer or a memo
generator. So each service is its own front door, and this service is
**headless-first**: accounts are created *from inside the app the user is
working in*, through an API the app calls from its own branded signup UI.
The service owns the pixels; id.didi.sh owns the record and the session.

## The contract

A consumer (any `*.didi.sh` service) ever sees three artifacts:

1. **A cookie** — `didi_session`, `Domain=.didi.sh`, `HttpOnly`, `Secure`,
   `SameSite=Lax`. The value is a short-lived (~12h) **EdDSA-signed token**
   verified *locally* by every service: signature + `exp`, no network call
   per request. If this service is briefly down, existing traffic keeps
   flowing — only new logins and refreshes wait.
2. **A JSON API** at `id.didi.sh/api/*` — magic-link issue/redeem, invite
   redeem (the only account-creation path; invite-only, no self-serve
   signup, no passwords), OAuth start/callback, session refresh/logout,
   `GET /api/me` for org + role claims.
3. **A public key set** at `/.well-known/jwks.json`.

Behind the contract: a 30-day rolling server-side session is the refresh and
revocation authority; the org model is **domain-as-id** (`lossless.group`,
`trychroma.com`, …) with five org-wide roles (`superuser` / `org_owner` /
`org_admin` / `editor` / `viewer`); the stable person id is **`didi_id`**
(UUIDv7), minted here and only here. Only this service mints sessions —
consumers verify, never sign.

## Stack

**Elixir / Phoenix** — deliberately the polyglot exception in the Lossless
tree, and safe here specifically: the headless contract means no consumer
imports this service's code, so the implementation language is invisible by
design.

| Piece | Choice |
|---|---|
| Framework | Phoenix (1.8.x) — `phx.gen.auth` is magic-link-first, which is our primary credential pathway |
| OAuth client flows | Assent (GitHub, Google Workspace w/ per-org domain allowlist; LinkedIn follows) |
| Token signing | JOSE (erlang-jose), EdDSA/Ed25519 (ES256 fallback) |
| Store | Ecto + a **libSQL** file — `exqlite`/`ecto_sqlite3` compiled against the libSQL amalgamation. SQLite-compliant file + C API today; flipping to a Turso-synced replica is the named upgrade path |
| Backup | Litestream replicating to Cloudflare R2 |
| Email (magic links) | Swoosh (provider TBD: Resend vs Postmark) |
| Admin console | Phoenix LiveView at `/admin` (`superuser` only) — invites, orgs, memberships, sessions, auth-event log |
| Serving | Bandit; multi-stage Dockerfile → OTP release, single container + volume |

## Consumers

| Service | Adapter |
|---|---|
| augment-it (first) | TS verify on the workspace WS gate; replaces the flat token map. First real users: the reach-edu and humain-vc client teams |
| decks (dididecks-ai) | Astro middleware port of the calmstorm gate |
| memos web (memopop-ai) | Same TS adapter |
| memos desktop (Tauri) | System-browser flow → one-time code exchange → keychain-held bearer token, verified by the FastAPI sidecar via PyJWT + JWKS |

Verification snippets (TS `jose`, Python `PyJWT`, ~30 lines each) ship as
documentation for consumers to copy in — **no shared package, on purpose.**

## Implementation increments

- [x] **1 — Walking skeleton** *(2026-07-06)*. Full schema migration,
      Ed25519 keypair + JWKS, magic-link issue → redeem → `didi_session`
      cookie → `/api/me` → refresh → logout. 19 tests green; proven live by
      `scripts/prove-skeleton.sh`.
- [ ] **2 — First consumer.** augment-it's TS verify adapter + access panel,
      dev-mode against localhost.
- [ ] **3 — Invites + admin.** Invite tokens, LiveView console, auth events.
      This increment makes client onboarding real.
- [ ] **4 — OAuth.** GitHub → Google Workspace (domain allowlist) →
      LinkedIn; account-linking rules ported from fullstack-vc's merge chain.
- [ ] **5 — Deploy.** `id.didi.sh` live; fullstack-vc identities imported
      (email → `didi_id`); first client invites go out.
- [ ] **6 — Consumers two and three.** decks middleware, memos web, the
      Tauri device-exchange flow.

## Development

First-time setup (macOS):

```sh
brew install elixir                # Elixir ≥ 1.18 / OTP 27 (asdf works too)
mix archive.install hex phx_new    # the Phoenix project generator
```

Then:

```sh
mix setup                                  # deps + db + migrations + assets
mix id.seed alice@example.com "Alice"      # invite stand-in until increment 3
mix phx.server                             # http://localhost:4000
./scripts/prove-skeleton.sh                # the increment-1 acceptance proof
mix test                                   # the suite
```

Local dev uses a host-only cookie on `localhost` and an auto-generated dev
keypair (`priv/keys/`, gitignored); the `.didi.sh` cookie is only meaningful
deployed. `mix id.gen.keypair` produces the production `ID_SIGNING_JWK`.
Dev-only: magic-link responses echo the raw token (`echo_login_tokens`) so
the prove script runs without reading the Swoosh mailbox at `/dev/mailbox`.

Secrets (signing keypair, R2 credentials, email API key, OAuth client
secrets) come from the environment — never committed, never in this repo.

## Deploy (Fly.io → id.didi.sh)

The deploy artifacts are committed: `fly.toml` (lax region, port 8080, a
Fly Volume at `/data` for the libSQL file, migrations run **at boot** —
never as a `release_command`, which runs on an ephemeral machine without
the volume) and a release `Dockerfile` generated by
`mix phx.gen.release --docker`, pinned to the repo's toolchain.

One-time setup:

```sh
brew install flyctl                # the CLI (installs the `fly` command)
fly auth login                     # browser auth

fly apps create id-didi-sh
fly volumes create idds_data --region lax --size 1 -a id-didi-sh

# Secrets — NEVER plaintext env vars, never committed:
fly secrets set -a id-didi-sh \
  SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  ID_SIGNING_JWK="$(mix id.gen.keypair | sed -n 's/^{/{/p' | head -1)"
```

Deploy + wire the domain:

```sh
fly deploy                          # builds remotely from the Dockerfile
fly certs add id.didi.sh -a id-didi-sh

# DNS lives in Vercel (the didi.sh registrar):
vercel dns add didi.sh id CNAME id-didi-sh.fly.dev
```

Verify: `curl https://id.didi.sh/.well-known/jwks.json` returns the
public key, and `scripts/prove-skeleton.sh` runs against
`BASE=https://id.didi.sh` (dev-token echo is off in prod, so the
magic-link step requires a real mailbox — increment 3's invites are the
production onboarding path).

Notes: `auto_stop_machines` is off on purpose — the identity plane must
not cold-start under JWKS and refresh traffic. Litestream→R2 backup is
the named follow-up before real client accounts exist; until then Fly
volume snapshots are the recovery story.

## Lineage

This service supersedes the earlier plan to extract a vendored
`lossless-auth-core` package. Prior art it draws on:

- [`Shared-Auth-for-Applied-AI-Labs`](https://github.com/lossless-group/lossless-ai-labs/blob/main/context-v/explorations/Shared-Auth-for-Applied-AI-Labs.md) — the architecture source (pathways, org model, roles, scale posture)
- [`Didi-sh-One-Login-One-Agent-Three-Services`](https://github.com/lossless-group/lossless-ai-labs/blob/main/context-v/explorations/Didi-sh-One-Login-One-Agent-Three-Services.md) — the platform frame and the GTM headless requirement
- `dididecks-ai` → `Calmstorm-Auth-Inventory` — audited session/token/invite mechanics (ported as semantics, not code)
- `astro-knots/sites/fullstack-vc` — three-provider OAuth + account-linking merge chain (users imported at launch; code ported as reference)

---

Part of [The Lossless Group](https://github.com/lossless-group)'s `ai-labs`
pseudomonorepo. Every repo here keeps a `context-v/` (living documentation)
and a `changelog/` (ship log) — start there.
