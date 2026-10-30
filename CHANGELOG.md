# Changelog

All notable changes to this project are documented in this file, following
the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.2.0] - 2026-10-30

### Added

- `base-version` (`kind: patch`): patch a specific release instead of the
  most recent one. Its release tag must exist, otherwise `prepare` fails
  before the build; empty or `latest` keeps the previous behaviour.
- `branch-update: fast-forward`: move an existing version branch up to the
  deployed commit, so a release's branch follows its patches. It never
  force-pushes: when the deployed commit doesn't descend from the branch, the
  branch is left alone with a warning. Default `never` keeps the previous
  behaviour.
- Outputs `base-tag` and `patch` (the release patched and the patch number)
  and `branch-updated`.

### Changed

- Releases published for a patch are named `<platform> v<version>-patch<n>`
  by default instead of sharing their base release's name.

## [1.1.1] - 2026-10-15

### Changed

- Marketplace-ready metadata: display name "Deploy Records" and a short
  description (usage is unchanged: `uses: detextre4/deploy-records@v1`).
- Releases of this action are created as drafts, to be published from the
  web UI with the GitHub Marketplace option ticked.

## [1.1.0] - 2026-10-15

### Added

- `collapse-after` (default `40`): a changelog section or commit list longer
  than that folds into a collapsible `<details>` block, so a big
  `Unreleased` section no longer floods the summary or release page.

### Fixed

- Tags and version branches no longer fail when GitHub refuses the
  `git push` because `GITHUB_TOKEN` can't push refs that touch
  `.github/workflows/` ("refusing to allow a GitHub App to create or update
  workflow … without `workflows` permission"): the ref is then created
  through the REST API with the `token` input. Push errors now name their
  real cause instead of always pointing at `contents: write`.
- Release bodies over GitHub's 125000-character limit are truncated with a
  notice instead of failing the step with HTTP 422; the tag message and the
  job summary keep the full notes.

## [1.0.0] - 2026-10-15

### Added

- `prepare` / `finalize` / `all` modes, with state kept per `id` so a
  version that was already released fails before the build.
- Version from `pubspec.yaml`, `package.json`, a plain file, a custom regex
  or an explicit input; optional `+build` requirement.
- `release`, `patch` and `testing` kinds with tag templates and
  placeholders; patches numbered per base release; previous tag per channel.
- `on-existing`: `fail`, `skip`, `use`, `overwrite`.
- Notes from configurable sections (details table, Keep a Changelog section,
  commits since the previous tag), English/Spanish labels with per-key
  overrides, or a full Markdown template.
- Records, each optional: job summary, annotated or lightweight tag, GitHub
  Release through the REST API (draft, prerelease, `make_latest`, asset
  upload), version branch.
