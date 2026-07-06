# didi.sh · landing

The **custom-domain marketing surface** for the didi.sh platform, deployed on
Vercel at the apex (`didi.sh`). Derived from `../splash/` (which stays put as
the repo's GitHub Pages presence, per the `maintain-splash-pages` convention —
the landing is the separate thing the `splash/` name preserved linguistic
space for).

Conversion-focused: hero → specimen ID card → the three services → the
credential datasheet → CTA to `id.didi.sh`. The dev surfaces (changelog,
context-v, search) are deliberately absent here — the landing links back to
the GitHub splash for the build log.

## Wiring it up in Vercel (one-time)

The domain is registered at Vercel, so this is all dashboard clicks:

1. **Import the repo** — Vercel → Add New → Project → import
   `lossless-group/id-didi-sh`.
2. **Root Directory:** `landing` (Framework Preset: Astro — auto-detected).
   Install command: `pnpm install`; build: `pnpm build`; output: `dist`.
3. **Assign the domain** — Project → Settings → Domains → add `didi.sh`
   (+ `www.didi.sh` redirecting to apex). Zero DNS work since Vercel is the
   registrar.
4. Pushes to `main` that touch `landing/` redeploy automatically.

## DNS for the rest of the platform (in Vercel DNS)

| Record | Type | Points at |
|---|---|---|
| `didi.sh`, `www` | (managed) | this landing, via the domain assignment above |
| `id` | CNAME | the Fly.io app (`<app>.fly.dev`) once the identity service deploys |
| `memos`, `decks`, `augment` | CNAME | their hosts, later |

Add records with `vercel dns add didi.sh id CNAME <app>.fly.dev` or the
dashboard.

## Local dev

```sh
cd landing
pnpm install --ignore-workspace
pnpm dev          # http://localhost:4321/
pnpm build        # static output in dist/
```

## Where content lives

| Surface | Source |
|---|---|
| Hero + credential datasheet copy | `src/pages/index.astro` + `src/lib/seo.ts` |
| The three service cards | `src/content/service-highlights/*.md` |
| OG banner | `public/og-banner.png` (1200×630) |
| Theme (credential posture) | `src/styles/theme.css` — same tokens as the splash |

Keep the splash and landing consciously in sync on theme + service copy;
they share the credential posture but serve different jobs (repo presence
vs conversion).
