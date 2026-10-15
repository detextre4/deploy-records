# shellcheck shell=bash disable=SC2034  # sets DR_G_* globals read by notes.sh
# Commit list since the previous tag. Sets DR_G_LIST (formatted lines, capped
# at max-commits), DR_G_TOTAL (all commits in range) and DR_G_HIDDEN.

dr_resolve_commits() {
  local previous=$1 range max=${DR_MAX_COMMITS:-150} merges=--no-merges
  case "$max" in
    '' | *[!0-9]*) dr_fail "Input 'max-commits' must be a whole number, got '$max'." ;;
  esac
  dr_bool "${DR_INCLUDE_MERGES:-false}" include-merges && merges=

  if [ -n "$previous" ]; then range="${previous}..HEAD"; else range=HEAD; fi

  # shellcheck disable=SC2086  # $merges is intentionally empty or one flag
  DR_G_TOTAL=$(git rev-list $merges --count "$range")
  if [ "$max" -eq 0 ]; then
    DR_G_LIST=
  else
    # -n, never `| head`: an early-closed pipe would SIGPIPE git under pipefail.
    # shellcheck disable=SC2086
    DR_G_LIST=$(git log "$range" $merges -n "$max" --pretty=format:"${DR_COMMIT_FORMAT:-- %s (%h)}")
  fi
  DR_G_HIDDEN=$((DR_G_TOTAL > max ? DR_G_TOTAL - max : 0))
}
