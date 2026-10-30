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
  assert_output --partial "Could not push refs/tags/v1.0.0+1 (see the git output above)"
}

@test "a 403 elsewhere in git's output isn't taken for a permission error" {
  pubspec 1.0.0+1
  git remote add origin "$BATS_TEST_TMPDIR/run-4039/does-not-exist.git"
  dr all
  assert_failure
  assert_output --partial "Could not push refs/tags/v1.0.0+1 (see the git output above)"
  refute_output --partial "permissions: contents: write"

  git tag -d v1.0.0+1 > /dev/null # created locally before the failed push
  git init -q --bare "$BATS_TEST_TMPDIR/remote.git"
  git remote set-url origin "$BATS_TEST_TMPDIR/remote.git"
  cat > "$BATS_TEST_TMPDIR/remote.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
echo "fatal: unable to access 'https://github.com/o/r.git/': The requested URL returned error: 403" >&2
exit 1
HOOK
  chmod +x "$BATS_TEST_TMPDIR/remote.git/hooks/pre-receive"
  dr all DR_ID=https
  assert_failure
  assert_output --partial "Add 'permissions: contents: write'"
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

@test "on-existing=use keeps a hand-pushed tag and still publishes the release" {
  pubspec 1.3.0+1
  setup_remote
  use_fake_api
  tag v1.3.0+1
  git push -q origin v1.3.0+1
  dr all DR_ON_EXISTING=use DR_RELEASE=true
  assert_success
  assert_equal "$(output tag-created)" "false"
  assert_equal "$(output release-url)" "https://github.com/o/r/releases/tag/new"
  run git --git-dir="$BATS_TEST_TMPDIR/remote.git" cat-file -p refs/tags/v1.3.0+1
  refute_output --partial "## 🚀"
}

@test "release bodies over GitHub's limit are truncated, the tag keeps everything" {
  pubspec 1.3.0+1
  setup_remote
  use_fake_api
  perl -e 'print "# Changelog\n\n## [1.3.0+1]\n\n"; print "- " . ("x" x 98) . "\n" for 1..1500' > CHANGELOG.md
  git add CHANGELOG.md && commit "docs: big changelog"
  dr all DR_RELEASE=true
  assert_success
  assert_output --partial "were truncated in the release body"
  body_chars=$(DR_F="$FAKE_DIR/body-2" perl -MJSON::PP -e 'local $/; open my $f, "<", $ENV{DR_F}; print length(decode_json(<$f>)->{body})')
  [ "$body_chars" -le 125000 ]
  json_field "$FAKE_DIR/body-2" body | tail -n 1 | grep -q 'truncated'
  [ "$(git --git-dir="$BATS_TEST_TMPDIR/remote.git" cat-file -p refs/tags/v1.3.0+1 | wc -c)" -gt 150000 ]
}

# GitHub's rule: GITHUB_TOKEN can't push refs touching .github/workflows/.
reject_like_github() {
  cat > "$BATS_TEST_TMPDIR/remote.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
echo 'refusing to allow a GitHub App to create or update workflow `.github/workflows/ci.yml` without `workflows` permission' >&2
exit 1
HOOK
  chmod +x "$BATS_TEST_TMPDIR/remote.git/hooks/pre-receive"
}

@test "workflows-permission rejection falls back to the API (annotated tag + ref)" {
  pubspec 1.3.0+1
  setup_remote
  use_fake_api
  reject_like_github
  dr all DR_PLATFORM=Android
  assert_success
  assert_output --partial "rejected by GitHub's rule"
  assert_output --partial "created annotated tag Android-v1.3.0+1 through the API"
  assert_equal "$(output tag-created)" "true"
  run cat "$FAKE_LOG"
  assert_line --index 0 "POST https://api.github.com/repos/o/r/git/tags"
  assert_line --index 1 "POST https://api.github.com/repos/o/r/git/refs"
  assert_equal "$(json_field "$FAKE_DIR/body-1" tag)" "Android-v1.3.0+1"
  assert_equal "$(json_field "$FAKE_DIR/body-1" object)" "$(git rev-parse HEAD)"
  json_field "$FAKE_DIR/body-1" message | grep -q '^## 🚀 Android Release'
  assert_equal "$(json_field "$FAKE_DIR/body-2" ref)" "refs/tags/Android-v1.3.0+1"
  assert_equal "$(json_field "$FAKE_DIR/body-2" sha)" "0123456789abcdef0123456789abcdef01234567"
}

@test "API fallback: lightweight tag, overwrite and version branch" {
  pubspec 1.3.0+1
  setup_remote
  use_fake_api
  reject_like_github
  dr all DR_TAG=lightweight DR_BRANCH=true DR_PLATFORM=Web
  assert_success
  run cat "$FAKE_LOG"
  refute_line --partial "git/tags"
  assert_line "POST https://api.github.com/repos/o/r/git/refs"
  assert_equal "$(json_field "$FAKE_DIR/body-1" sha)" "$(git rev-parse HEAD)"
  assert_equal "$(json_field "$FAKE_DIR/body-2" ref)" "refs/heads/version/web/1.3.0+1"

  : > "$FAKE_LOG"
  git tag v9.9.9 # make the tag "exist" locally for on-existing=overwrite
  export FAKE_REF_EXISTS=1
  dr all DR_ID=ow DR_VERSION=9.9.9 DR_TAG=lightweight DR_ON_EXISTING=overwrite
  assert_success
  run cat "$FAKE_LOG"
  assert_line "PATCH https://api.github.com/repos/o/r/git/refs/tags/v9.9.9"
}

@test "other push failures don't fall back" {
  pubspec 1.3.0+1
  setup_remote
  use_fake_api
  cat > "$BATS_TEST_TMPDIR/remote.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
echo 'remote: Permission to o/r.git denied to github-actions[bot].' >&2
exit 1
HOOK
  chmod +x "$BATS_TEST_TMPDIR/remote.git/hooks/pre-receive"
  dr all
  assert_failure
  assert_output --partial "Add 'permissions: contents: write'"
  run cat "$FAKE_LOG"
  assert_output ""
}

remote_head() {
  git --git-dir="$BATS_TEST_TMPDIR/remote.git" rev-parse "refs/heads/$1"
}

@test "branch-update=fast-forward moves a patched release's branch forward" {
  pubspec 1.3.0+1
  setup_remote
  dr all DR_PLATFORM=Android DR_BRANCH=true
  assert_success
  release_sha=$(git rev-parse HEAD)

  commit "fix: hot"
  : > "$GITHUB_OUTPUT"
  dr all DR_ID=p1 DR_KIND=patch DR_PLATFORM=Android DR_BRANCH=true DR_BRANCH_UPDATE=fast-forward
  assert_success
  assert_equal "$(output tag)" "Android-v1.3.0+1-patch1"
  assert_equal "$(output branch)" "version/android/1.3.0+1"
  assert_equal "$(output branch-created)" "false"
  assert_equal "$(output branch-updated)" "true"
  assert_equal "$(remote_head version/android/1.3.0+1)" "$(git rev-parse HEAD)"
  [ "$release_sha" != "$(git rev-parse HEAD)" ]

  # Re-run on the same commit: nothing to move.
  : > "$GITHUB_OUTPUT"
  dr all DR_ID=p1again DR_KIND=patch DR_PLATFORM=Android DR_TAG=none DR_BRANCH=true DR_BRANCH_UPDATE=fast-forward
  assert_success
  assert_equal "$(output branch-updated)" "false"
  assert_output --partial "already at the deployed commit"
}

@test "branch-update=never (default) still leaves an existing branch alone" {
  pubspec 1.3.0+1
  setup_remote
  dr all DR_PLATFORM=Android DR_BRANCH=true
  release_sha=$(git rev-parse HEAD)
  commit "fix: hot"
  : > "$GITHUB_OUTPUT"
  dr all DR_ID=p1 DR_KIND=patch DR_PLATFORM=Android DR_BRANCH=true
  assert_success
  assert_equal "$(output branch-updated)" "false"
  assert_equal "$(remote_head version/android/1.3.0+1)" "$release_sha"
}

@test "branch-update=fast-forward never rewrites a diverged branch" {
  pubspec 1.3.0+1
  setup_remote
  dr all DR_PLATFORM=Android DR_BRANCH=true
  commit "fix: on the version branch"
  git push -q origin HEAD:refs/heads/version/android/1.3.0+1
  branch_sha=$(git rev-parse HEAD)
  git reset -q --hard HEAD~1
  commit "fix: elsewhere"
  : > "$GITHUB_OUTPUT"
  dr all DR_ID=p1 DR_KIND=patch DR_PLATFORM=Android DR_BRANCH=true DR_BRANCH_UPDATE=fast-forward
  assert_success
  assert_output --partial "is not an ancestor of the deployed commit"
  assert_equal "$(output branch-updated)" "false"
  assert_equal "$(remote_head version/android/1.3.0+1)" "$branch_sha"
}

@test "invalid branch-update fails" {
  pubspec 1.3.0+1
  dr prepare DR_BRANCH_UPDATE=force
  assert_failure
  assert_output --partial "Input 'branch-update' must be one of"
}

@test "API fallback: fast-forward is a non-forced ref update" {
  pubspec 1.3.0+1
  setup_remote
  dr all DR_PLATFORM=Web DR_TAG=none DR_BRANCH=true
  commit "fix: hot"
  use_fake_api
  reject_like_github
  : > "$GITHUB_OUTPUT"
  dr all DR_ID=p1 DR_KIND=patch DR_PLATFORM=Web DR_TAG=none DR_BRANCH=true DR_BRANCH_UPDATE=fast-forward
  assert_success
  assert_equal "$(output branch-updated)" "true"
  run cat "$FAKE_LOG"
  assert_line "PATCH https://api.github.com/repos/o/r/git/refs/heads/version%2Fweb%2F1.3.0%2B1"
  assert_equal "$(json_field "$FAKE_DIR/body-1" sha)" "$(git rev-parse HEAD)"
  assert_equal "$(json_field "$FAKE_DIR/body-1" force)" "false"
}

@test "patch releases are named after their patch number" {
  pubspec 1.3.0+1
  setup_remote
  git tag -a Web-v1.3.0+1 -m r
  git push -q origin Web-v1.3.0+1
  commit "fix: hot"
  use_fake_api
  dr all DR_KIND=patch DR_PLATFORM=Web DR_RELEASE=true
  assert_success
  run cat "$FAKE_LOG"
  assert_line "POST https://api.github.com/repos/o/r/releases"
  assert_equal "$(json_field "$FAKE_DIR/body-2" name)" "Web v1.3.0+1-patch1"
}
