# id-didi-sh

**The identity plane for the didi.sh service family** — one small, owned
auth service behind `id.didi.sh`. Create an account once (from inside
whichever app invited you), and you're signed in across **memos**
(memopop-ai), **decks** (dididecks-ai), and **augment-it** via a single
`.didi.sh` session cookie.

> **Status: pre-implementation.** The spec is written and the stack is
> decided; increment 1 (the Phoenix walking skeleton) is next. The canonical
> spec lives in the parent pseudomonorepo:
> [`ai-labs/context-v/specs/Id-Didi-Sh-Identity-Service.md`](https://github.com/lossless-group/lossless-ai-labs/blob/main/context-v/specs/Id-Didi-Sh-Identity-Service.md)

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

- [ ] **1 — Walking skeleton.** `mix phx.new`, migrations, keypair,
      magic-link issue → redeem → cookie → offline verify → `/api/me`,
      proven by a curl script.
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

Prereqs: Elixir ≥ 1.18 / OTP 27 (asdf or Homebrew), and — once increment 1
lands — `mix setup` will be the one-command bootstrap. Local dev uses a
host-only cookie on `localhost` and a dev keypair; the `.didi.sh` cookie is
only meaningful deployed.

Secrets (signing keypair, R2 credentials, email API key, OAuth client
secrets) come from the environment — never committed, never in this repo.

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
