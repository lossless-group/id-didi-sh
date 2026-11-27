---
site_uuid: 1b0ccc76-5171-4c15-b423-715c4b8cadb3
hex_code: q86j8n
title: "Every Refusal at the Trust Boundary Is Now Tested"
lede: "Coverage went from 68% to 93%, with security paths first, and it is now a gate that fails the precommit if it slips. Kay-OS joins MemoPop as an OAuth resource."
publish: true
date_created: 2026-11-26
date_modified: 2026-11-26
date_authored_initial_draft: 2026-11-26
date_authored_current_draft: 2026-11-26
authors:
  - Michael Staton
augmented_with:
  - Claude Code on Claude Opus 5.5
tags:
  - Test-Coverage
  - OAuth
  - Security
  - Id-Didi-Sh
files_changed:
  - config/config.exs
  - mix.exs
  - lib/id_didi_sh/mailer/resend_adapter.ex
  - test/
  - context-v/plans/Test-Coverage-Push-for-id-didi-sh.md
---

## Why Care?

id.didi.sh is the one service that says no on behalf of every other service.
Most of the ways it says no had never been run in a test: a forged cookie, a
CORS origin that isn't on the list, an authorization code presented by the
wrong client, a refresh token for someone who has left the firm. A refusal
that quietly stops refusing looks exactly like everything working.

The branch named `hygene/test-coverage` never held this work. It held the
workspaces feature (see the branch-resolution issue). This is the coverage
that its name promised.

## What's New?

- **Kay-OS is an OAuth resource.** Claude connectors pointed at
  `https://mcp.kay-os.lol` can get tokens scoped to it, alongside MemoPop.
- **The token endpoint's refusals are pinned.** Expired, replayed, and
  cross-client codes; a `redirect_uri` that changed; a consenting session
  that has ended; expired and cross-client refresh tokens. Removing someone
  from an entity kills their grant family, and adding them back does not
  bring it back to life.
- **Confidential clients work over HTTP Basic,** and a failed Basic login
  gets the `WWW-Authenticate` challenge the RFC asks for.
- **CORS is tested on both sides.** A listed origin gets its own origin echoed
  back with credentials. Any other origin gets no CORS headers at all, and the
  wildcard never appears.
- **The sign-in page shows the same response for known and unknown addresses,**
  checked byte for byte, so it can't be used to find out who has an account.
- **The account page, the API's 403/404/422 responses, the operator `mix id.*`
  tasks, and the Resend adapter** all have tests now. The adapter is tested
  against a stub, never the network.
- **Coverage is a gate.** `mix precommit` now runs `test --cover` with a
  threshold of 92%, set just under the measured 92.87% rather than at an
  aspirational number.

## By the numbers

| | Before | After |
|---|---|---|
| Tests | 137 | 231 |
| Line coverage | 68% | 93% |
| `AccountController` | 0% | 97% |
| `OAuthTokenController`, `Plugs.CORS`, `Keys` | 45–67% | 100% |

## Worth Knowing

- **Ignored rather than tested:** the HEEx template modules, which read 0%
  even when their pages render, plus generator output, supervision wiring, and
  the release entry point. Each one is listed in `mix.exs` with the reason.
- **Raise the threshold when coverage rises.** Lowering it to get a change
  through defeats the point.
- **No CI runs `mix test` yet.** The only workflow builds the splash, so the
  gate holds only where `mix precommit` actually gets run.
