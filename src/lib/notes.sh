# shellcheck shell=bash source-path=SCRIPTDIR disable=SC2016,SC2154
# SC2016: backticks in single-quoted printf formats are Markdown, not code.
# SC2154: DR_L_* labels come from ../i18n/*.sh, DR_V_*/DR_T_*/DR_C_*/DR_G_* from
# the other libs, all sourced by main.sh before any function here runs.
# Notes rendering: built-in layout (sections in the order given by
# `sections`) or a user Markdown template with {{placeholders}}.

DR_LABEL_KEYS="field value version tag commit previous_tag note none kind_release kind_patch kind_testing changelog commits_since commits_all no_changelog no_commits more"

dr_load_labels() {
  local lang=${DR_LANGUAGE:-en} line key text
  # shellcheck source=../i18n/en.sh
  . "$DR_SRC/i18n/en.sh"
  # shellcheck source=/dev/null
  [ "$lang" = en ] || . "$DR_SRC/i18n/$lang.sh"

  [ -n "${DR_LABELS:-}" ] || return 0
  while IFS= read -r line; do
    line=${line%$'\r'}
    [ -n "${line//[[:space:]]/}" ] || continue
    case "$line" in
      *=*) ;;
      *) dr_fail "Input 'labels' line '$line' must be key=Text." ;;
    esac
    key=${line%%=*}
    key=${key//[[:space:]]/}
    text=${line#*=}
    text=${text#"${text%%[![:space:]]*}"}
    text=${text%"${text##*[![:space:]]}"}
    case " $DR_LABEL_KEYS " in
      *" $key "*) printf -v "DR_L_$key" '%s' "$text" ;;
      *) dr_fail "Unknown label key '$key' in 'labels' (valid: $DR_LABEL_KEYS)." ;;
    esac
  done <<EOF
$DR_LABELS
EOF
}

# A value safe inside a Markdown table cell.
dr_cell() {
  local v=${1//|/\\|}
  v=${v//$'\r'/}
  printf '%s' "${v//$'\n'/<br>}"
}

dr_kind_label() {
  case "$1" in
    release) printf '%s' "$DR_L_kind_release" ;;
    patch) printf '%s' "$DR_L_kind_patch" ;;
    testing) printf '%s' "$DR_L_kind_testing" ;;
  esac
}

dr_commit_link() {
  local short
  short=$(printf '%s' "$DR_N_SHA" | cut -c1-8)
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    printf '[`%s`](%s/%s/commit/%s)' "$short" "${GITHUB_SERVER_URL:-https://github.com}" "$GITHUB_REPOSITORY" "$DR_N_SHA"
  else
    printf '`%s`' "$short"
  fi
}

dr_block_details() {
  local line label value
  printf '| %s | %s |\n| :--- | :--- |\n' "$DR_L_field" "$DR_L_value"
  printf '| **%s** | `%s` |\n' "$DR_L_version" "$DR_V_FULL"
  printf '| **%s** | `%s` |\n' "$DR_L_tag" "$DR_T_TAG"
  printf '| **%s** | %s |\n' "$DR_L_commit" "$(dr_commit_link)"
  if [ -n "${DR_DETAILS:-}" ]; then
    while IFS= read -r line; do
      line=${line%$'\r'}
      [ -n "${line//[[:space:]]/}" ] || continue
      case "$line" in
        *'|'*) label=${line%%|*} value=${line#*|} ;;
        *) dr_fail "Input 'details' line '$line' must be Label|Value." ;;
      esac
      printf '| **%s** | %s |\n' "$(dr_cell "$label")" "$(dr_cell "$value")"
    done <<EOF
$DR_DETAILS
EOF
  fi
  printf '| **%s** | %s |\n' "$DR_L_note" "$(dr_cell "${DR_NOTE:-$DR_L_none}")"
}

dr_block_changelog() {
  [ -n "$DR_C_LABEL" ] || return 0
  printf '### 📋 %s (%s — `[%s]`)\n\n' "$DR_L_changelog" "$(basename "${DR_CHANGELOG_PATH:-CHANGELOG.md}")" "$DR_C_LABEL"
  if [ -n "$DR_C_BODY" ]; then printf '%s\n' "$DR_C_BODY"; else printf '%s\n' "$DR_L_no_changelog"; fi
}

