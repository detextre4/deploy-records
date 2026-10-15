#!/usr/bin/env bats
load test_helper

changelog() {
  cat > CHANGELOG.md <<'MD'
# Changelog

## [Unreleased]

### Added
- Pending thing

## [1.3.0+1] - 2026-10-01

### Fixed
- Released thing

## [1.2.0+1] - 2026-09-01
- old
MD
  git add CHANGELOG.md
  git commit -q -m "docs: changelog"
}

# notes — the rendered notes file of the default id.
notes() {
  cat "$RUNNER_TEMP/deploy-records/default.md"
}

@test "default layout: heading, details, changelog version section, commits" {
  export GITHUB_REPOSITORY=acme/app
  pubspec 1.2.0+1
  tag Android-v1.2.0+1
  changelog
  commit "feat: shiny"
  pubspec 1.3.0+1
  dr all DR_TAG=none DR_PLATFORM=Android 'DR_DETAILS=Flavor|prod
API Version|`v1`' DR_NOTE=hello
  assert_success
  run notes
  assert_line --index 0 '## 🚀 Android Release — `Android-v1.3.0+1`'
  assert_line '| Field | Value |'
  assert_line '| **Version** | `1.3.0+1` |'
  assert_line '| **Tag** | `Android-v1.3.0+1` |'
  assert_line --regexp '^\| \*\*Commit\*\* \| \[`[0-9a-f]{8}`\]\(https://github.com/acme/app/commit/[0-9a-f]{40}\) \|$'
  assert_line '| **Flavor** | prod |'
  assert_line '| **API Version** | `v1` |'
  assert_line '| **Note** | hello |'
  assert_line '### 📋 Release notes (CHANGELOG.md — `[1.3.0+1]`)'
  assert_line '- Released thing'
  refute_line '- Pending thing'
  assert_line '### 🧾 Commits since `Android-v1.2.0+1`'
  assert_line --regexp '^- feat: shiny \([0-9a-f]+\)$'
}

@test "patches use the Unreleased section" {
  pubspec 1.3.0+1
  tag Android-v1.3.0+1
  changelog
  dr all DR_TAG=none DR_KIND=patch DR_PLATFORM=Android
  assert_success
  run notes
  assert_line '### 📋 Release notes (CHANGELOG.md — `[Unreleased]`)'
  assert_line '- Pending thing'
}

@test "auto falls back to Unreleased when the version isn't closed yet" {
  pubspec 1.9.0+1
  changelog
  dr all DR_TAG=none
  assert_success
  run notes
  assert_line '### 📋 Release notes (CHANGELOG.md — `[Unreleased]`)'
}

@test "explicit changelog section and a missing one" {
  pubspec 1.3.0+1
  changelog
  dr all DR_TAG=none 'DR_CHANGELOG_SECTION=1.2.0+1'
  assert_success
  run notes
  assert_line '- old'

  dr all DR_TAG=none DR_ID=b DR_CHANGELOG_SECTION=9.9.9
  assert_success
  assert_output --partial "has no '## [9.9.9]' section"
  run cat "$RUNNER_TEMP/deploy-records/b.md"
  assert_line '_No entries in the changelog._'
}

@test "no changelog file: section skipped" {
  pubspec 1.0.0+1
  dr all DR_TAG=none
  assert_success
  run notes
  refute_output --partial 'Release notes'
}

@test "sections pick and order the blocks" {
  pubspec 1.0.0+1
  changelog
  dr all DR_TAG=none DR_SECTIONS=commits,details
  assert_success
  run notes
  refute_output --partial 'Release notes'
  commits_line=$(grep -n '### 🧾' "$RUNNER_TEMP/deploy-records/default.md" | cut -d: -f1)
  details_line=$(grep -n '| Field | Value |' "$RUNNER_TEMP/deploy-records/default.md" | cut -d: -f1)
  [ "$commits_line" -lt "$details_line" ]

  dr all DR_TAG=none DR_SECTIONS=details,bogus
  assert_failure
  assert_output --partial "Unknown section 'bogus'"
}

