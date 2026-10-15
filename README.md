# deploy-records

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
existing version branch is never moved, so re-running a workflow can't
rewrite a published support line.

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

- **Patches** are numbered per base release: `{{base_tag}}` is the most
  recent release tag (by creation date) and `{{patch}}` is one more than the
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

**Language**: `language: en` or `es`, and any label can be overridden:

```yaml
labels: |
  note=Comments
  changelog=What's new
```

Keys: `field value version tag commit previous_tag note none kind_release
kind_patch kind_testing changelog commits_since commits_all no_changelog
no_commits more`.

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
| `previous-tag-pattern` | derived | Glob for the previous tag |
| `on-existing` | `fail` | `fail`, `skip`, `use`, `overwrite` |
| `title` | `<platform> <kind>` | Notes heading |
| `note` | — | Free text in the details table |
| `details` | — | Extra rows, `Label\|Value` per line |
| `sections` | `details,changelog,commits` | Built-in sections and their order |
| `language` | `en` | `en` or `es` |
| `labels` | — | Label overrides, `key=Text` per line |
| `template-file` | — | Your own Markdown template |
| `changelog-path` | `CHANGELOG.md` | Keep a Changelog file |
| `changelog-section` | `auto` | `auto`, `version`, `unreleased` or a name |
| `commit-format` | `- %s (%h)` | `git log --pretty` format |
| `max-commits` | `150` | Cap on listed commits |
| `include-merges` | `false` | List merge commits |
| `release-name` | `<platform> v<version>` | Release title |
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
| `tag-created` | Whether this run pushed the tag |
| `notes-path` / `notes` | The notes file path / its Markdown |
| `release-url` | The release page (empty if none) |
| `branch` / `branch-created` | The version branch name / whether it was pushed now |

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

Releasing: add the version's section to `CHANGELOG.md`, push a `vX.Y.Z` tag;
`release.yml` publishes the release (with this action) and moves `vX`.

## License

[MIT](LICENSE)
