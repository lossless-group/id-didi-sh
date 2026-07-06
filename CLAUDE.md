# Agent instructions for `id-didi-sh`

**This repo is the polyglot exception in the Lossless tree: Elixir/Phoenix,
not TypeScript.** That is a deliberate, argued decision — see the canonical
spec before proposing a stack change:
`../context-v/specs/Id-Didi-Sh-Identity-Service.md` (in the `ai-labs`
parent). This repo's own `context-v/` holds implementation-local docs only;
the spec of record stays at the parent level.

## Load-bearing invariants (do not weaken casually)

1. **The contract is three artifacts** — the `didi_session` cookie
   (EdDSA-signed, `Domain=.didi.sh`), the JSON API under `/api`, and the
   JWKS endpoint. Consumers depend on nothing else. Changing any of these is
   a cross-service breaking change; flag it, don't slip it in.
2. **Invite-only, no passwords.** The ONLY account-creation path is invite
   redemption. Never add a self-serve signup endpoint or a password column —
   both are explicitly out of scope per the spec.
3. **Only this service mints sessions.** Consumers verify with the public
   key; the signing key never leaves this service. Symmetric algorithms
   (HS256) are forbidden for session tokens — any verifier could mint.
4. **Headless-first.** Consumer apps own the signup/login pixels and call
   the API. Do not grow hosted login pages beyond the minimal `/access`
   fallback and the OAuth callback hop.
5. **No shared packages with consumers.** Verify snippets are documentation
   that consumers copy in. Do not publish a client library — the
   no-shared-code property is what makes the Elixir choice safe.
6. **Store is a libSQL file** (`exqlite` compiled against libSQL), backed up
   via Litestream→R2. Turso-remote is a named future upgrade, not a
   dependency to introduce now.

## Working here

- **Language conventions:** idiomatic Elixir; `mix format` before commit;
  Ecto migrations are append-only once pushed.
- **Secrets** come from the environment only (signing keypair, R2 creds,
  email API key, OAuth client secrets). Never commit a secret; never write
  one to `context-v/` or `changelog/`.
- **Branch:** `main` is the working branch of this repo (mounted as a
  submodule of `ai-labs`, which is also on `main`).
- **Universal directories:** keep `context-v/` and `changelog/` current per
  the tree-wide conventions (`changelog-conventions`, `context-vigilance`
  skills). Ship notes go in `changelog/` with the titled filename pattern.

## See also

- `../CLAUDE.md` — ai-labs parent instructions (Chroma corpus, skills sync)
- `../context-v/specs/Id-Didi-Sh-Identity-Service.md` — the spec of record
- `../context-v/explorations/Didi-sh-One-Login-One-Agent-Three-Services.md`
  — the platform frame (GTM constraint, trust boundary, deploy topology)
