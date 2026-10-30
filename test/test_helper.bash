# shellcheck shell=bash
# Shared setup: a fresh throwaway git repo per test, plus helpers to run the
# action's entry point the way action.yml does (inputs as DR_* env vars).

DR_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
load "$DR_ROOT/node_modules/bats-support/load"
load "$DR_ROOT/node_modules/bats-assert/load"

setup() {
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  cd "$WORK" || exit 1
  git init -q -b main
  git config user.name test
  git config user.email test@example.com
  git config tag.gpgSign false
  git config commit.gpgSign false
  # No detached gc/maintenance: a background git outliving the test keeps
  # bats waiting on its output (seen on the Windows runner).
  git config gc.auto 0
  git config maintenance.auto false

  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/step_summary"
  export GITHUB_RUN_NUMBER=42
  export GITHUB_RUN_ATTEMPT=1
  # The runner's own ref (the action's CI) must not leak into the throwaway
  # repos: the checked-out branch decides, unless a test sets it.
  unset GITHUB_REF_NAME
  mkdir -p "$RUNNER_TEMP"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
}

# commit <message> — an empty commit.
commit() {
  git commit -q --allow-empty -m "$1"
}

# pubspec <version> — writes and commits pubspec.yaml.
pubspec() {
  printf 'name: app\nversion: %s\n' "$1" > pubspec.yaml
  git add pubspec.yaml
  git commit -q -m "chore: version $1"
}

# tag <name> — annotated tag on HEAD.
tag() {
  git tag -a "$1" -m "$1"
  # creatordate has 1s resolution; keep "latest tag" ordering deterministic.
  sleep 1
}

# dr <mode> [VAR=value...] — runs src/main.sh with the given inputs.
dr() {
  local mode=$1
  shift
  run env DR_MODE="$mode" "$@" bash "$DR_ROOT/src/main.sh"
}

# output <name> — a single-line value written to $GITHUB_OUTPUT.
output() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -n 1
}
