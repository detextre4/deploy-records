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

# patch_changelog — Unreleased plus a section for patch 2 of 1.3.0+1.
patch_changelog() {
  cat > CHANGELOG.md <<'MD'
# Changelog

## [Unreleased]
- Pending thing

## [1.3.0+1-patch.2]
- Patch two thing

## [1.3.0+1-parche.2]
- Parche dos

## [1.3.0+1-patch.3]

## [1.3.0+1] - 2026-10-01
- Released thing
MD
  git add CHANGELOG.md
  git commit -q -m "docs: changelog"
}

@test "patch id from the pubspec picks its own section" {
  printf 'name: app\nversion: 1.3.0+1\napp_patch: 2   # next patch\n' > pubspec.yaml
  git add pubspec.yaml && commit "chore: patch id"
  tag Android-v1.3.0+1
  patch_changelog
  dr all DR_TAG=none DR_KIND=patch DR_PLATFORM=Android
  assert_success
  run notes
  assert_line '### 📋 Release notes (CHANGELOG.md — `[1.3.0+1-patch.2]`)'
  assert_line '- Patch two thing'
  refute_line '- Pending thing'
}

@test "patch id from package.json, custom key and section template" {
  printf '{\n  "name": "app",\n  "version": "1.3.0+1",\n  "otaPatch": "2"\n}\n' > package.json
  git add package.json && commit "chore: patch id"
  tag v1.3.0+1
  patch_changelog
  dr all DR_TAG=none DR_KIND=patch DR_VERSION_FILE=package.json DR_PATCH_ID_KEY=otaPatch \
    'DR_PATCH_SECTION_TEMPLATE={{version}}-parche.{{patch_id}}'
  assert_success
  run notes
  assert_line '### 📋 Release notes (CHANGELOG.md — `[1.3.0+1-parche.2]`)'
  assert_line '- Parche dos'
}

@test "explicit patch-id wins; an empty patch section falls back to Unreleased" {
  printf 'name: app\nversion: 1.3.0+1\napp_patch: 2\n' > pubspec.yaml
  git add pubspec.yaml && commit "chore: patch id"
  tag Android-v1.3.0+1
  patch_changelog
  dr all DR_TAG=none DR_KIND=patch DR_PLATFORM=Android DR_PATCH_ID=3 DR_PATCH_SECTIONS=single
  assert_success
  assert_output --partial "No entries under '## [1.3.0+1-patch.3]'"
  run notes
  assert_line '### 📋 Release notes (CHANGELOG.md — `[Unreleased]`)'
  assert_line '- Pending thing'
}

# accumulate_setup <app_patch> — release 1.3.0+1 (Android) with patch sections
# 3 (shipped), 4 and 5 in the changelog.
accumulate_setup() {
  printf 'name: app\nversion: 1.3.0+1\napp_patch: %s\n' "$1" > pubspec.yaml
  cat > CHANGELOG.md <<'MD'
# Changelog

## [Unreleased]
- Pending thing

## [1.3.0+1-patch.5]
- Fix five

## [1.3.0+1-patch.4]
- Fix four

## [1.3.0+1-patch.3] - 2026-11-01
- Fix three

## [1.3.0+1] - 2026-10-01
- Released thing
MD
  git add pubspec.yaml CHANGELOG.md && commit "chore: patches"
  tag Android-v1.3.0+1
}

# patch_tag <name> [patch id] — annotated patch tag, with the marker a
# previous run would have written when an id is given.
patch_tag() {
  if [ -n "${2:-}" ]; then
    git tag -a "$1" -m "$(printf 'notes\n\n<!-- deploy-records:patch-id=%s -->' "$2")"
  else
    git tag -a "$1" -m notes
  fi
  sleep 1
}

@test "a platform that skipped a patch gets every section since its last one" {
  accumulate_setup 5
  patch_tag Android-v1.3.0+1-patch1 3
  dr all DR_TAG=none DR_KIND=patch DR_PLATFORM=Android
  assert_success
  run notes
  assert_line '### 📋 Release notes (CHANGELOG.md — `[1.3.0+1-patch.4], [1.3.0+1-patch.5]`)'
  assert_line '#### 1.3.0+1-patch.4'
  assert_line '- Fix four'
  assert_line '#### 1.3.0+1-patch.5'
  assert_line '- Fix five'
  refute_line '- Fix three'
  refute_line '- Pending thing'
  assert_line '<!-- deploy-records:patch-id=5 -->'
}

@test "a platform up to date gets only the new section, unchanged layout" {
  accumulate_setup 5
  patch_tag Android-v1.3.0+1-patch1 4
  dr all DR_TAG=none DR_KIND=patch DR_PLATFORM=Android
  assert_success
  run notes
  assert_line '### 📋 Release notes (CHANGELOG.md — `[1.3.0+1-patch.5]`)'
  refute_line '#### 1.3.0+1-patch.5'
  refute_line '- Fix four'
}

