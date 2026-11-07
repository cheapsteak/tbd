# Publishing the phone loader

The phone loader is the small web page under `phone/loader/` that a phone opens to reach TBD. This repo holds its source, and a separate GitHub org serves it with GitHub Pages. This guide is for the maintainer who sets that up: for this project, or for a fork that publishes its own loader. The example org is `acme-loader`; use your own.

The design is in [`docs/specs/2026-11-07-phone-control-design.md`](specs/2026-11-07-phone-control-design.md), sections 15 and 17.

## Why a separate org and repo

- **The loader holds the phone's keys.** It keeps them in the browser's storage for its own origin, and any page on that origin can read them.
- **Every Pages site on one account shares one origin.** A project site on an account is served under `https://<account>.github.io/`, the same origin as every other Pages site of that account. Serving the loader from the maintainer's own account would hand its keys to every other Pages site there (spec, "Rejected alternatives").
- **So the loader gets an org of its own,** whose only Pages site is the loader.

## How a deploy flows

- **A merge to `main` that touches `phone/loader/`** runs [`.github/workflows/phone-loader-deploy.yml`](../.github/workflows/phone-loader-deploy.yml) in this repo.
- **Its `verify` job** installs the loader's dependencies with `npm ci`, then runs `npm run typecheck` and `npm test`.
- **Its `dispatch` job** runs only after `verify` passed, only while `PHONE_LOADER_DEPLOY_ENABLED` is `true`, and only from `main`. It mints a short-lived token from the GitHub App and dispatches the loader repo's `deploy.yml` with the commit ID.
- **The loader repo's `deploy.yml`** checks out that commit from this public repo and publishes `phone/loader/` exactly as committed, but only if the commit is on `main` and its `phone/loader` tree is still the newest one on `main`.
- **What a leaked token can do.** It can start a deploy, but it cannot change what is served: the loader repo publishes only what this repo holds on `main`. A re-run, or an out-of-order dispatch of an older commit, exits without deploying. The token's one permission, Actions: write, also lets it cancel, re-run or disable the loader repo's workflow runs; none of those changes the served files.
- **What guards the loader, then,** is what guards `main` here: branch protection, and code-owner review of `phone/loader/` and of the deploy workflow.

## One-time setup, in order

1. **Create the org and its Pages repo.** Create the org (for example `acme-loader`) and a repo in it named `acme-loader.github.io`, so the loader is served at `https://acme-loader.github.io/`. In the repo's Pages settings, set the source to GitHub Actions.
2. **Add the loader repo's workflow.** Add [the workflow below](#the-loader-repos-workflow) to that repo as `.github/workflows/deploy.yml`. Add the repository variable `TBD_SOURCE_REPO`: for the main project, `cheapsteak/tbd`; a fork names itself.
3. **Create the GitHub App.** Create a GitHub App owned by the org, with no webhook and one repository permission, Actions: Read and write. Install it only on the loader repo. Generate a private key, and note the App ID from the App's settings page.
4. **Configure this repo.**
   - Create the environment `phone-loader`, with its deployment branches limited to `main` (Settings, Environments, Deployment branches and tags, Selected branches and tags).
   - Add the App's private key as the environment secret `PHONE_LOADER_APP_PRIVATE_KEY`: `gh secret set PHONE_LOADER_APP_PRIVATE_KEY --env phone-loader < acme-loader-app.private-key.pem`.
   - Add the repository variables `PHONE_LOADER_APP_ID` (the App ID), `PHONE_LOADER_OWNER` (`acme-loader`) and `PHONE_LOADER_REPO` (`acme-loader.github.io`), each with `gh variable set <name> --body <value>`.
5. **Turn deploys on and check one.** Once `phone/loader/` is on `main`, set `PHONE_LOADER_DEPLOY_ENABLED` to `true` (`gh variable set PHONE_LOADER_DEPLOY_ENABLED --body true`), run `gh workflow run phone-loader-deploy.yml --ref main`, and check that `https://acme-loader.github.io/version.json` shows the commit.
6. **Record the loader URL** in `Config.phoneLoaderURLDefault` (spec, section 11).

