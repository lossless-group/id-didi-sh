---
title: "resolve two important branches — tests and workspaces"
lede: "The workspaces feature is not on feature/workspaces. It is on hygene/test-coverage, unmerged since 2026-08-09, along with a frontmatter sweep and the splash date-chain fix. Nothing on main knows it exists."
date_created: 2026-08-21
date_modified: 2026-08-21
authors:
  - Michael Staton
augmented_with:
  - Claude Code on Claude Opus 5
semantic_version: 0.0.0.1
status: Open
tags:
  - Issue-Resolution
  - Branches
  - Workspaces
  - Test-Coverage
  - Technical-Debt
  - Id-Didi-Sh
site_uuid: 77d42060-854a-4fa6-9905-4ace5a9e39ea
hex_code: 0j8o4a
date_authored_initial_draft: 2026-08-21
date_authored_current_draft: 2026-08-21
publish: false
---

# resolve two important branches — tests and workspaces

## What

Two branches carry work that never reached `main`, and the names actively
mislead about which holds what.

### `hygene/test-coverage` — 7 commits unmerged

Despite the name, **this branch holds an entire feature**, not just tests:

| Commit | Date | What |
|---|---|---|
| `f7a4e79` | | `new(context-v)` — corpora-builder primitives *(docs now on main)* |
| `b0b417c` | 2026-08-09 | **`feat(workspaces)` — the tenancy boundary** |
| `725c5e3` | | `fix(splash)` — teach the date chains the editorial keys |
| `3ebda2c` | | `fix(frontmatter)` — editorial date pair + identity across all 7 changelog entries |
| `8a6d636` | | `doc(context-v)` — normalize frontmatter across 3 files |
| `faa12eb` | | `fix(splash), doc(claude)` — block scalars, editorial dates, browser-drive block |
| `8af9992` | | `doc(context-v)` — frontmatter sweep: identity, dates, ledes, publish flags |

The feature commit adds real, tested code that `main` has never seen:

```
lib/id_didi_sh/accounts/workspace.ex              (new)
lib/id_didi_sh/accounts/workspace_membership.ex   (new)
lib/id_didi_sh/workspaces.ex                      (new)
lib/id_didi_sh_web/controllers/workspace_controller.ex (new)
priv/repo/migrations/20260809000001_workspaces.exs (new)
test/id_didi_sh/workspaces_test.exs               (new)
test/id_didi_sh_web/controllers/workspace_controller_test.exs (new)
lib/id_didi_sh/accounts.ex                        (modified)
lib/id_didi_sh_web/router.ex                      (modified)
```

Its commit message carries a load-bearing invariant worth not losing:

> Derive membership from an email domain and you have built a system that
> structurally cannot express an advisor. So membership is an explicit grant,
> and the granted person's address is irrelevant to it.

`default_domain` survives only as a **self-signup hint**, read in exactly one
function; `role_of/2` never consults it, and there is a test asserting that
clearing or changing a domain cannot revoke anybody — "because it is the mistake
a future reader is most likely to make while *simplifying*."

### `feature/workspaces` — 1 commit unmerged, and it is not workspaces

`219c9e0 doc(notes): what OAuth and OIDC actually are` — a document whose
content already reached `main` by another route. The branch also holds **older**
copies of `splash/src/components/Header.astro` and
`splash/src/layouts/BaseLayout.astro`, predating the interlinking fix in
`204b38a`.

So the branch named for the feature contains none of it.

## Why it matters

**A tested feature is sitting unmerged and unnamed.** `feat(workspaces)` landed
2026-08-09 and nothing on `main` references it. Twelve days later the entities
work shipped a *different* tenancy model — flat `entities` with
`kind: "organization" | "workspace" | "project"` — which may supersede,
duplicate, or conflict with `accounts/workspace.ex`. Nobody has checked. That
check gets harder every week, and the invariant above is exactly the kind of
thing that gets re-derived badly.

**Both branches will resurrect the augment-it DESIGN.md if merged carelessly.**
Each carries the pre-2026-08-21 copies of `splash/DESIGN.md` and
`site/DESIGN.md` — the verbatim augment-it contract, magenta spine and all. A
merge that takes theirs silently undoes this morning's correction.

**`feature/workspaces` is what the `ai-labs` parent currently points at.**
Resolving it moves the parent's gitlink, so it is not a purely local decision.

**The frontmatter sweep is coupled to a splash change.** `3ebda2c` adds editorial
date keys to the changelog entries; `725c5e3` teaches `splash/src/loaders/frontmatter.ts`
to read them. Taking the docs without the loader means dates render from the
wrong keys. They move together or not at all.

## Options

1. **Triage `hygene/test-coverage` as two separate merges.** Cherry-pick the
   frontmatter sweep + splash loader fix as one coherent docs-and-rendering
   change; treat `feat(workspaces)` as its own decision after reconciling it
   against the `entities` model. Highest clarity, most steps.
2. **Reconcile workspaces against entities first, then merge whatever survives.**
   Answer "does `entities(kind: workspace)` replace `accounts/workspace.ex`?"
   before moving any code. If it does, the branch becomes a docs-only merge and
   the feature is deleted with its invariant migrated into the entities model.
3. **Merge `hygene/test-coverage` wholesale into `main`,** resolving DESIGN.md
   conflicts in favor of `main`. Fastest; ships a possibly-superseded tenancy
   model alongside the new one and defers the real question.
4. **Rename the branches to match their contents** and defer everything else.
   Cheapest possible step; removes the trap without paying down anything.

## Recommendation

**Option 2, then Option 1.** The workspaces-vs-entities question is the one that
gets more expensive with time and blocks the rest — answer it first, on paper,
without moving code. Then the frontmatter sweep and splash loader fix merge as
an easy pair.

Whichever path: **resolve DESIGN.md in favor of `main` on every merge**, and
delete `feature/workspaces` once its one doc commit is confirmed redundant —
after checking with the `ai-labs` parent, which currently points at it.

## Open questions

1. **Does `entities(kind: "workspace")` supersede `accounts/workspace.ex`?**
   The entities model is flat with no `parent_id`; the workspaces model has its
   own membership table and a `default_domain` self-signup hint. They may be the
   same idea built twice.
2. **Does the advisor invariant hold in the entities model?** Membership as an
   explicit grant, with the granted person's address irrelevant. If entities
   already guarantees this, the workspaces code is redundant; if not, entities
   has a gap.
3. **Is the milestone "Maintain Test Coverage for Didi Auth" still the frame**
   for `hygene/test-coverage`, given the branch grew a feature?
4. **Can `feature/workspaces` be deleted outright** once the `ai-labs` parent is
   repointed?

## Related

- `context-v/plans/Entities-and-Keys-Implementation-Plan.md` — the model that may supersede workspaces
- `context-v/issues/Entities-and-Organizations-Both-Exist.md` — the same duplicate-tenancy question, one layer down
- `context-v/explorations/What-Corpora-Builder-Needs-From-didi-sh.md` — names "workspaces aren't a thing here yet" as a consumer gap
- `ai-labs/context-v/plans/Didi-Login-and-Workspace-Config-for-Corpora.md` — Phase B, which `b0b417c` implements
- `204b38a` — the splash interlinking fix both branches predate
