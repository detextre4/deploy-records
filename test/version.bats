#!/usr/bin/env bats
load test_helper

@test "reads pubspec.yaml by default" {
  pubspec 1.3.0+7
  dr prepare
  assert_success
  assert_equal "$(output version)" "1.3.0+7"
  assert_equal "$(output version-name)" "1.3.0"
  assert_equal "$(output build-number)" "7"
}

@test "auto-detects package.json and ignores nested versions" {
  printf '{\n  "name": "api",\n  "version": "0.4.2",\n  "dependencies": { "x": { "version": "9.9.9" } }\n}\n' > package.json
  git add package.json && commit "feat: api"
  dr prepare DR_VERSION_FILE=package.json
  assert_success
  assert_equal "$(output version)" "0.4.2"
  assert_equal "$(output build-number)" ""
}

@test "plain file takes the first non-empty line" {
  printf '\n  2.0.1  \nignored\n' > VERSION
  git add VERSION && commit "chore: version"
  dr prepare DR_VERSION_FILE=VERSION
  assert_success
  assert_equal "$(output version)" "2.0.1"
}

@test "regex format uses the first capture group" {
  printf 'const appVersion = "5.6.7";\n' > version.ts
  git add version.ts && commit "chore: version"
  dr prepare DR_VERSION_FILE=version.ts DR_VERSION_FORMAT=regex 'DR_VERSION_REGEX=appVersion = "([^"]+)"'
  assert_success
  assert_equal "$(output version)" "5.6.7"
}

@test "explicit version wins over the file" {
  pubspec 1.0.0+1
  dr prepare DR_VERSION=9.9.9+9
  assert_success
  assert_equal "$(output version)" "9.9.9+9"
}

@test "require-build-number rejects a version without +build" {
  pubspec 1.3.0
  dr prepare DR_REQUIRE_BUILD_NUMBER=true
  assert_failure
  assert_output --partial "must be major.minor.patch+build"
}

@test "missing version file fails with a hint" {
  commit "chore: empty"
  dr prepare
  assert_failure
  assert_output --partial "version-file 'pubspec.yaml' not found"
}
