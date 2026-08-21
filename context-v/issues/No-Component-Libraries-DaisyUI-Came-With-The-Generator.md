---
title: "no component libraries — daisyUI came with the generator"
lede: "335KB of vendored daisyUI arrived with mix phx.new on 2026-07-06 and was never a choice. It is load-bearing in exactly one file. The standing rule: don't add more, and replace rather than extend when that file gets touched."
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
  - Dependencies
  - Design-System
  - Elixir
  - Phoenix
  - Id-Didi-Sh
site_uuid: 2f512680-f7a9-4b51-80f7-92c0b1826abc
hex_code: 2a4qrg
date_authored_initial_draft: 2026-08-21
date_authored_current_draft: 2026-08-21
publish: false
---

# no component libraries — daisyUI came with the generator

## The rule

**No component libraries.** Not daisyUI, not Flowbite, not shadcn, not Bootstrap.
The tree already prohibits unnecessary dependencies (see the `astro-knots`
skill's hard prohibitions); this states the same rule for the Elixir side, where
a generator can smuggle one in without anybody deciding.

We have a design system. It is written down in `splash/DESIGN.md`, its runtime
source of truth is `theme.css`, and it exists precisely so the surfaces look
like *this* product rather than like a framework's default. A component library
is a second design system with different opinions, and importing one means
either fighting it or inheriting its look.

## Where this one came from

Not a decision. `3e9f90e` — *"feat(walking-skeleton): magic link → EdDSA
didi_session cookie → /api/me, proven live"*, 2026-07-06 — is the commit that
brought the whole Phoenix scaffold, and Phoenix 1.8's `mix phx.new` ships
Tailwind 4 **plus daisyUI** by default. It came vendored:

```
assets/vendor/daisyui.js         288,156 bytes
assets/vendor/daisyui-theme.js    46,889 bytes
                                 ───────
                                 335,045 bytes
```

Nobody evaluated it. It rode in with the walking skeleton and stayed because
nothing needed styling until the credential UI did.

## What it is actually doing

Concentrated, not diffuse. The real usage is in **`core_components.ex`** — the
generator's form and table components lean on `input`, `select`, `label`,
`fieldset`, `checkbox`, `textarea`, `table`. Outside that file it is a thin
scatter: `btn`, `card`, `join`, `alert`, `link`, `toast`, in `keys_live.ex`,
the `/access` templates, and the root page.

`hero-*` classes are **not** daisyUI — that is the separate heroicons Tailwind
plugin, and it is fine.

## Why it isn't on fire

The theme port (`07ade98`) already maps the credential palette **onto** daisyUI's
token slots rather than sitting beside them. Every daisyUI component now renders
in verdigris, copper and vault-black across all three modes. So the visible
symptom — the app looking like a framework demo — is gone, and what remains is
335KB of vendored CSS-generation we don't need and a set of class names that
aren't ours.

With two users, ripping it out today buys nothing a reader would notice.

## Options

1. **Standing rule, opportunistic removal.** Add no further component
   libraries; when `core_components.ex` is next touched, replace daisyUI
   classes with the posture utilities in `theme.css` rather than extending
   them. daisyUI leaves when its last caller does.
2. **Rip it out now.** Rewrite `core_components.ex` against `theme.css`, delete
   both vendored files and the `@plugin` blocks. One focused session; touches
   every form in the app.
3. **Keep it deliberately.** Decide the form/table components are worth 335KB,
   document that, and stop treating it as debt.

## Recommendation

**Option 1.** The rule is the valuable part; the removal is bookkeeping that can
ride along with work already happening in those files. Increment 5 of
`[[Bring-The-Spike-Under-The-Credential-Design-System]]` — dressing
`keys_live.ex`, `/access`, `layouts.ex` and `core_components.ex` — is exactly
the session where this happens naturally.

What must **not** happen is a third design system arriving the same way this one
did. If a generator, template, or tutorial brings a component library, strip it
in the same commit that brings it.

## Related

- `splash/DESIGN.md` — the design system that already exists
- `assets/css/theme.css` — the posture utilities that replace component-library classes
- `[[Bring-The-Spike-Under-The-Credential-Design-System]]` — increment 5 is where removal rides along
- `astro-knots` skill — the tree-wide hard prohibitions this extends to Elixir