## Turning deploys off

Unset `PHONE_LOADER_DEPLOY_ENABLED` (`gh variable delete PHONE_LOADER_DEPLOY_ENABLED`). Any value other than exactly `true` also turns deploys off. The workflow still runs on a loader change and tests it, then stops before the dispatch. The loader keeps serving whatever it last published.

## The loader repo's workflow

`.github/workflows/deploy.yml` in the loader repo, in full:

```yaml
name: Deploy the loader

on:
  workflow_dispatch:
    inputs:
      commit:
        description: The TBD commit whose phone/loader/ folder to publish
        required: true
        type: string

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - name: Require a full commit ID
        env:
          COMMIT: ${{ inputs.commit }}
        run: |
          case "$COMMIT" in
            ''|*[!0-9a-f]*) echo "::error::commit must be a 40-character commit ID"; exit 1 ;;
          esac
          if [ "${#COMMIT}" -ne 40 ]; then echo "::error::commit must be a 40-character commit ID"; exit 1; fi
      - uses: actions/checkout@v4
        with:
          repository: ${{ vars.TBD_SOURCE_REPO }}
          ref: ${{ inputs.commit }}
          fetch-depth: 0
          persist-credentials: false
          path: source
      - name: Require the commit to be on main and its loader to be the newest
        id: current
        working-directory: source
        env:
          COMMIT: ${{ inputs.commit }}
        run: |
          set -euo pipefail
          git fetch --quiet origin main
          if ! git merge-base --is-ancestor "$COMMIT" origin/main; then
            echo "::error::$COMMIT is not on main; only commits on main are published"
            exit 1
          fi
          want="$(git rev-parse "$COMMIT:phone/loader")"
          have="$(git rev-parse origin/main:phone/loader)"
          if [ "$want" != "$have" ]; then
            echo "A newer loader is on main, and its own deploy publishes it."
            echo "deploy=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          echo "deploy=true" >> "$GITHUB_OUTPUT"
          echo "tree=$want" >> "$GITHUB_OUTPUT"
      - name: Stage the loader exactly as committed
        if: steps.current.outputs.deploy == 'true'
        env:
          COMMIT: ${{ inputs.commit }}
          TREE: ${{ steps.current.outputs.tree }}
        run: |
          set -euo pipefail
          mkdir site
          git -C source archive --format=tar "$COMMIT" phone/loader | tar -x -C site --strip-components=2
          find site -name '*.test.js' -delete
          printf '{"commit":"%s","tree":"%s"}\n' "$COMMIT" "$TREE" > site/version.json
      - if: steps.current.outputs.deploy == 'true'
        uses: actions/configure-pages@v6
      - if: steps.current.outputs.deploy == 'true'
        uses: actions/upload-pages-artifact@v5
        with:
          path: site
      - if: steps.current.outputs.deploy == 'true'
        id: deployment
        uses: actions/deploy-pages@v5
```

What each step guards:

- **A full commit ID.** Only 40 lowercase hex characters pass, so a branch name, a tag or a short ID cannot pick out something other than one exact commit.
- **A read-only checkout of the source.** It checks out the commit from `TBD_SOURCE_REPO`, with full history and without keeping the token in the git config.
- **On `main`, and the newest loader.** The commit must be an ancestor of `main`, the same check this repo's [`release.yml`](../.github/workflows/release.yml) makes before it publishes a build. Its `phone/loader` tree must also equal `main`'s. If it does not, a newer loader is on `main` and its own deploy publishes it, so this run ends green without deploying. A re-run or a late dispatch of an older commit therefore publishes nothing.
- **Exactly as committed.** The site is staged with `git archive` from the commit itself, never from a working tree. Test files beside the loader's sources (`*.test.js`) are left out, and `version.json` records the commit and the tree that were published.
- **Publishing.** GitHub's Pages actions publish the staged folder. `deploy-pages` needs `pages: write`, `id-token: write` and the `github-pages` environment ([deploy-pages](https://github.com/actions/deploy-pages)). `configure-pages@v6`, `upload-pages-artifact@v5` and `deploy-pages@v5` were the newest majors of those actions when this guide was written.
