---
title: "Loop log — entities and keys"
lede: "One entry per increment: the gate, the result, and anything decided that the plan did not cover."
date_created: 2026-08-20
date_modified: 2026-08-20
authors:
  - Michael Staton
augmented_with:
  - Claude Code on Claude Opus 5
tags:
  - Loop
  - Id-Didi-Sh
  - Entities
site_uuid: 7f2c4d81-3ba6-4e19-9c02-1d5e8a3f6b47
hex_code: lp4vnz
date_authored_initial_draft: 2026-08-20
date_authored_current_draft: 2026-08-20
publish: false
---

# Loop log — entities and keys

Plan: [[Entities-and-Keys-Implementation-Plan]]. Contract:
`ai-labs/context-v/specs/Flexible-Entity-Relationships-to-Mirror-Messy-IRL-Collaboration.md`.

## Increment 1 — entities schema + context — ✅ PASSED 2026-08-20

**Built:** migration `20260820000001_create_entities`, `IdDidiSh.Entities`
context, `Entity` / `EntityMembership` schemas, `mix id.entity`, 10 tests.

**Gate:** `mix test` green and `mix id.entity` creates an entity and adds a
member. Both observed — suite went 29 → **39 passed**, and against the dev DB:

```
entity 01a0228e-80c9-7725-9f2f-c6f354476acc  project/apollo  Apollo Program
mps@didi.sh is editor in project/apollo
```

**Invariant tests now in the suite:**
- `entities have no parent_id` — a schema assertion, so a future migration
  adding containment fails loudly (Ruling 1)
- `removing a member from one entity leaves other memberships intact` — both
  directions (Ruling 1b)
- `also_member_of/2 powers the removal disclosure`

**Decided in flight, not in the plan:**

1. **`effective_role/2` is membership-only for now, with no lender stub.** The
   plan implied a `lender?` helper returning false until increment 4. Elixir
   1.20's type checker correctly flagged the resulting branch as dead. A stub
   that always returns false lies to both the reader and the compiler, so the
   function is honestly membership-only with a comment marking where increment 4
   slots in.
2. **`mix id.entity` deliberately has no `remove` verb.** Removal must show what
   access survives (Ruling 1b), which is a conversation, not a one-liner. It
   belongs in the API and the LiveView, not a mix task that would let an operator
   remove someone while blind.

**Not done, deliberately:** HTTP endpoints (increment 2).

## Increment 2 — entity HTTP endpoints — ✅ PASSED 2026-08-20

**Built:** `IdDidiShWeb.Plugs.RequireUser`, `EntityController`, six routes under
an `:api_authed` pipeline, 10 controller tests. Suite 39 → **49 passed**, clean
compile.

**Gate:** `DELETE /api/entities/:entity_id/members/:didi_id` returns
`also_member_of`, and removal from one entity leaves the others intact. Both
asserted, including the DB-level check that the surviving membership is really
still there rather than merely reported.

**Decided in flight:**

1. **The disclosure ships as a rendered sentence, not just data.** The response
   carries `also_member_of` (the list) *and* `disclosure` — "Bob will keep access
   to: Apollo, Q3 Diligence." If every client composes its own sentence, some
   client eventually omits it. Putting the words in the API makes the honest
   thing the default.
2. **Survivors are read BEFORE the delete**, so the response describes the world
   the caller is creating rather than racing it.
3. **Auth extracted to a plug.** `MeController` does the three-step check inline
   (token → live session row → user). Copying that per action is how one endpoint
   quietly loses the session-row check, so `RequireUser` does it once.
4. **Creator becomes `org_owner`** of what they create — otherwise an entity is
   born with nobody able to administer it. Note the vocabulary strain: `org_owner`
   on a *project* reads oddly (plan OQ 2, still open).
5. **Adding a non-existent user returns `unknown_user_invite_not_implemented`**
   rather than half-creating something. The invite path through `login_tokens`
   exists but is not wired to entities; named explicitly so it is not mistaken for
   a bug.

**Not done, deliberately:** `PATCH /api/entities/:id` (no caller yet), and
`GET /api/users/:didi_id/entities` — `also_member_of` already covers the
disclosure, and a general "where is this person" endpoint wants an authorization
story of its own.

