# Changelog

All notable changes to this project are documented in this file, following
the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
