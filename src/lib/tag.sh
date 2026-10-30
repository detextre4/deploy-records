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
    platform_lower "$(printf '%s' "${DR_PLATFORM:-}" | tr '[:upper:]' '[:lower:]')" \
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

# Whether base-version names a release (empty and "latest" mean the most
# recent one).
dr_base_version_set() {
  case "$(printf '%s' "${DR_BASE_VERSION:-}" | tr '[:upper:]' '[:lower:]')" in
    '' | latest) return 1 ;;
    *) return 0 ;;
  esac
}

# Sets DR_T_TAG, DR_T_PREVIOUS, DR_T_EXISTS, DR_T_BASE_TAG, DR_T_PATCH.
dr_resolve_tag() {
  local kind=$1 template release_glob patch_glob version build count unresolved
  DR_T_BASE_TAG=
  DR_T_PATCH=

  if dr_base_version_set; then
    [ "$kind" = patch ] ||
      dr_fail "base-version only applies to kind=patch (got kind=$kind) — leave it empty or 'latest'."
    if dr_bool "${DR_REQUIRE_BUILD_NUMBER:-false}" require-build-number; then
      printf '%s' "$DR_BASE_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$' ||
        dr_fail "base-version '$DR_BASE_VERSION' must be major.minor.patch+build (e.g. 1.3.0+1) — require-build-number is on."
    fi
  fi

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
      if dr_base_version_set; then
        # An explicit base: exactly that release, which must have been recorded.
        version=$DR_BASE_VERSION
        case "$version" in *+*) build=${version#*+} ;; *) build= ;; esac
        DR_T_BASE_TAG=$(dr_render_version "$(dr_render_context "$(dr_template_for release)")" "$version" "$build")
        dr_tag_exists "$DR_T_BASE_TAG" ||
          dr_fail "base-version $version: release tag $DR_T_BASE_TAG not found — patch a version that was released (and tagged), or leave base-version empty/latest for the most recent release."
      else
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

# --- Release lines -------------------------------------------------------
# With release-lines on, each version branch is the support line of its
# release: a patch run on it patches that release, and a patch of an older
# release has to run on its own line (trunk carries newer code).

# The ref this run is on (GITHUB_REF_NAME, else the checked-out branch).
dr_ref_name() {
  if [ -n "${GITHUB_REF_NAME:-}" ]; then
    printf '%s' "$GITHUB_REF_NAME"
  else
    git symbolic-ref --short -q HEAD 2> /dev/null || true
  fi
}

dr_branch_template() {
  if [ -n "${DR_BRANCH_TEMPLATE:-}" ]; then
    printf '%s' "$DR_BRANCH_TEMPLATE"
  elif [ -n "${DR_PLATFORM:-}" ]; then
    printf '%s' 'version/{{platform_lower}}/{{version}}'
  else
    printf '%s' 'version/{{version}}'
  fi
}

# dr_branch_name <version> <build> <tag> — the version branch of a release.
dr_branch_name() {
  dr_render "$(dr_render_version "$(dr_render_context "$(dr_branch_template)")" "$1" "$2")" tag "$3"
}

# Sets DR_L_LINE (the release line this run is on, empty if none) and, for a
# patch on a line, DR_BASE_VERSION (the line's release).
dr_resolve_line() {
  local kind=$1 template prefix suffix ref version
  DR_L_LINE=
  dr_bool "${DR_RELEASE_LINES:-false}" release-lines || return 0

  template=$(dr_render "$(dr_branch_template)" platform "${DR_PLATFORM:-}" \
    platform_lower "$(printf '%s' "${DR_PLATFORM:-}" | tr '[:upper:]' '[:lower:]')")
  prefix=${template%%"{{version}}"*}
  suffix=${template#*"{{version}}"}
  case "$template" in
    *'{{version}}'*) ;;
    *) prefix='{{' ;;
  esac
  case "$prefix$suffix" in
    *'{{'*) dr_fail "release-lines needs a branch-template whose only placeholders are {{version}} (once), {{platform}} and {{platform_lower}} — got '$(dr_branch_template)'." ;;
  esac

  ref=$(dr_ref_name)
  case "$ref" in
    "$prefix"*"$suffix") ;;
    *) return 0 ;;
  esac
  version=${ref#"$prefix"}
  version=${version%"$suffix"}
  [ -n "$version" ] || return 0
  DR_L_LINE=$ref

  case "$kind" in
    release)
      dr_fail "kind=release on the release line $ref — releases run from the main deploy branch; on $ref only patches of $version are allowed."
      ;;
    patch)
      if dr_base_version_set && [ "$DR_BASE_VERSION" != "$version" ]; then
        dr_fail "base-version $DR_BASE_VERSION doesn't match the release line $ref, which patches $version — leave base-version empty/latest or set it to $version."
      fi
      DR_BASE_VERSION=$version
      ;;
  esac
  dr_info "release line $ref (release $version)"
}

# Off a release line, a patch may only target the most recent release.
# Requires dr_resolve_tag to have run.
dr_check_line_policy() {
  local kind=$1 latest line
  [ "$kind" = patch ] || return 0
  [ -z "$DR_L_LINE" ] || return 0
  dr_bool "${DR_RELEASE_LINES:-false}" release-lines || return 0

  latest=$(dr_latest_tag "$(dr_glob_for "$(dr_template_for release)")" "$(dr_glob_for "$(dr_template_for patch)")")
  [ -n "$latest" ] || return 0
  [ "$DR_T_BASE_TAG" != "$latest" ] || return 0
  line=$(dr_branch_name "$DR_V_FULL" "$DR_V_BUILD" "$DR_T_TAG")
  dr_fail "$DR_T_BASE_TAG is not the latest release ($latest) — with release-lines, an older release is patched from its release line: branch $line off it (if missing), cherry-pick the fix there and run this workflow on $line."
}

# Sets DR_RECORDED: whether tag/release/branch are written (record: false
# never; else record-on globs, where a release line always counts).
dr_resolve_recorded() {
  local ref pattern patterns
  DR_RECORDED=true
  # record: false — a trial run (e.g. a staging-channel patch): notes only,
  # whatever the ref.
  if ! dr_bool "${DR_RECORD:-true}" record; then
    DR_RECORDED=false
    dr_info "record: false — only the notes and summary are written (no tag, release or branch)."
    return 0
  fi
  [ -n "${DR_RECORD_ON:-}" ] || return 0
  [ -z "$DR_L_LINE" ] || return 0
  ref=$(dr_ref_name)
  patterns=$(printf '%s' "$DR_RECORD_ON" | tr ',' '\n')
  while IFS= read -r pattern; do
    pattern=$(printf '%s' "$pattern" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$pattern" ] || continue
    # shellcheck disable=SC2254  # unquoted on purpose: glob match
    case "$ref" in $pattern) return 0 ;; esac
  done <<PATTERNS
$patterns
PATTERNS
  DR_RECORDED=false
  dr_info "ref '$ref' is not in record-on — only the notes and summary are written (no tag, release or branch)."
}
