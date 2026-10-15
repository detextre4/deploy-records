#!/usr/bin/env bats
load test_helper

# A local bare repo as "origin", and the fake curl first on PATH.
setup_remote() {
  git init -q --bare "$BATS_TEST_TMPDIR/remote.git"
  git remote add origin "$BATS_TEST_TMPDIR/remote.git"
  git push -q origin main
}

use_fake_api() {
  export FAKE_DIR="$BATS_TEST_TMPDIR/fake"
  export FAKE_LOG="$FAKE_DIR/requests.log"
  mkdir -p "$FAKE_DIR/bin"
  cp "$DR_ROOT/test/fixtures/fake-curl" "$FAKE_DIR/bin/curl"
  chmod +x "$FAKE_DIR/bin/curl"
  : > "$FAKE_LOG"
  export PATH="$FAKE_DIR/bin:$PATH"
  export GITHUB_REPOSITORY=o/r
  export GH_TOKEN=test-token
}

remote_tag_message() {
  git --git-dir="$BATS_TEST_TMPDIR/remote.git" cat-file -p "refs/tags/$1"
}

json_field() {
  DR_KEY="$2" perl -MJSON::PP -e 'local $/; my $d = decode_json(<STDIN>); my $v = $d->{$ENV{DR_KEY}}; print ref($v) ? ($v ? "true" : "false") : $v' < "$1"
}

@test "annotated tag is pushed with the notes as message, headings kept" {
  pubspec 1.0.0+1
  setup_remote
  dr all DR_PLATFORM=Android
  assert_success
  assert_equal "$(output tag-created)" "true"
  run remote_tag_message Android-v1.0.0+1
  assert_line --partial "type commit"
  assert_line '## 🚀 Android Release — `Android-v1.0.0+1`'
}

@test "lightweight tag" {
  pubspec 1.0.0+1
  setup_remote
  dr all DR_TAG=lightweight
  assert_success
  run git --git-dir="$BATS_TEST_TMPDIR/remote.git" cat-file -t refs/tags/v1.0.0+1
  assert_output commit
}

@test "tag: none creates nothing" {
  pubspec 1.0.0+1
  setup_remote
  dr all DR_TAG=none
  assert_success
  assert_equal "$(output tag-created)" "false"
  run git --git-dir="$BATS_TEST_TMPDIR/remote.git" tag -l
  assert_output ""
}

@test "on-existing=skip leaves the existing tag alone" {
  pubspec 1.0.0+1
  setup_remote
  tag v1.0.0+1
  git push -q origin v1.0.0+1
  commit "feat: later"
  dr all DR_ON_EXISTING=skip DR_RELEASE=true
  assert_success
  assert_equal "$(output tag-created)" "false"
  assert_output --partial "no tag or release created"
  assert_equal "$(git --git-dir="$BATS_TEST_TMPDIR/remote.git" rev-parse 'v1.0.0+1^{commit}')" "$(git rev-parse HEAD~1)"
}

@test "on-existing=overwrite moves the tag to HEAD" {
  pubspec 1.0.0+1
  setup_remote
  tag v1.0.0+1
  git push -q origin v1.0.0+1
  commit "feat: later"
  dr all DR_ON_EXISTING=overwrite
  assert_success
  assert_equal "$(git --git-dir="$BATS_TEST_TMPDIR/remote.git" rev-parse 'v1.0.0+1^{commit}')" "$(git rev-parse HEAD)"
}

@test "tag push failure explains the permission" {
  pubspec 1.0.0+1
  git remote add origin "$BATS_TEST_TMPDIR/does-not-exist.git"
  dr all
  assert_failure
  assert_output --partial "permissions: contents: write"
}

