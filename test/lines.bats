#!/usr/bin/env bats
load test_helper

# Two Android releases: 1.2.0+1 (older, patched once) and 1.3.0+1 (latest).
two_releases() {
  pubspec 1.2.0+1
  tag Android-v1.2.0+1
  git branch version/android/1.2.0+1
  commit "fix: old line"
  tag Android-v1.2.0+1-patch1
  pubspec 1.3.0+1
  tag Android-v1.3.0+1
}

@test "a patch on a release line patches that release" {
  two_releases
  git checkout -q version/android/1.2.0+1
  commit "fix: cherry-picked"
  dr prepare DR_KIND=patch DR_PLATFORM=Android DR_RELEASE_LINES=true
  assert_success
  assert_equal "$(output tag)" "Android-v1.2.0+1-patch2"
  assert_equal "$(output base-tag)" "Android-v1.2.0+1"
  assert_equal "$(output version)" "1.2.0+1"
  assert_equal "$(output release-line)" "version/android/1.2.0+1"
  assert_equal "$(output recorded)" "true"
}

@test "the line wins over latest and must match an explicit base-version" {
  two_releases
  git checkout -q version/android/1.2.0+1
  dr prepare DR_KIND=patch DR_PLATFORM=Android DR_RELEASE_LINES=true DR_BASE_VERSION=latest
  assert_success
  assert_equal "$(output base-tag)" "Android-v1.2.0+1"
  dr prepare DR_KIND=patch DR_PLATFORM=Android DR_RELEASE_LINES=true DR_BASE_VERSION=1.2.0+1
  assert_success
  dr prepare DR_KIND=patch DR_PLATFORM=Android DR_RELEASE_LINES=true DR_BASE_VERSION=1.3.0+1
  assert_failure
  assert_output --partial "doesn't match the release line version/android/1.2.0+1"
}

@test "GITHUB_REF_NAME decides the line (detached checkouts)" {
  two_releases
  git checkout -q --detach version/android/1.2.0+1
  dr prepare DR_KIND=patch DR_PLATFORM=Android DR_RELEASE_LINES=true GITHUB_REF_NAME=version/android/1.2.0+1
  assert_success
  assert_equal "$(output base-tag)" "Android-v1.2.0+1"
}

@test "kind=release on a release line fails" {
  two_releases
  git checkout -q version/android/1.2.0+1
  dr prepare DR_PLATFORM=Android DR_RELEASE_LINES=true DR_ON_EXISTING=skip
  assert_failure
  assert_output --partial "kind=release on the release line version/android/1.2.0+1"
}

@test "off a line, release-lines only lets a patch target the latest release" {
  two_releases
  commit "fix: trunk"
  dr prepare DR_KIND=patch DR_PLATFORM=Android DR_RELEASE_LINES=true
  assert_success
  assert_equal "$(output base-tag)" "Android-v1.3.0+1"
  assert_equal "$(output release-line)" ""

  dr prepare DR_KIND=patch DR_PLATFORM=Android DR_RELEASE_LINES=true DR_BASE_VERSION=1.2.0+1
  assert_failure
  assert_output --partial "Android-v1.2.0+1 is not the latest release (Android-v1.3.0+1)"
  assert_output --partial "run this workflow on version/android/1.2.0+1"

  # Without release-lines the old behaviour stays: any recorded base.
  dr prepare DR_KIND=patch DR_PLATFORM=Android DR_BASE_VERSION=1.2.0+1
  assert_success
}

@test "release-lines needs a branch-template with {{version}}" {
  pubspec 1.3.0+1
  dr prepare DR_KIND=patch DR_RELEASE_LINES=true 'DR_BRANCH_TEMPLATE=release/{{version_name}}'
  assert_failure
  assert_output --partial "release-lines needs a branch-template"
}

@test "custom branch-template lines" {
  pubspec 2.0.0+1
  tag v2.0.0+1
  git checkout -q -b support/2.0.0+1
  dr prepare DR_KIND=patch DR_RELEASE_LINES=true 'DR_BRANCH_TEMPLATE=support/{{version}}'
  assert_success
  assert_equal "$(output release-line)" "support/2.0.0+1"
  assert_equal "$(output tag)" "v2.0.0+1-patch1"
}

setup_remote() {
  git init -q --bare "$BATS_TEST_TMPDIR/remote.git"
  git remote add origin "$BATS_TEST_TMPDIR/remote.git"
  git push -q origin main
}

@test "record-on: other refs write only the notes" {
  pubspec 1.3.0+1
  setup_remote
  git checkout -q -b feature/x
  dr all DR_PLATFORM=Android DR_BRANCH=true DR_RECORD_ON=deploy/android
  assert_success
  assert_equal "$(output recorded)" "false"
  assert_equal "$(output tag-created)" "false"
  assert_equal "$(output branch-created)" "false"
  run git --git-dir="$BATS_TEST_TMPDIR/remote.git" for-each-ref --format='%(refname)'
  refute_output --partial "refs/tags/"
  refute_output --partial "refs/heads/version/"
  grep -q "Android-v1.3.0+1" "$GITHUB_STEP_SUMMARY"
}

@test "record-on: an existing tag doesn't fail where nothing is recorded" {
  pubspec 1.3.0+1
  tag Android-v1.3.0+1
  git checkout -q -b feature/x
  dr prepare DR_PLATFORM=Android DR_RECORD_ON=deploy/android
  assert_success
  assert_output --partial "already exists — ignored"
  assert_equal "$(output tag-exists)" "true"
}

@test "record-on: matching refs (globs, comma lists) record" {
  pubspec 1.3.0+1
  setup_remote
  git checkout -q -b deploy/android
  dr all DR_PLATFORM=Android DR_BRANCH=true 'DR_RECORD_ON=main, deploy/*'
  assert_success
  assert_equal "$(output recorded)" "true"
  assert_equal "$(output tag-created)" "true"
  assert_equal "$(output branch-created)" "true"
}

@test "record-on: a release line records even when not listed" {
  pubspec 1.2.0+1
  setup_remote
  tag Android-v1.2.0+1
  git push -q origin Android-v1.2.0+1
  git checkout -q -b version/android/1.2.0+1
  git push -q origin version/android/1.2.0+1
  commit "fix: cherry-picked"
  dr all DR_KIND=patch DR_PLATFORM=Android DR_BRANCH=true DR_BRANCH_UPDATE=fast-forward \
    DR_RELEASE_LINES=true DR_RECORD_ON=deploy/android
  assert_success
  assert_equal "$(output recorded)" "true"
  assert_equal "$(output tag)" "Android-v1.2.0+1-patch1"
  assert_equal "$(output branch)" "version/android/1.2.0+1"
  assert_equal "$(output branch-updated)" "true"
  assert_equal "$(git --git-dir="$BATS_TEST_TMPDIR/remote.git" rev-parse refs/heads/version/android/1.2.0+1)" "$(git rev-parse HEAD)"
}