## Increment 2b — invite by email — ✅ PASSED 2026-08-20

Not in the original plan. Added because increment 2 shipped a limitation
(`unknown_user_invite_not_implemented`) and the machinery to close it already
existed: `login_tokens` carries `kind ∈ magic_link | invite`, and the Resend
adapter is wired.

**Built:** migration adding `login_tokens.entity_id`; `Accounts.issue_invite/2`
and `redeem_invite/1`; `InviteNotifier`; `AccessController` redeeming either
token kind; `EntityController.add_member` inviting when the email is unknown.
Suite 49 → **55 passed**.

**Gate:** invite an unknown email → 202 + mail from `no-reply@didi.sh` → redeem
→ account created **and** membership attached. Asserted end to end, including
that the invite is single-use.

**Decided in flight:**

1. **202, not 201, for an invite.** Adding someone who has never heard of
   didi.sh is not a failure and must not read like one — but it has not happened
   yet either. A 201 would claim a member who cannot sign in.
2. **One landing page, two token kinds.** `/access` tries magic-link then
   invite. The person clicking cannot tell which they hold, so the page must not
   care. Both claims are atomic in their own query, so trying one then the other
   cannot double-claim.
3. **Invite TTL is 7 days**, against 15 minutes for a magic link. An invite is
   often read days later; a sign-in link is used immediately.
4. **Membership attachment is recorded either way** — `invite_membership_attached`
   or `invite_membership_failed` in `auth_events`. A person stranded outside the
   thing they were invited to should leave a trace rather than a silence.
5. **Delivery failure does not lose the invite.** The token row exists whether or
   not the mail sends; the response says `queued_delivery_failed` so an operator
   can resend rather than wonder.

**Stale comment corrected:** `MagicLinkNotifier` said the sender must stay
`onboarding@resend.dev` until didi.sh was verified in Resend. It is verified —
self-host-stack already sends client mail from `no-reply@didi.sh`.

## Increment 3 — credentials, encrypted at rest — ✅ PASSED 2026-08-20

**Built:** `cloak_ecto` + `IdDidiSh.Vault` (AES-256-GCM) + `Encrypted.Binary`
type; migration `20260820000003_create_credentials` with all four tables
(`credentials`, `credential_cascades`, `credential_loans`, `credential_usage`);
`IdDidiSh.Credentials` create / list / revoke; 12 tests. Suite 55 → **65 passed**.

**Gate:** a credential round-trips, and the raw value appears in no API response.
Asserted the strong way — by reading the raw SQLite column with `Repo.query/2`,
bypassing the Ecto type that would decrypt it, and confirming the secret is not
in those bytes. Also asserted that a rendered list, JSON-encoded, contains
neither of two secrets.

**Decided in flight:**

1. **`render/1` is built by naming safe fields, not by dropping unsafe ones.** A
   future column is invisible until someone adds it to the serializer — the
   failure direction you want. A blocklist leaks by default; an allowlist hides
   by default.
2. **Revocation keeps the row.** Deleting a credential would orphan its
   `credential_usage` history, and that history is the lender's record of what
   their card paid for. The key stops working; the evidence stays.
3. **Only the owner may revoke** — `{:error, :not_the_owner}` otherwise. It is
   their key, and an entity admin taking it back is not a thing that can happen.
4. **Short values mask entirely** (`····`) rather than showing four of six
   characters.
5. **The dev/test encryption key is deterministic**, so the suite needs no
   environment setup, and `Vault.init/1` raises in prod when
   `CREDENTIAL_ENCRYPTION_KEY` is missing. The fallback is unreachable where it
   would matter.
6. **All four tables landed in one migration**, per the plan, even though
   increment 3 only uses `credentials`. The lending tables arrive in increment 4
   with no further schema change.

**Not shipped:** this is local only. Per
[[Storage-and-Backups-for-id-didi-sh]], increment 3 must not reach production
before the Turso cutover, so no lent credential is ever written to the
unreplicated Fly volume. Writing the code does not breach that; deploying it
would.