@test "first patch of a platform on a release gets every patch section" {
  accumulate_setup 5
  dr all DR_TAG=none DR_KIND=patch DR_PLATFORM=Android
  assert_success
  run notes
  assert_line '### 📋 Release notes (CHANGELOG.md — `[1.3.0+1-patch.3], [1.3.0+1-patch.4], [1.3.0+1-patch.5]`)'
  assert_line '- Fix three'
}

@test "previous patch without a recorded id, single, and an id going backwards" {
  accumulate_setup 5
  patch_tag Android-v1.3.0+1-patch1
  dr all DR_TAG=none DR_KIND=patch DR_PLATFORM=Android
  assert_success
  assert_output --partial 'has no recorded patch id'
  run notes
  assert_line '### 📋 Release notes (CHANGELOG.md — `[1.3.0+1-patch.5]`)'

  patch_tag Android-v1.3.0+1-patch2 3
  dr all DR_TAG=none DR_ID=s DR_KIND=patch DR_PLATFORM=Android DR_PATCH_SECTIONS=single
  assert_success
  run cat "$RUNNER_TEMP/deploy-records/s.md"
  assert_line '### 📋 Release notes (CHANGELOG.md — `[1.3.0+1-patch.5]`)'

  patch_tag Android-v1.3.0+1-patch3 9
  dr all DR_TAG=none DR_ID=b DR_KIND=patch DR_PLATFORM=Android
  assert_success
  assert_output --partial 'lower than the previous patch'
  run cat "$RUNNER_TEMP/deploy-records/b.md"
  assert_line '### 📋 Release notes (CHANGELOG.md — `[1.3.0+1-patch.5]`)'
}

@test "another platform's patches don't count" {
  accumulate_setup 5
  tag iOS-v1.3.0+1
  patch_tag iOS-v1.3.0+1-patch1 4
  patch_tag Android-v1.3.0+1-patch1 3
  dr all DR_TAG=none DR_KIND=patch DR_PLATFORM=Android
  assert_success
  run notes
  assert_line '### 📋 Release notes (CHANGELOG.md — `[1.3.0+1-patch.4], [1.3.0+1-patch.5]`)'
}

@test "the recorded id survives into the pushed tag" {
  accumulate_setup 4
  git init -q --bare "$BATS_TEST_TMPDIR/remote.git"
  git remote add origin "$BATS_TEST_TMPDIR/remote.git"
  dr all DR_KIND=patch DR_PLATFORM=Android
  assert_success
  run git tag -l --format='%(contents)' Android-v1.3.0+1-patch1
  assert_line '<!-- deploy-records:patch-id=4 -->'
}

@test "a release ignores the patch id" {
  printf 'name: app\nversion: 1.3.0+1\napp_patch: 2\n' > pubspec.yaml
  git add pubspec.yaml && commit "chore: patch id"
  patch_changelog
  dr all DR_TAG=none
  assert_success
  run notes
  assert_line '### 📋 Release notes (CHANGELOG.md — `[1.3.0+1]`)'
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

@test "the README's example template renders every placeholder" {
  export GITHUB_REPOSITORY=acme/app GITHUB_RUN_ID=123
  pubspec 1.0.0+1
  tag Android-v1.0.0+1
  changelog
  pubspec 1.1.0+2
  dr all DR_TAG=none DR_PLATFORM=Android DR_TEMPLATE_FILE="$DR_ROOT/examples/notes-template.md" DR_NOTE=hi
  assert_success
  refute_output --partial "unknown placeholder"
  run notes
  assert_line --index 0 '# Android Release 1.1.0 (build 2)'
  assert_line '<summary>2 commits since Android-v1.0.0+1</summary>'
  refute_output --partial '{{'
}

@test "long sections fold into <details>, short ones don't" {
  pubspec 1.0.0+1
  perl -e 'print "# Changelog\n\n## [Unreleased]\n\n"; print "- item $_\n" for 1..60' > CHANGELOG.md
  git add CHANGELOG.md && commit "docs: changelog"
  dr all DR_TAG=none
  assert_success
  run notes
  assert_line '<summary>Show all (60 lines)</summary>'
  assert_line '- item 60'
  # The 2-commit list stays unfolded.
  [ "$(grep -c '<details>' "$RUNNER_TEMP/deploy-records/default.md")" -eq 1 ]

  dr all DR_TAG=none DR_ID=es DR_LANGUAGE=es DR_COLLAPSE_AFTER=1
  run cat "$RUNNER_TEMP/deploy-records/es.md"
  assert_line '<summary>Ver todo (60 líneas)</summary>'
  assert_line '<summary>Ver todo (2 líneas)</summary>'

  dr all DR_TAG=none DR_ID=never DR_COLLAPSE_AFTER=0
  run cat "$RUNNER_TEMP/deploy-records/never.md"
  refute_output --partial '<details>'

  dr all DR_TAG=none DR_ID=bad DR_COLLAPSE_AFTER=lots
  assert_failure
  assert_output --partial "Input 'collapse-after' must be a whole number"
}