dr_commits_body() {
  if [ -n "$DR_G_LIST" ]; then printf '%s\n' "$DR_G_LIST"; else printf '%s\n' "$DR_L_no_commits"; fi
  if [ "$DR_G_HIDDEN" -gt 0 ]; then printf -- '- … +%s %s\n' "$DR_G_HIDDEN" "$DR_L_more"; fi
}

dr_block_commits() {
  if [ -n "$DR_T_PREVIOUS" ]; then
    printf '### 🧾 %s `%s`\n\n' "$DR_L_commits_since" "$DR_T_PREVIOUS"
  else
    printf '### 🧾 %s\n\n' "$DR_L_commits_all"
  fi
  dr_commits_body
}

dr_default_title() {
  if [ -n "${DR_TITLE:-}" ]; then
    printf '%s' "$DR_TITLE"
  elif [ -n "${DR_PLATFORM:-}" ]; then
    printf '%s %s' "$DR_PLATFORM" "$(dr_kind_label "$DR_N_KIND")"
  else
    dr_kind_label "$DR_N_KIND"
  fi
}

dr_layout_default() {
  local section block
  printf '## 🚀 %s — `%s`\n' "$DR_N_TITLE" "$DR_T_TAG"
  for section in $(printf '%s' "${DR_SECTIONS:-details,changelog,commits}" | tr ',' ' '); do
    case "$section" in
      details) block=$(dr_block_details) ;;
      changelog) block=$(dr_block_changelog) ;;
      commits) block=$(dr_block_commits) ;;
      *) dr_fail "Unknown section '$section' in 'sections' (details, changelog, commits)." ;;
    esac
    [ -n "$block" ] || continue
    printf '\n%s\n' "$block"
    first=false
  done
  : "$first"
}

dr_layout_template() {
  local file=$DR_TEMPLATE_FILE template rendered unresolved
  [ -f "$file" ] || dr_fail "template-file '$file' not found."
  template=$(cat "$file")
  rendered=$(dr_render "$template" \
    title "$DR_N_TITLE" \
    kind "$DR_N_KIND" \
    kind_label "$(dr_kind_label "$DR_N_KIND")" \
    platform "${DR_PLATFORM:-}" \
    version "$DR_V_FULL" \
    version_name "$DR_V_NAME" \
    build_number "$DR_V_BUILD" \
    tag "$DR_T_TAG" \
    previous_tag "$DR_T_PREVIOUS" \
    sha "$DR_N_SHA" \
    short_sha "$(printf '%s' "$DR_N_SHA" | cut -c1-8)" \
    commit_link "$(dr_commit_link)" \
    note "${DR_NOTE:-}" \
    details "$(dr_block_details)" \
    changelog "$(dr_block_changelog)" \
    changelog_body "$DR_C_BODY" \
    changelog_section "$DR_C_LABEL" \
    commits "$(dr_block_commits)" \
    commit_list "$(dr_commits_body)" \
    commit_count "$DR_G_TOTAL" \
    run "${GITHUB_RUN_NUMBER:-0}" \
    run_url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
    repository "${GITHUB_REPOSITORY:-}" \
    date "$(date -u +%Y-%m-%d)")
  unresolved=$(dr_unresolved "$rendered")
  [ -z "$unresolved" ] || dr_warn "template-file has an unknown placeholder $unresolved (left as-is)."
  printf '%s\n' "$rendered"
}

# dr_build_notes <out file> — needs DR_V_*, DR_T_*, DR_N_KIND resolved.
dr_build_notes() {
  local out=$1
  dr_load_labels
  DR_N_SHA=${GITHUB_SHA:-}
  [ -n "$DR_N_SHA" ] || DR_N_SHA=$(git rev-parse HEAD)
  DR_N_TITLE=$(dr_default_title)
  dr_resolve_changelog "$DR_N_KIND" "$DR_V_FULL"
  dr_resolve_commits "$DR_T_PREVIOUS"

  mkdir -p "$(dirname "$out")"
  if [ -n "${DR_TEMPLATE_FILE:-}" ]; then
    dr_layout_template > "$out"
  else
    dr_layout_default > "$out"
  fi
}
