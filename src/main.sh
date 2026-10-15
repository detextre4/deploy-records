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

dr_validate_inputs() {
  dr_one_of "${DR_MODE:-all}" mode prepare finalize all
  dr_one_of "${DR_KIND:-release}" kind release patch testing
  dr_one_of "${DR_TAG:-annotated}" tag none annotated lightweight
  dr_one_of "${DR_ON_EXISTING:-fail}" on-existing fail skip overwrite
  dr_one_of "${DR_LANGUAGE:-en}" language en es
  dr_bool "${DR_SUMMARY:-true}" summary || true
  dr_bool "${DR_RELEASE:-false}" release || true
  if dr_bool "${DR_RELEASE:-false}" release && [ "${DR_TAG:-annotated}" = none ]; then
    dr_fail "release: true needs a tag — set 'tag' to annotated or lightweight."
  fi
  git rev-parse --git-dir > /dev/null 2>&1 || dr_fail "Not inside a git repository — run actions/checkout (with fetch-depth: 0) first."
}

dr_prepare() {
  local kind=${DR_KIND:-release}
  dr_resolve_version
  dr_resolve_tag "$kind"

  if [ "$DR_T_EXISTS" = true ]; then
    case "${DR_ON_EXISTING:-fail}" in
      fail) dr_fail "Tag $DR_T_TAG already exists — bump the version (or its +build number) before recording this $kind again, or set on-existing to skip/overwrite." ;;
      skip) dr_warn "Tag $DR_T_TAG already exists — on-existing=skip: no tag or release will be created." ;;
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
    patch "$DR_T_PATCH"

  dr_set_output version "$DR_V_FULL"
  dr_set_output version-name "$DR_V_NAME"
  dr_set_output build-number "$DR_V_BUILD"
  dr_set_output tag "$DR_T_TAG"
  dr_set_output previous-tag "$DR_T_PREVIOUS"
  dr_set_output tag-exists "$DR_T_EXISTS"
}

dr_finalize() {
  dr_fail "mode=finalize is not implemented yet."
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
