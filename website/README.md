# Photo Export Website

This directory contains the documentation website for Photo Export. It is built with Astro and Starlight and published with the `deploy-website.yml` workflow.

## Local Development

Run all commands from `website/`:

```bash
npm install
npm run dev
```

Use Node 22.12 or newer. The package manifest declares this in `engines`, and CI runs the website with Node 22.

Useful commands:

| Command               | Purpose                                                            |
| :-------------------- | :----------------------------------------------------------------- |
| `npm run dev`         | Start the local dev server                                         |
| `npm run build`       | Build the static site into `dist/`                                 |
| `npm run preview`     | Preview the production build locally                               |
| `npm run check`       | Run `astro check`                                                  |
| `npm run validate`    | Run the same validation used in CI (`astro check` + `astro build`) |
| `npm run test:links`  | Exercise the link checker against disposable preview sites         |
| `npm run check:links` | Check internal pages/assets after `npm run build`                  |

The built-site checker starts an owned Astro preview server on a loopback-only ephemeral port, uses the same repository base path as the build, and stops it on success or failure. Startup and requests have bounded timeouts. External hosts, mail/data links, and fragment validation are excluded so external availability does not gate CI; local page/asset URLs (including CSS references) are checked. Broken links report the referring page. Linkinator is an exact-version development dependency recorded in the lockfile.

## Content Layout

- `src/content/docs/` contains the published documentation pages.
- `src/pages/index.astro` contains the landing page.
- `src/components/` contains the custom website components.
- `astro.config.mjs` defines the site metadata and Starlight sidebar. The Pages `base` path and GitHub repo links are derived by `site-config.mjs` from the `GITHUB_REPOSITORY` environment variable (set automatically by GitHub Actions), so renaming the repository does not require a code change. Local builds use the fallback in that shared module — update it if the repository is renamed.

## Documentation Boundaries

Keep content responsibilities clear:

- Update the root `README.md` for repository-level setup and contributor entry points.
- Update `src/content/docs/` for user-facing product documentation.
- Update `docs/` in the repo root for maintainer notes and planning material.

Avoid copying large chunks of text between the repo root and the website. Link when possible; duplicate only when the user experience requires it.
