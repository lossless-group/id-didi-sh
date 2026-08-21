---
title: "also_member_of will miss lenders once lending lands"
lede: "The removal disclosure reads memberships only. From increment 4 a person can have access purely by lending a credential, and the disclosure will under-report."
date_created: 2026-08-20
date_modified: 2026-08-20
authors:
  - Michael Staton
augmented_with:
  - Claude Code on Claude Opus 5
semantic_version: 0.0.0.1
status: Open
tags:
  - Issue-Resolution
  - Entities
  - Credentials
  - Id-Didi-Sh
site_uuid: ba9c1569-757d-4b69-880f-b372e8aba828
hex_code: oc9swd
date_authored_initial_draft: 2026-08-20
date_authored_current_draft: 2026-08-20
publish: false
---

# also_member_of will miss lenders once lending lands

## What

`Entities.also_member_of/2` powers the removal disclosure —
*"Bob will keep access to: Apollo, Q3 Diligence."* It queries
`entity_memberships`.

From increment 4, `effective_role/2` also returns `:admin` for anyone with a live
credential loan to an entity, **whether or not they hold a membership row**
(Ruling 2 — the person with the credit card is often not on the project).

## Why it matters

The disclosure exists precisely so nobody believes they offboarded someone who
did not leave. Once lending confers access, a membership-only query produces
exactly that false belief — the most confident possible version of it, because
the UI states it as fact.

`Entities.list_entities_for/1` has the same gap and already carries a note.

## Fix

When increment 4 lands, both functions union in entities where the person has a
live loan. Add a test: a lender with no membership row still appears in
`also_member_of`.

## Related

- `context-v/loops/Entities-and-Keys.md` — increment 4
- Ruling 2, Ruling 1b
