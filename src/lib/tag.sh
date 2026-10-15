# shellcheck shell=bash disable=SC2034  # sets DR_V_*/DR_T_* globals read by main.sh
# Tag resolution: the kind's template, the previous tag, patch numbering and
# the "already exists" policy. Requires dr_resolve_version to have run.

dr_default_template() {
  case "$1" in
    release)
      if [ -n "${DR_PLATFORM:-}" ]; then echo '{{platform}}-v{{version}}'; else echo 'v{{version}}'; fi
      ;;
    patch)
      echo '{{base_tag}}-patch{{patch}}'
      ;;
    testing)
      if [ -n "${DR_PLATFORM:-}" ]; then echo 'testing-{{platform}}-v{{version}}-run{{run}}'; else echo 'testing-v{{version}}-run{{run}}'; fi
      ;;
  esac
}

dr_template_for() {
  local custom
  case "$1" in
    release) custom=${DR_TAG_TEMPLATE_RELEASE:-} ;;
    patch) custom=${DR_TAG_TEMPLATE_PATCH:-} ;;
    testing) custom=${DR_TAG_TEMPLATE_TESTING:-} ;;
  esac
  if [ -n "$custom" ]; then echo "$custom"; else dr_default_template "$1"; fi
}

# Context placeholders available to every tag template (not the version ones).
dr_render_context() {
  local sha=${GITHUB_SHA:-}
  [ -n "$sha" ] || sha=$(git rev-parse HEAD 2>/dev/null || true)
  dr_render "$1" \
    platform "${DR_PLATFORM:-}" \
    run "${GITHUB_RUN_NUMBER:-0}" \
    run_attempt "${GITHUB_RUN_ATTEMPT:-1}" \
    sha "$sha" \
    short_sha "$(printf '%s' "$sha" | cut -c1-8)" \
    date "$(date -u +%Y-%m-%d)"
}

# Glob matching every tag a template can produce: only {{platform}} is fixed,
# per-run values ({{run}}, {{sha}}, {{date}}...) and the version become "*".
dr_glob_for() {
  dr_glob_from_template "$(dr_render "$1" platform "${DR_PLATFORM:-}")"
}

dr_render_version() {
  dr_render "$1" version "$2" version_name "${2%%+*}" build_number "$3"
}

dr_tag_exists() {
  git rev-parse -q --verify "refs/tags/$1" > /dev/null 2>&1
}

# Latest tag matching <glob> by creation date, excluding <exclude-glob>.
dr_latest_tag() {
  local glob=$1 exclude=${2:-} t tags
  # Captured first, not piped: breaking out of `git tag | while` early would
  # SIGPIPE git and fail the step under pipefail.
  tags=$(git tag -l "$glob" --sort=-creatordate)
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ -n "$exclude" ]; then
      # shellcheck disable=SC2254  # unquoted on purpose: glob match
      case "$t" in $exclude) continue ;; esac
    fi
    printf '%s\n' "$t"
    return 0
  done <<EOF
$tags
EOF
}

# Nearest tag reachable from HEAD matching <glob>, never <self>.
dr_nearest_tag() {
  git describe --tags --match "$1" --exclude "$2" --abbrev=0 HEAD 2>/dev/null || true
}

# Inverse of the release template: the version inside a release tag, or empty.
dr_version_from_release_tag() {
  local tag=$1 template prefix suffix
  template=$(dr_render "$(dr_template_for release)" platform "${DR_PLATFORM:-}")
  case "$template" in
    *'{{version}}'*) ;;
    *) return 0 ;;
  esac
  prefix=${template%%"{{version}}"*}
  suffix=${template#*"{{version}}"}
  case "$prefix$suffix" in *'{{'*) return 0 ;; esac
  case "$tag" in
    "$prefix"*"$suffix") ;;
    *) return 0 ;;
  esac
  tag=${tag#"$prefix"}
  printf '%s' "${tag%"$suffix"}"
}

# Sets DR_T_TAG, DR_T_PREVIOUS, DR_T_EXISTS, DR_T_BASE_TAG, DR_T_PATCH.
dr_resolve_tag() {
  local kind=$1 template release_glob patch_glob version build count unresolved
  DR_T_BASE_TAG=
  DR_T_PATCH=

  if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    dr_warn "Shallow clone: earlier tags aren't visible, so the previous tag, patch numbering and the existing-tag check can be wrong. Use actions/checkout with fetch-depth: 0."
  fi

  release_glob=$(dr_glob_for "$(dr_template_for release)")
  version=$DR_V_FULL
  build=$DR_V_BUILD

  case "$kind" in
    release | testing)
      template=$(dr_render_version "$(dr_render_context "$(dr_template_for "$kind")")" "$version" "$build")
      ;;
    patch)
      patch_glob=$(dr_glob_for "$(dr_template_for patch)")
      DR_T_BASE_TAG=$(dr_latest_tag "$release_glob" "$patch_glob")
      if [ -z "$DR_T_BASE_TAG" ]; then
        DR_T_BASE_TAG=$(dr_render_version "$(dr_render_context "$(dr_template_for release)")" "$version" "$build")
        dr_warn "No release tag matching '$release_glob' found; numbering this patch against '$DR_T_BASE_TAG' (the current version)."
      else
        local tagged
        tagged=$(dr_version_from_release_tag "$DR_T_BASE_TAG")
        if [ -n "$tagged" ]; then
          version=$tagged
          case "$tagged" in *+*) build=${tagged#*+} ;; *) build= ;; esac
        fi
      fi
      count=$(git tag -l "$(dr_glob_for "$(dr_render "$(dr_template_for patch)" base_tag "$DR_T_BASE_TAG")")" | wc -l | tr -d ' ')
      DR_T_PATCH=$((count + 1))
      template=$(dr_render "$(dr_render_version "$(dr_render_context "$(dr_template_for patch)")" "$version" "$build")" \
        base_tag "$DR_T_BASE_TAG" patch "$DR_T_PATCH")
      # The patch is labelled with the version it patches.
      DR_V_FULL=$version
      DR_V_NAME=${version%%+*}
      DR_V_BUILD=$build
      ;;
    *)
      dr_fail "Unknown kind '$kind' (release, patch, testing)."
      ;;
  esac

  unresolved=$(dr_unresolved "$template")
  [ -z "$unresolved" ] || dr_fail "Tag template for kind=$kind has an unknown placeholder $unresolved."
  DR_T_TAG=$template

  if [ -n "${DR_PREVIOUS_TAG_PATTERN:-}" ]; then
    DR_T_PREVIOUS=$(dr_nearest_tag "$DR_PREVIOUS_TAG_PATTERN" "$DR_T_TAG")
  elif [ "$kind" = testing ]; then
    DR_T_PREVIOUS=$(dr_nearest_tag "$(dr_glob_for "$(dr_template_for testing)")" "$DR_T_TAG")
  else
    # Release and patch tags share the release glob ("Android-v*" also
    # matches "Android-v1.3.0+1-patch2"), so patches diff from the last
    # release or patch, whichever is nearer.
    DR_T_PREVIOUS=$(dr_nearest_tag "$release_glob" "$DR_T_TAG")
  fi

  if dr_tag_exists "$DR_T_TAG"; then DR_T_EXISTS=true; else DR_T_EXISTS=false; fi
}