@test "release is created with the notes, flags and assets" {
  pubspec 1.3.0+1
  setup_remote
  use_fake_api
  mkdir -p build && echo apk > build/app.apk && echo ipa > "build/my app.ipa"
  dr all DR_PLATFORM=Android DR_RELEASE=true DR_PRERELEASE=true DR_MAKE_LATEST=legacy 'DR_FILES=build/*.apk
build/*.ipa
missing/*.zip'
  assert_success
  assert_equal "$(output release-url)" "https://github.com/o/r/releases/tag/new"
  assert_output --partial "'missing/*.zip' matched no file"

  run cat "$FAKE_LOG"
  assert_line --index 0 "GET https://api.github.com/repos/o/r/releases/tags/Android-v1.3.0%2B1"
  assert_line --index 1 "POST https://api.github.com/repos/o/r/releases"
  assert_line "POST https://uploads.example/repos/o/r/releases/8/assets?name=app.apk"
  assert_line "POST https://uploads.example/repos/o/r/releases/8/assets?name=my%20app.ipa"

  payload="$FAKE_DIR/body-2"
  assert_equal "$(json_field "$payload" tag_name)" "Android-v1.3.0+1"
  assert_equal "$(json_field "$payload" name)" "Android v1.3.0+1"
  assert_equal "$(json_field "$payload" prerelease)" "true"
  assert_equal "$(json_field "$payload" draft)" "false"
  assert_equal "$(json_field "$payload" make_latest)" "legacy"
  json_field "$payload" body | grep -q '## 🚀 Android Release'
}

@test "existing release fails unless overwrite, which patches it and replaces same-name assets" {
  pubspec 1.3.0+1
  setup_remote
  use_fake_api
  export FAKE_EXISTING=1
  dr all DR_RELEASE=true DR_TAG=none
  assert_failure
  assert_output --partial "release: true needs a tag"

  dr all DR_RELEASE=true
  assert_failure
  assert_output --partial "already exists — set on-existing to overwrite"

  : > "$FAKE_LOG"
  mkdir -p build && echo apk > build/app.apk
  dr all DR_ID=o DR_RELEASE=true DR_ON_EXISTING=overwrite DR_FILES=build/app.apk 'DR_RELEASE_NAME=Custom'
  assert_success
  run cat "$FAKE_LOG"
  assert_line "PATCH https://api.github.com/repos/o/r/releases/7"
  assert_line "DELETE https://api.github.com/repos/o/r/releases/assets/99"
  assert_line "POST https://uploads.example/repos/o/r/releases/7/assets?name=app.apk"
}

@test "API errors surface GitHub's message" {
  pubspec 1.3.0+1
  setup_remote
  use_fake_api
  export FAKE_FAIL_CREATE=1
  dr all DR_RELEASE=true
  assert_failure
  assert_output --partial "Creating the release for v1.3.0+1 failed (HTTP 422: Validation Failed)"
}

@test "release without a token fails clearly" {
  pubspec 1.3.0+1
  setup_remote
  use_fake_api
  unset GH_TOKEN
  dr all DR_RELEASE=true
  assert_failure
  assert_output --partial "No token for the GitHub API"
}

@test "version branch: created once, then left alone" {
  pubspec 1.3.0+1
  setup_remote
  dr all DR_PLATFORM=Android DR_TAG=none DR_BRANCH=true
  assert_success
  assert_equal "$(output branch)" "version/android/1.3.0+1"
  assert_equal "$(output branch-created)" "true"
  assert_equal "$(git --git-dir="$BATS_TEST_TMPDIR/remote.git" rev-parse refs/heads/version/android/1.3.0+1)" "$(git rev-parse HEAD)"

  : > "$GITHUB_OUTPUT"
  commit "fix: later"
  dr all DR_ID=again DR_PLATFORM=Android DR_TAG=none DR_BRANCH=true
  assert_success
  assert_equal "$(output branch-created)" "false"
  assert_output --partial "already exists on origin"
}

@test "branch template and invalid names" {
  pubspec 2.0.0+5
  setup_remote
  dr all DR_TAG=none DR_BRANCH=true 'DR_BRANCH_TEMPLATE=release/{{version_name}}'
  assert_success
  assert_equal "$(output branch)" "release/2.0.0"

  dr all DR_ID=bad DR_TAG=none DR_BRANCH=true 'DR_BRANCH_TEMPLATE=bad..name'
  assert_failure
  assert_output --partial "is not a valid branch name"
}
