---
title: "Test coverage push for id-didi-sh"
lede: "Line coverage is 68% and nobody ever tried to raise it — the branch named for this held a feature instead. Five phases, security-relevant paths first, ending in a pinned threshold so the number cannot quietly slide again."
date_created: 2026-11-26
date_modified: 2026-11-26
authors:
  - Michael Staton
augmented_with:
  - Claude Code on Claude Opus 5.5
semantic_version: 0.0.1.0
status: Partially-Shipped
tags:
  - Plan
  - Test-Coverage
  - OAuth
  - Security
  - Elixir
  - Id-Didi-Sh
site_uuid: 2b607fc5-e7c3-4b67-8740-d3fc44066cd0
hex_code: 7i1y1u
date_authored_initial_draft: 2026-11-26
date_authored_current_draft: 2026-11-26
publish: false
type: Plans
---

# Test coverage push for id-didi-sh

## Where this starts

`mix test --cover` on `main` at `97fe67a`: **137 tests green, 67.97% line
coverage**, failing Elixir's default 90% threshold. No `test_coverage:` key in
`mix.exs`, so that 90% is an accident, not a decision.

`hygene/test-coverage` was never coverage work — see
`context-v/issues/Resolve-Two-Important-Branches-Tests-&-Workspaces.md`. Its
salvageable behaviors (the four entity tests) already landed on `main`. This
plan is the coverage work that branch name promised.

## The rule for what counts

Coverage is a proxy. The goal is that **every branch a request can take through
the trust boundary is pinned by a test**, and the number follows. So:

- Each test asserts a behavior a consumer or attacker could observe
  (status, header, body, row), never "the function was called."
- Measurement artifacts get **ignored**, not tested into submission. A HEEx
  `embed_templates` module reads 0% even when its controller is at 100%
  (`PageController` 100% / `PageHTML` 0%) — the cover tool attributes template
  code to the `.heex` file. Testing those modules directly would prove nothing.
- Generator boilerplate nobody edits (`CoreComponents`) is ignored the same way.
  If we start editing it, it comes off the ignore list.

## Phase 1 — the trust boundary (security-relevant, lowest coverage)

| Module | Now | Uncovered behavior to pin |
|---|---|---|
| `OAuthTokenController` | 57% | HTTP Basic client auth (RFC 6749 §2.3.1), including `www-authenticate` on a Basic `invalid_client`; body-only `invalid_client` has no such header; missing `grant_type` → `invalid_request`; unknown grant → `unsupported_grant_type`; `cache-control: no-store` + `pragma: no-cache` on every response, errors included; malformed Basic header falls back to the body |
| `Plugs.CORS` | 45% | listed origin gets exact echo + credentials + `vary: origin`; unlisted origin gets no CORS headers at all; no `Origin` header is a no-op; preflight `OPTIONS` from a listed origin → 204, methods/headers/max-age, halted; preflight from an unlisted origin is **not** answered with CORS headers |
| `Keys` | 67% | `ID_SIGNING_JWK` env wins over the dev key; neither present and dev keys disallowed → raises with the `mix id.gen.keypair` hint; `kid` is the RFC 7638 thumbprint; public JWK carries no private `d` |
| `AuthController` | 75% | non-email input re-renders with an error; missing `email` param re-renders; unknown address renders the **same** "sent" page as a known one (enumeration oracle); a `return_to` outside `/oauth/authorize` is dropped |

`Keys` caches in `:persistent_term`, so its tests clear the cache in
`setup`/`on_exit` and run `async: false`. The env-var test restores the
variable afterwards.

## Phase 2 — the browser surfaces that write

| Module | Now | Behavior to pin |
|---|---|---|
| `AccountController` | 0% | signed-out → redirect to `/auth` for every action; `show` renders entities and the labelled legacy-orgs block; profile save; alias add (good, invalid, duplicate); entity create makes the creator `org_admin`; `slug_taken` flash; add member: non-admin refused, empty email refused, known user added, unknown address invited (invite row exists, email sent) |
| `CredentialController` / `EntityController` | ~78% | the remaining error branches (unknown ids, forbidden, bad params) — enumerate from the cover HTML, don't guess |
| `InviteNotifier` | 69% | the branch not hit by the invite flow |

## Phase 3 — operator tooling

| Module | Now | Approach |
|---|---|---|
| `Mailer.ResendAdapter` | 0% | `Req.Test` stub: 2xx → `{:ok, body}`; 4xx → `{:error, {status, body}}`; transport error → `{:error, reason}`; nil fields dropped from payload; `{name, addr}` formatting. Needs a `plug:` option threaded through config so tests never touch the network |
| `Mix.Tasks.Id.*` (7 tasks) | 0% | Each task run with `Mix.Task.rerun/2` against the sandbox repo, asserting the rows/output. `id.email.test` uses the test mailer. `id.gen.keypair` asserts it prints a parseable Ed25519 JWK |
| `Release` | 0% | **Ignored.** Release-only entry point; `rollback/2` is destructive and it is generator code |

## Phase 4 — pin the number

In `mix.exs`:

```elixir
test_coverage: [
  summary: [threshold: <measured floor>],
  ignore_modules: [
    ~r/^IdDidiShWeb\..*HTML$/,       # embed_templates (matched without "Elixir.")
    IdDidiShWeb.Layouts,             # embed_templates
    IdDidiShWeb.CoreComponents,      # generator output
    IdDidiShWeb,                     # the `use` macro module
    IdDidiSh.Application, IdDidiShWeb.Telemetry,  # supervision wiring
    IdDidiSh.Release,                # see Phase 3
    IdDidiSh.DataCase, IdDidiShWeb.ConnCase  # test support
  ]
]
```

The threshold is set to the measured result **rounded down to the integer**,
not to an aspirational number — a threshold above reality gets disabled the
first time it blocks a hotfix. `precommit` gains `test --cover`.

## Phase 5 — prod config smoke via Doppler (separate, optional)

`MIX_ENV=prod mix run` fails locally because `config/runtime.exs` raises without
`DATABASE_PATH`, `SECRET_KEY_BASE`, and friends. Doppler (CLI 3.77.1 installed,
this directory not yet linked to a project) can supply them:

```bash
doppler setup                      # link this dir to the id-didi-sh project/config
doppler run -- env MIX_ENV=prod mix run --no-start \
  -e 'IO.inspect IdDidiSh.OAuth.resources()'
```

This proves the prod config resolves (e.g. that `kay-os` is in the prod
resource list) without deploying. It is **not** part of the coverage gate:
tests must keep passing with zero secrets, or CI and every fresh clone break.
Secrets stay in Doppler; nothing from it is written to `context-v/`,
`changelog/`, or any committed file.

## Done when

- [x] Phase 1 tests green (`539bb57`)
- [x] Phase 2 tests green (`90f1d74`)
- [x] Phase 3 tests green (`be24d4d`)
- [x] Phase 1b, added mid-push: every OAuth grant refusal, `Token.verify`,
      and the headless API's 400/401s (`0ef6497`). The cover report showed
      these were the largest security-relevant gap left
- [x] `test_coverage` pinned in `mix.exs` at **92** (measured 92.87%),
      `precommit` runs `test --cover`
- [x] changelog entry
- [ ] Phase 5 (Doppler): the `id-didi-sh` project exists with `dev`,
      `dev_personal`, `prd`; `prd` holds no secrets yet
- [ ] No CI runs `mix test`. The gate holds only where `precommit` runs
- [ ] `origin/hygene/test-coverage` deleted, branch issue marked Resolved
      (needs Michael's go-ahead — not yet given)
