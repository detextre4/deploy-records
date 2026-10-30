#!/usr/bin/env bash
# deploy-records entry point. Every input arrives as a DR_* env var (see
# action.yml) — never interpolated into shell code.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

DR_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$DR_SRC/lib/common.sh"
# shellcheck source=lib/version.sh
. "$DR_SRC/lib/version.sh"
# shellcheck source=lib/tag.sh
. "$DR_SRC/lib/tag.sh"
# shellcheck source=lib/changelog.sh
. "$DR_SRC/lib/changelog.sh"
# shellcheck source=lib/commits.sh
. "$DR_SRC/lib/commits.sh"
# shellcheck source=lib/notes.sh
. "$DR_SRC/lib/notes.sh"
# shellcheck source=lib/records.sh
. "$DR_SRC/lib/records.sh"

dr_validate_inputs() {
  dr_one_of "${DR_MODE:-all}" mode prepare finalize all
  dr_one_of "${DR_KIND:-release}" kind release patch testing
  dr_one_of "${DR_TAG:-annotated}" tag none annotated lightweight
  dr_one_of "${DR_ON_EXISTING:-fail}" on-existing fail skip use overwrite
  dr_one_of "${DR_BRANCH_UPDATE:-never}" branch-update never fast-forward
  dr_one_of "${DR_LANGUAGE:-en}" language en es
  dr_bool "${DR_SUMMARY:-true}" summary || true
  dr_bool "${DR_RELEASE:-false}" release || true
  dr_bool "${DR_BRANCH:-false}" branch || true
  dr_bool "${DR_RELEASE_LINES:-false}" release-lines || true
  dr_bool "${DR_RECORD:-true}" record || true
  if dr_bool "${DR_RELEASE:-false}" release && [ "${DR_TAG:-annotated}" = none ]; then
    dr_fail "release: true needs a tag — set 'tag' to annotated or lightweight."
  fi
  git rev-parse --git-dir > /dev/null 2>&1 || dr_fail "Not inside a git repository — run actions/checkout (with fetch-depth: 0) first."
}

dr_prepare() {
  local kind=${DR_KIND:-release}
  dr_resolve_version
  dr_resolve_line "$kind"
  dr_resolve_tag "$kind"
  dr_check_line_policy "$kind"
  dr_resolve_recorded

  if [ "$DR_T_EXISTS" = true ] && [ "$DR_RECORDED" = false ]; then
    dr_info "Tag $DR_T_TAG already exists — ignored, nothing is recorded on this ref."
  elif [ "$DR_T_EXISTS" = true ]; then
    case "${DR_ON_EXISTING:-fail}" in
      fail) dr_fail "Tag $DR_T_TAG already exists — bump the version (or its +build number) before recording this $kind again, or set on-existing to skip/use/overwrite." ;;
      skip) dr_warn "Tag $DR_T_TAG already exists — on-existing=skip: no tag or release will be created." ;;
      use) dr_info "Tag $DR_T_TAG already exists — on-existing=use: it is kept as is; release/branch records still run." ;;
      overwrite) dr_warn "Tag $DR_T_TAG already exists — on-existing=overwrite: it will be replaced." ;;
    esac
  fi

  dr_info "version=$DR_V_FULL tag=$DR_T_TAG previous=${DR_T_PREVIOUS:-<none>} exists=$DR_T_EXISTS"

  dr_state_write \
    kind "$kind" \
    version "$DR_V_FULL" \
    version_name "$DR_V_NAME" \
    build_number "$DR_V_BUILD" \
    tag "$DR_T_TAG" \
    previous_tag "$DR_T_PREVIOUS" \
    tag_exists "$DR_T_EXISTS" \
    base_tag "$DR_T_BASE_TAG" \
    patch "$DR_T_PATCH"     recorded "$DR_RECORDED"     release_line "$DR_L_LINE"

  dr_set_output version "$DR_V_FULL"
  dr_set_output version-name "$DR_V_NAME"
  dr_set_output build-number "$DR_V_BUILD"
  dr_set_output tag "$DR_T_TAG"
  dr_set_output previous-tag "$DR_T_PREVIOUS"
  dr_set_output tag-exists "$DR_T_EXISTS"
  dr_set_output base-tag "$DR_T_BASE_TAG"
  dr_set_output patch "$DR_T_PATCH"
  dr_set_output recorded "$DR_RECORDED"
  dr_set_output release-line "$DR_L_LINE"
}

# Restores what prepare resolved (same job, same id).
dr_load_state() {
  dr_state_exists || dr_fail "mode=finalize found no prepare state for id '${DR_ID:-default}' — run this action with mode=prepare earlier in the same job (or use mode=all)."
  DR_N_KIND=$(dr_state_get kind)
  DR_V_FULL=$(dr_state_get version)
  DR_V_NAME=$(dr_state_get version_name)
  DR_V_BUILD=$(dr_state_get build_number)
  DR_T_TAG=$(dr_state_get tag)
  DR_T_PREVIOUS=$(dr_state_get previous_tag)
  DR_T_EXISTS=$(dr_state_get tag_exists)
  DR_T_BASE_TAG=$(dr_state_get base_tag)
  DR_T_PATCH=$(dr_state_get patch)
  DR_RECORDED=$(dr_state_get recorded)
  DR_L_LINE=$(dr_state_get release_line)
}

dr_finalize() {
  local notes
  dr_load_state

  notes=${DR_NOTES_FILE:-}
  [ -n "$notes" ] || notes="$(dirname "$(dr_state_file)")/${DR_ID:-default}.md"
  dr_build_notes "$notes"
  dr_info "notes written to $notes"

  if dr_bool "${DR_SUMMARY:-true}" summary; then
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      { cat "$notes"; echo; } >> "$GITHUB_STEP_SUMMARY"
    else
      dr_warn "GITHUB_STEP_SUMMARY is not set — summary skipped."
    fi
  fi

  dr_records "$notes"

  dr_set_output version "$DR_V_FULL"
  dr_set_output version-name "$DR_V_NAME"
  dr_set_output build-number "$DR_V_BUILD"
  dr_set_output tag "$DR_T_TAG"
  dr_set_output previous-tag "$DR_T_PREVIOUS"
  dr_set_output tag-exists "$DR_T_EXISTS"
  dr_set_output base-tag "$DR_T_BASE_TAG"
  dr_set_output patch "$DR_T_PATCH"
  dr_set_output recorded "${DR_RECORDED:-true}"
  dr_set_output release-line "$DR_L_LINE"
  dr_set_output notes-path "$notes"
  dr_set_output notes "$(cat "$notes")"
}

dr_main() {
  dr_validate_inputs
  case "${DR_MODE:-all}" in
    prepare) dr_prepare ;;
    finalize) dr_finalize ;;
    all)
      dr_prepare
      dr_finalize
      ;;
  esac
}

# Sourced by the tests without running.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  dr_main "$@"
fi