@test "spanish labels and overrides" {
  pubspec 1.0.0+1
  dr all DR_TAG=none DR_LANGUAGE=es DR_KIND=testing DR_PLATFORM=Web 'DR_LABELS=note=Comentario
field = Campo'
  assert_success
  run notes
  assert_line --index 0 '## 🚀 Web Testing — `testing-Web-v1.0.0+1-run42`'
  assert_line '| Campo | Detalle |'
  assert_line '| **Versión** | `1.0.0+1` |'
  assert_line '| **Comentario** | N/A |'
  assert_line '### 🧾 Commits (historial completo, sin tag previo)'
}

@test "unknown label key fails" {
  pubspec 1.0.0+1
  dr all DR_TAG=none 'DR_LABELS=nope=x'
  assert_failure
  assert_output --partial "Unknown label key 'nope'"
}

@test "table cells escape pipes and newlines" {
  pubspec 1.0.0+1
  dr all DR_TAG=none 'DR_NOTE=a|b
c'
  assert_success
  run notes
  assert_line '| **Note** | a\|b<br>c |'
}

@test "max-commits caps the list" {
  pubspec 1.0.0+1
  commit "feat: one"
  commit "feat: two"
  commit "feat: three"
  dr all DR_TAG=none DR_MAX_COMMITS=2
  assert_success
  run notes
  assert_line --regexp '^- feat: three'
  refute_line --regexp '^- feat: one'
  assert_line '- … +2 more'
}

@test "custom commit format and merges" {
  pubspec 1.0.0+1
  git checkout -q -b topic
  commit "feat: on topic"
  git checkout -q main
  git merge -q --no-ff topic -m "Merge topic"
  dr all DR_TAG=none 'DR_COMMIT_FORMAT=* %s'
  assert_success
  run notes
  assert_line '* feat: on topic'
  refute_line '* Merge topic'
  dr all DR_TAG=none DR_ID=m DR_INCLUDE_MERGES=true 'DR_COMMIT_FORMAT=* %s'
  run cat "$RUNNER_TEMP/deploy-records/m.md"
  assert_line '* Merge topic'
}

@test "template-file replaces the layout" {
  pubspec 2.1.0+4
  changelog
  printf '# {{platform}} {{version_name}} (build {{build_number}})\n{{changelog_section}}: {{commit_count}} commits\n{{nope}}\n' > notes.tpl
  dr all DR_TAG=none DR_PLATFORM=iOS DR_TEMPLATE_FILE=notes.tpl
  assert_success
  assert_output --partial "unknown placeholder {{nope}}"
  run notes
  assert_line --index 0 '# iOS 2.1.0 (build 4)'
  assert_line --index 1 'Unreleased: 2 commits'
}

@test "summary on and off, custom notes-file, outputs" {
  pubspec 1.0.0+1
  dr all DR_TAG=none DR_NOTES_FILE=out/notes.md
  assert_success
  [ -f out/notes.md ]
  assert_equal "$(output notes-path)" "out/notes.md"
  grep -q '^notes<<DR_EOF_' "$GITHUB_OUTPUT"
  grep -q '## 🚀 Release — `v1.0.0+1`' "$GITHUB_STEP_SUMMARY"

  : > "$GITHUB_STEP_SUMMARY"
  dr all DR_TAG=none DR_ID=quiet DR_SUMMARY=false
  assert_success
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "finalize reuses prepare's resolution; without it, fails" {
  pubspec 1.0.0+1
  dr finalize DR_TAG=none DR_ID=lonely
  assert_failure
  assert_output --partial "found no prepare state for id 'lonely'"

  dr prepare DR_PLATFORM=Android DR_ID=a
  assert_success
  pubspec 7.7.7+7 # changing the file after prepare must not matter
  dr finalize DR_TAG=none DR_PLATFORM=Android DR_ID=a
  assert_success
  assert_equal "$(output tag)" "Android-v1.0.0+1"
}

@test "custom title" {
  pubspec 1.0.0+1
  dr all DR_TAG=none 'DR_TITLE=Web Production'
  assert_success
  run notes
  assert_line --index 0 '## 🚀 Web Production — `v1.0.0+1`'
}
