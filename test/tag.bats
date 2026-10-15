#!/usr/bin/env bats
load test_helper

@test "release tag with platform" {
  pubspec 1.3.0+1
  dr prepare DR_PLATFORM=Android
  assert_success
  assert_equal "$(output tag)" "Android-v1.3.0+1"
  assert_equal "$(output tag-exists)" "false"
  assert_equal "$(output previous-tag)" ""
}

@test "release tag without platform" {
  pubspec 1.3.0+1
  dr prepare
  assert_success
  assert_equal "$(output tag)" "v1.3.0+1"
}

@test "testing tag carries the run number" {
  pubspec 1.3.0+1
  dr prepare DR_KIND=testing DR_PLATFORM=Web
  assert_success
  assert_equal "$(output tag)" "testing-Web-v1.3.0+1-run42"
}

@test "existing release tag fails by default" {
  pubspec 1.3.0+1
  tag Android-v1.3.0+1
  dr prepare DR_PLATFORM=Android
  assert_failure
  assert_output --partial "Tag Android-v1.3.0+1 already exists"
}

@test "on-existing=skip and overwrite don't fail" {
  pubspec 1.3.0+1
  tag Android-v1.3.0+1
  dr prepare DR_PLATFORM=Android DR_ON_EXISTING=skip
  assert_success
  assert_equal "$(output tag-exists)" "true"
  dr prepare DR_PLATFORM=Android DR_ON_EXISTING=overwrite
  assert_success
  assert_output --partial "will be replaced"
}

@test "previous tag is the nearest release of the same platform" {
  pubspec 1.2.0+1
  tag Android-v1.2.0+1
  tag iOS-v1.2.0+1
  commit "feat: x"
  pubspec 1.3.0+1
  tag iOS-v1.3.0+1
  dr prepare DR_PLATFORM=Android
  assert_success
  assert_equal "$(output previous-tag)" "Android-v1.2.0+1"
}

@test "testing diffs against testing tags only" {
  pubspec 1.3.0+1
  tag testing-Android-v1.3.0+1-run41
  commit "feat: x"
  tag Android-v1.3.0+1
  commit "feat: y"
  dr prepare DR_KIND=testing DR_PLATFORM=Android
  assert_success
  assert_equal "$(output previous-tag)" "testing-Android-v1.3.0+1-run41"
}

@test "patches number per base release and keep its version" {
  pubspec 1.3.0+1
  tag Android-v1.3.0+1
  commit "fix: hot"
  dr prepare DR_KIND=patch DR_PLATFORM=Android
  assert_success
  assert_equal "$(output tag)" "Android-v1.3.0+1-patch1"
  assert_equal "$(output previous-tag)" "Android-v1.3.0+1"

  tag Android-v1.3.0+1-patch1
  # pubspec already bumped for the next release: the patch still targets 1.3.0+1
  pubspec 1.4.0+1
  dr prepare DR_KIND=patch DR_PLATFORM=Android
  assert_success
  assert_equal "$(output tag)" "Android-v1.3.0+1-patch2"
  assert_equal "$(output version)" "1.3.0+1"
  assert_equal "$(output previous-tag)" "Android-v1.3.0+1-patch1"
}

@test "patch without any release falls back to the current version" {
  pubspec 2.0.0+3
  dr prepare DR_KIND=patch DR_PLATFORM=iOS
  assert_success
  assert_equal "$(output tag)" "iOS-v2.0.0+3-patch1"
  assert_output --partial "No release tag matching"
}

@test "custom templates with every placeholder" {
  pubspec 1.3.0+5
  dr prepare DR_PLATFORM=Web 'DR_TAG_TEMPLATE_RELEASE=web/{{version_name}}/b{{build_number}}-r{{run}}'
  assert_success
  assert_equal "$(output tag)" "web/1.3.0/b5-r42"
}

@test "unknown placeholder in a template fails" {
  pubspec 1.3.0+1
  dr prepare 'DR_TAG_TEMPLATE_RELEASE=v{{verison}}'
  assert_failure
  assert_output --partial "unknown placeholder {{verison}}"
}

@test "previous-tag-pattern override" {
  pubspec 1.0.0+1
  tag legacy-1
  commit "feat: x"
  dr prepare DR_PLATFORM=Android 'DR_PREVIOUS_TAG_PATTERN=legacy-*'
  assert_success
  assert_equal "$(output previous-tag)" "legacy-1"
}

@test "prepare persists state for a later finalize" {
  pubspec 1.3.0+1
  dr prepare DR_PLATFORM=Android DR_ID=android
  assert_success
  run cat "$RUNNER_TEMP/deploy-records/android.state"
  assert_line "tag=Android-v1.3.0+1"
  assert_line "version=1.3.0+1"
}
