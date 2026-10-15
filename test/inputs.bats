#!/usr/bin/env bats
load test_helper

@test "rejects an unknown kind" {
  pubspec 1.0.0+1
  dr prepare DR_KIND=hotfix
  assert_failure
  assert_output --partial "Input 'kind' must be one of"
}

@test "release without a tag is rejected" {
  pubspec 1.0.0+1
  dr prepare DR_RELEASE=true DR_TAG=none
  assert_failure
  assert_output --partial "release: true needs a tag"
}

@test "non-boolean summary is rejected" {
  pubspec 1.0.0+1
  dr prepare DR_SUMMARY=maybe
  assert_failure
  assert_output --partial "Input 'summary' must be true or false"
}

@test "outside a git repository fails with a hint" {
  mkdir "$BATS_TEST_TMPDIR/plain"
  cd "$BATS_TEST_TMPDIR/plain"
  # Stop git from discovering a parent repository above the temp dir.
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
  dr prepare DR_VERSION=1.0.0
  assert_failure
  assert_output --partial "Not inside a git repository"
}

@test "template values containing & and / render literally" {
  . "$DR_ROOT/src/lib/common.sh"
  run dr_render 'a {{x}} b' x 'R&D / ops'
  assert_output 'a R&D / ops b'
}
