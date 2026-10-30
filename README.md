# Deploy Records

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Deploy%20Records-blue?logo=github)](https://github.com/marketplace/actions/deploy-records)
[![CI](https://github.com/detextre4/deploy-records/actions/workflows/ci.yml/badge.svg)](https://github.com/detextre4/deploy-records/actions/workflows/ci.yml)

A composite GitHub Action that **records a deploy**: it resolves the version
and tag, renders release notes, and, each one switched on or off on its own,
writes the job summary, pushes a git tag, publishes a GitHub Release and
pushes a version branch.

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
- uses: detextre4/deploy-records@v1
  with:
    platform: Android
    release: 'true'
    files: build/app/outputs/flutter-apk/app-release.apk
```

That run, with `version: 1.3.0+1` in `pubspec.yaml`, pushes an annotated tag
`Android-v1.3.0+1` and publishes a release whose body is:

```markdown
## 🚀 Android Release — `Android-v1.3.0+1`

| Field | Value |
| :--- | :--- |
| **Version** | `1.3.0+1` |
| **Tag** | `Android-v1.3.0+1` |
| **Commit** | [`9f3c2a1b`](https://github.com/acme/app/commit/9f3c…) |
| **Note** | N/A |

### 📋 Release notes (CHANGELOG.md — `[1.3.0+1]`)

### Fixed
- …

### 🧾 Commits since `Android-v1.2.0+4`

- fix: … (a1b2c3d)
```

The same body goes to the job summary and the tag message.

- **Pure bash + git + curl + perl**l, runs on Ubuntu, macOS (bash 3.2) and
  Windows (Git Bash) runners, hosted or self-hosted. No Node, no Docker, no
  other action.
- **Every input is passed through environment variables**, never
  interpolated into shell code, a note with quotes or `$(...)` is just text.

## Contents

- [Records](#records)
- [Modes: one step or prepare + finalize](#modes-one-step-or-prepare--finalize)
- [Kinds and tag templates](#kinds-and-tag-templates)
- [Patching a specific release](#patching-a-specific-release)
- [Release lines](#release-lines) · [Recording only on some refs](#recording-only-on-some-refs)
- [Version](#version)
- [Notes](#notes)
- [When the tag already exists](#when-the-tag-already-exists)
- [Inputs](#inputs) · [Outputs](#outputs) · [Placeholders](#placeholders)
- [Requirements and limits](#requirements-and-limits)
- [Examples](#examples)

## Records

| Record | Input | Default |
|---|---|---|
| Job summary | `summary` | `true` |
| Git tag (annotated carries the notes as message) | `tag`: `none` / `annotated` / `lightweight` | `annotated` |
| GitHub Release (+ attached files) | `release`, `files` | `false` |
| Version branch at the deployed commit | `branch`, `branch-template` | `false` |
| Notes file for later steps (Slack, store notes…) | `notes-file` | temp file, see `notes-path` output |

Only the summary and a tag happen by default. A release needs a tag. An
existing version branch is never moved by default, so re-running a workflow
can't rewrite a published support line; `branch-update: fast-forward` lets it
move forward only (see [Patching a specific release](#patching-a-specific-release)).

## Modes: one step or prepare + finalize

```yaml
# One step at the end of the job:
- uses: detextre4/deploy-records@v1        # mode: all (default)

# Or split, so a version that was already released fails BEFORE a 20-minute build:
- uses: detextre4/deploy-records@v1
  with: { mode: prepare, platform: iOS }
# ... build, sign, upload ...
- uses: detextre4/deploy-records@v1
  with: { mode: finalize, platform: iOS, release: 'true', files: build/ios/ipa/*.ipa }
```

`finalize` reuses exactly what `prepare` resolved (version, tag, previous tag)
even if files changed in between. Several pairs in one job are kept apart with
`id`. Pass the same `platform`/template inputs to both steps.

## Kinds and tag templates

| `kind` | Default tag | Commits listed since |
|---|---|---|
| `release` | `{{platform}}-v{{version}}` → `Android-v1.3.0+1` | last `Android-v*` tag (release or patch) |
| `patch` | `{{base_tag}}-patch{{patch}}` → `Android-v1.3.0+1-patch2` | same |
| `testing` | `testing-{{platform}}-v{{version}}-run{{run}}` | last `testing-Android-v*` tag |

Without `platform`, the defaults drop it: `v1.3.0+1`,
`testing-v1.3.0+1-run42`.

- **Patches** are numbered per base release: `{{base_tag}}` is the release
  named by `base-version` or, when that is empty/`latest`, the most recent
  release tag (by creation date), and `{{patch}}` is one more than the
  patches it already has. The patch is labelled with the base release's
  version, not the current file's: after bumping `pubspec.yaml` to `1.4.0+1`
  for the next release, a Shorebird-style patch of `1.3.0+1` still gets
  `Android-v1.3.0+1-patch3`.
- **Testing** tags carry `{{run}}` because the same version is usually built
  many times.
- **Custom schemes**: `tag-template-release`, `tag-template-patch`,
  `tag-template-testing` accept any [placeholder](#placeholders), e.g.
  `web/{{version_name}}/b{{build_number}}`. An unknown placeholder fails the
  step. `previous-tag-pattern` overrides the glob used to find the previous
  tag.

## Patching a specific release

Over-the-air patches (Shorebird, CodePush…) target one store release while
newer ones may already be out. Point the patch at its release so the record
matches what was actually patched:

```yaml
- id: records
  uses: detextre4/deploy-records@v1
  with:
    mode: prepare
    platform: Android
    kind: patch
    base-version: ${{ inputs.release_version }}   # e.g. 1.2.0+7; empty/"latest" = most recent
# The resolved base is the single source of truth for the patch tool too:
- run: shorebird patch android --release-version=${{ steps.records.outputs.version }}
- uses: detextre4/deploy-records@v1
  with:
    mode: finalize
    platform: Android
    branch: 'true'
    branch-update: fast-forward
```

- `base-version` must name a release whose tag exists
  (`Android-v1.2.0+7`), otherwise `prepare` fails before the build. It only
  applies to `kind: patch`, and follows `require-build-number`. The release
  tag template must depend only on the version/platform for it to resolve.
- Outputs `base-tag` (`Android-v1.2.0+7`) and `patch` (`3`) tell later steps
  exactly what is being patched.
- `branch-update: fast-forward` moves the release's version branch
  (`version/android/1.2.0+7`) to the patched commit, so the branch always
  holds what is live for that release, and the next patch (which replaces
  this one) starts from it. It only ever moves forward: when the deployed
  commit doesn't descend from the branch, the branch is left alone with a
  warning (the deploy already happened, so the step doesn't fail). To patch an
  older release, branch off its version branch, cherry-pick the fix and
  deploy from there.
- Run `finalize` after the patch was published, so a failed patch leaves no
  tag behind and the numbering stays in step.
- Patch releases are named `<platform> v<version>-patch<n>` by default.

## Release lines

`release-lines: 'true'` turns that workflow into rules the action enforces,
so the caller doesn't script them. Each version branch (`branch-template`,
default `version/<platform>/<version>`) is the support line of its release:

| Run on | `kind: release` | `kind: patch` |
|---|---|---|
| A release line, e.g. `version/android/1.2.0+7` | fails | patches **that** release (`base-version` empty/`latest` or equal to it, anything else fails) |
| Any other ref (your deploy branch) | as usual | only the **latest** release; an older one fails and names the line to run on |

```yaml
- id: records
  uses: detextre4/deploy-records@v1
  with:
    mode: prepare
    platform: Android
    kind: ${{ inputs.action_type == 'release' && 'release' || 'patch' }}
    base-version: ${{ inputs.release_version }}
    release-lines: 'true'
    record-on: deploy/android
# ... build / shorebird patch --release-version=${{ steps.records.outputs.version }} ...
- uses: detextre4/deploy-records@v1
  with:
    mode: finalize
    platform: Android
    release: ${{ inputs.action_type == 'release' }}
    branch: 'true'                 # release: creates the line; patch: moves it forward
    branch-update: fast-forward
```

To patch an older release: create its line if it doesn't exist yet (e.g.
`git push origin 'Android-v1.2.0+7^{commit}:refs/heads/version/android/1.2.0+7'`),
cherry-pick the fix onto it and run the workflow on that branch. Remember a
`workflow_dispatch` runs the workflow file of the branch it is dispatched on,
so the line needs your current workflow too.

The line comes from `GITHUB_REF_NAME` (the checked-out branch outside
Actions); output `release-line` names it, empty off a line. The
`branch-template` may only use `{{version}}` (once), `{{platform}}` and
`{{platform_lower}}`. Set `release-lines` on `prepare` (or `all`):
`finalize` reuses what it decided.

## Recording only on some refs

`record: 'false'` makes a run a trial: only the notes and summary, on any
ref, and nothing that later runs depend on (a patch tried on a staging
channel doesn't use up a patch number, nor moves the version branch):

```yaml
record: ${{ inputs.action_type != 'patch-staging' }}
```

`record-on` lists the refs (globs, comma- or newline-separated) where the
tag, release and branch are written, e.g. `record-on: deploy/android` or
`record-on: main, release/*`. On any other ref only the notes and summary are
produced (handy for dry runs from feature branches) and an existing tag
doesn't fail `prepare`. With `release-lines`, a release line always records.
Output `recorded` says which case applied, for later steps such as
notifications (`if: steps.records.outputs.recorded == 'true'`). Empty (the
default) records everywhere. Set it on `prepare` (or `all`).

## Version

| Source | Inputs |
|---|---|
| `pubspec.yaml` (default) | — |
| `package.json` (top-level `"version"`) | `version-file: package.json` |
| First non-empty line of any file | `version-file: VERSION` |
| Your own regex (first capture group, Perl syntax) | `version-format: regex`, `version-regex: 'appVersion = "([^"]+)"'` |
| Given directly | `version: 1.3.0+1` |

`version-format: auto` infers the format from the file name. Set
`require-build-number: 'true'` to reject versions without a `+build` suffix.

## Notes

**Sections**: `sections: details,changelog,commits` picks and orders them.

- **details**: a table with version, tag and a link to the commit, then one
  row per `details` line (`Label|Value`), then `note`. Pipes and newlines in
  values are escaped so the table never breaks.
- **changelog**: a section of a [Keep a Changelog](https://keepachangelog.com)
  file (`changelog-path`). `changelog-section: auto` takes the version's own
  section (`## [1.3.0+1]`) or falls back to `## [Unreleased]`; patches always
  use `Unreleased`, since they ship what's pending. Also `version`,
  `unreleased` or an exact section name. A missing file skips the section.
- **commits**: `git log` since the previous tag, `commit-format` (any
  `--pretty` format), capped at `max-commits` with a "+N more" line, merges
  excluded unless `include-merges`.

**Long sections fold**: when the changelog section or the commit list has
more than `collapse-after` lines (default `40`), its content goes into a
collapsible `<details>` block ("Show all (N lines)") under a visible heading,
so a big `Unreleased` section doesn't flood the summary or release page.
`collapse-after: 0` never folds.

**Language**: `language: en` or `es`, and any label can be overridden:

```yaml
labels: |
  note=Comments
  changelog=What's new
```

Keys: `field value version tag commit previous_tag note none kind_release
kind_patch kind_testing changelog commits_since commits_all no_changelog
no_commits more show_all` (`show_all` may use `{{lines}}`).

**Full template**: `template-file: .github/release-notes.md` replaces the
built-in layout with your own Markdown and [placeholders](#placeholders),
including whole rendered blocks (`{{details}}`, `{{changelog}}`,
`{{commits}}`) or their raw parts (`{{changelog_body}}`, `{{commit_list}}`).
See [`examples/notes-template.md`](examples/notes-template.md). Unknown
placeholders are left in place with a warning.

## When the tag already exists

`on-existing`:

| Value | Tag | Release / branch | Use it for |
|---|---|---|---|
| `fail` (default) | — fails in `prepare`, before the build | — | Forcing a version bump per release |
| `skip` | left alone | not created (notes and summary still written) | Pushes that don't always bump the version |
| `use` | left alone | created | A tag you pushed by hand; the workflow only publishes |
| `overwrite` | moved to HEAD (force-push) | release updated, same-name assets replaced | Re-publishing on purpose |

## Inputs

| Input | Default | Description |
|---|---|---|
| `mode` | `all` | `prepare`, `finalize` or `all` |
| `kind` | `release` | `release`, `patch` or `testing` |
| `id` | `default` | Separates several prepare/finalize pairs in one job |
| `summary` | `true` | Write the job summary |
| `tag` | `annotated` | `none`, `annotated` or `lightweight` |
| `release` | `false` | Publish a GitHub Release |
| `branch` | `false` | Push a version branch |
| `record` | `true` | `false` = trial run: notes and summary only |
| `record-on` | — | Refs (globs) where tag/release/branch are written; empty = all |
| `release-lines` | `false` | Version branches as release lines (see [Release lines](#release-lines)) |
| `branch-update` | `never` | `never` or `fast-forward` an existing version branch |
| `branch-template` | `version/{{platform_lower}}/{{version}}` | Branch name (`version/{{version}}` without platform) |
| `remote` | `origin` | Remote for the tag and branch |
| `notes-file` | temp file | Where to write the notes |
| `version` | — | Explicit version |
| `version-file` | `pubspec.yaml` | File to read it from |
| `version-format` | `auto` | `auto`, `pubspec`, `package-json`, `plain`, `regex` |
| `version-regex` | — | Regex with one capture group |
| `require-build-number` | `false` | Require `+build` |
| `platform` | — | Free-form label (`{{platform}}`) |
| `tag-template-release` / `-patch` / `-testing` | see [Kinds](#kinds-and-tag-templates) | Tag name templates |
| `base-version` | — | `kind: patch`: release being patched (empty/`latest` = most recent) |
| `previous-tag-pattern` | derived | Glob for the previous tag |
| `on-existing` | `fail` | `fail`, `skip`, `use`, `overwrite` |
| `title` | `<platform> <kind>` | Notes heading |
| `note` | — | Free text in the details table |
| `details` | — | Extra rows, `Label\|Value` per line |
| `sections` | `details,changelog,commits` | Built-in sections and their order |
| `language` | `en` | `en` or `es` |
| `labels` | — | Label overrides, `key=Text` per line |
| `collapse-after` | `40` | Fold longer changelog/commit sections (`0` = never) |
| `template-file` | — | Your own Markdown template |
| `changelog-path` | `CHANGELOG.md` | Keep a Changelog file |
| `changelog-section` | `auto` | `auto`, `version`, `unreleased` or a name |
| `commit-format` | `- %s (%h)` | `git log --pretty` format |
| `max-commits` | `150` | Cap on listed commits |
| `include-merges` | `false` | List merge commits |
| `release-name` | `<platform> v<version>` (`-patch<n>` for patches) | Release title |
| `files` | — | Files to attach, one glob per line |
| `draft` | `false` | Draft release |
| `prerelease` | `false` | Pre-release |
| `make-latest` | `true` | `true`, `false` or `legacy` |
| `token` | `github.token` | Token for the release API |

## Outputs

| Output | Description |
|---|---|
| `version` | Full version, e.g. `1.3.0+1` (a patch's base version) |
| `version-name` | Without `+build`, e.g. `1.3.0` |
| `build-number` | The `+build` part, may be empty |
| `tag` | Resolved tag |
| `previous-tag` | Where the commit list starts (empty = full history) |
| `tag-exists` | Whether the tag existed when `prepare` ran |
| `base-tag` / `patch` | `kind: patch`: the release tag patched / the patch number (empty otherwise) |
| `tag-created` | Whether this run pushed the tag |
| `notes-path` / `notes` | The notes file path / its Markdown |
| `release-url` | The release page (empty if none) |
| `branch` / `branch-created` | The version branch name / whether it was pushed now |
| `branch-updated` | Whether an existing version branch was fast-forwarded now |
| `recorded` | Whether this run writes the tag/release/branch (`record`, `record-on`, release line) |
| `release-line` | The release line this run is on (empty if none) |

## Placeholders

Tag and branch templates: `{{platform}}`, `{{platform_lower}}`,
`{{version}}`, `{{version_name}}`, `{{build_number}}`, `{{run}}`,
`{{run_attempt}}`, `{{sha}}`, `{{short_sha}}`, `{{date}}` (UTC,
`YYYY-MM-DD`); patch templates add `{{base_tag}}` and `{{patch}}`; branch
templates add `{{tag}}`.

Notes templates: `{{title}}`, `{{kind}}`, `{{kind_label}}`, `{{platform}}`,
`{{version}}`, `{{version_name}}`, `{{build_number}}`, `{{tag}}`,
`{{previous_tag}}`, `{{sha}}`, `{{short_sha}}`, `{{commit_link}}`, `{{note}}`,
`{{details}}`, `{{changelog}}`, `{{changelog_body}}`, `{{changelog_section}}`,
`{{commits}}`, `{{commit_list}}`, `{{commit_count}}`, `{{run}}`, `{{run_url}}`,
`{{repository}}`, `{{date}}`.

## Requirements and limits

- **`fetch-depth: 0`** on `actions/checkout`. A shallow clone has no earlier
  tags, so the previous tag, patch numbering and the existing-tag check would
  be wrong, the action warns when it detects one.
- **`permissions: contents: write`** in the calling workflow for tags,
  branches and releases. An action can't grant itself permissions; a summary-
  only run (`tag: none`) needs none.
- **GitHub refuses `git push` from `GITHUB_TOKEN` for refs it sees as
  touching `.github/workflows/`** ("…without `workflows` permission"). When
  that happens the tag/branch is created through the REST API instead, with
  `token`. If your setup still blocks it, pass a PAT or GitHub App token with
  the `workflow` scope as `token`.
- **Annotated tags need a git identity.** If the job has none configured,
  `github-actions[bot]` is used.
- **Releases use the REST API with curl** (`GITHUB_API_URL` is honoured, so
  GitHub Enterprise Server works). `token` must be allowed to write contents.
  Release bodies are capped at GitHub's 125000 characters (truncated with a
  notice); the tag message and the summary always carry the full notes.
- **`files` globs** are expanded by bash: one pattern per line; patterns
  matching nothing only warn.
- **The notes reflect HEAD** at `finalize` time. run it on the commit you
  built.

## Examples

- [`flutter-mobile-release.yml`](examples/flutter-mobile-release.yml):
  Shorebird release/patch, APK attached, version branch.
- [`testing-build.yml`](examples/testing-build.yml): per-run testing tags,
  Spanish notes.
- [`web-deploy.yml`](examples/web-deploy.yml): deployment URL in the notes.
- [`node-api.yml`](examples/node-api.yml): `package.json`, release on push.
- [`minimal.yml`](examples/minimal.yml): summary only, nothing pushed.

## Development

```sh
npm ci            # bats, bats-assert, bats-support (pinned)
npm test          # the suite: throwaway git repos, a local bare remote, a fake curl
pip install shellcheck-py==0.11.0.1 actionlint-py==1.7.12.25
shellcheck -x -s bash src/main.sh src/lib/*.sh src/i18n/*.sh
actionlint
```

Releasing:

1. Close the version's section in `CHANGELOG.md` and push it to `main`.
2. Push a `vX.Y.Z` tag. `release.yml` drafts the GitHub Release with this
   action (notes from that `CHANGELOG.md` section) and moves `vX`.
3. Open the draft under Releases, tick **Publish this Action to the GitHub
   Marketplace** and publish it — GitHub only lists releases published that
   way, from the web UI.

## License

[MIT](LICENSE)
