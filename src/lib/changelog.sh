# shellcheck shell=bash disable=SC2034  # sets DR_C_* globals read by notes.sh
# Keep a Changelog section lookup. Sets DR_C_LABEL (section name used, or
# names joined by ", " when a patch spans several; empty when the file is
# missing), DR_C_DISPLAY (the same, each in brackets) and DR_C_BODY (the
# content, may be empty).

# dr_changelog_section <file> <name> — body of "## [<name>]", without the
# heading and without leading blank lines.
dr_changelog_section() {
  awk -v h="## [$2]" '
    { sub(/\r$/, "") }
    index($0, h) == 1 { found = 1; next }
    found && /^## \[/ { exit }
    found { print }
  ' "$1" | sed '/./,$!d'
}

dr_changelog_has_section() {
  grep -Fq "## [$2]" "$1"
}

# dr_patch_section_name <version> <patch id> — patch-section-template with
# {{version}} and {{patch_id}} filled in (default "{{version}}-patch.{{patch_id}}").
dr_patch_section_name() {
  local name=${DR_PATCH_SECTION_TEMPLATE:-}
  [ -n "$name" ] || name='{{version}}-patch.{{patch_id}}'
  name=${name//\{\{version\}\}/$1}
  name=${name//\{\{patch_id\}\}/$2}
  printf '%s' "$name"
}

# Marker appended to a patch's notes (so to its annotated tag): the next
# patch of the same platform reads it to know which sections it already
# shipped. An HTML comment, so it doesn't show in rendered Markdown.
DR_PATCH_MARKER_PREFIX='<!-- deploy-records:patch-id='

# dr_previous_patch_id — sets DR_C_PREV_TAG (this platform's latest patch tag
# of the same release, empty when it's the first) and DR_C_PREV_ID (the patch
# id recorded in it; empty when that tag has no marker).
dr_previous_patch_id() {
  local glob
  DR_C_PREV_TAG=
  DR_C_PREV_ID=
  [ -n "${DR_T_BASE_TAG:-}" ] || return 0
  glob=$(dr_glob_for "$(dr_render "$(dr_template_for patch)" base_tag "$DR_T_BASE_TAG")")
  DR_C_PREV_TAG=$(dr_latest_tag "$glob" "${DR_T_TAG:-}")
  [ -n "$DR_C_PREV_TAG" ] || return 0
  DR_C_PREV_ID=$(git tag -l --format='%(contents)' "$DR_C_PREV_TAG" |
    sed -n 's/^<!-- deploy-records:patch-id=\([A-Za-z0-9._-]*\) -->$/\1/p' | tail -n 1)
}

# dr_is_count <value> — a non-negative integer.
dr_is_count() {
  case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac
}

# dr_patch_sections <file> <version> <patch id> — the patch's section, or with
# patch-sections=accumulate and numeric ids every non-empty section from the
# one after this platform's previous patch up to this one (a platform that
# skipped a patch still gets its notes; patches are cumulative). Sets
# DR_C_LABEL/DR_C_DISPLAY/DR_C_BODY; leaves DR_C_BODY empty when there's
# nothing to ship.
dr_patch_sections() {
  local file=$1 version=$2 id=$3 strategy=${DR_PATCH_SECTIONS:-accumulate} from i name body
  local labels='' display='' merged='' count=0 last_name='' last_body=''

  case "$strategy" in
    accumulate | single) ;;
    *) dr_fail "Unknown patch-sections '$strategy' (accumulate, single)." ;;
  esac

  from=$id
  if [ "$strategy" = accumulate ] && dr_is_count "$id"; then
    dr_previous_patch_id
    if [ -z "$DR_C_PREV_TAG" ]; then
      from=0
    elif [ -z "$DR_C_PREV_ID" ]; then
      dr_info "Previous patch $DR_C_PREV_TAG has no recorded patch id — only this patch's section is used."
    elif ! dr_is_count "$DR_C_PREV_ID"; then
      dr_info "Previous patch id '$DR_C_PREV_ID' isn't a number — only this patch's section is used."
    elif [ "$DR_C_PREV_ID" -gt "$id" ]; then
      dr_warn "Patch id $id is lower than the previous patch's ($DR_C_PREV_ID, $DR_C_PREV_TAG) — only this patch's section is used. Check the patch id."
    elif [ "$DR_C_PREV_ID" -lt "$id" ]; then
      from=$DR_C_PREV_ID
    fi
    if [ "$from" != "$id" ] && [ $((id - from)) -gt 1000 ]; then
      dr_warn "Patch id range $((from + 1))..$id is too wide — only this patch's section is used."
      from=$id
    fi
  fi

  if [ "$from" = "$id" ]; then
    i=$id
  else
    i=$((from + 1))
  fi
  while :; do
    name=$(dr_patch_section_name "$version" "$i")
    body=$(dr_changelog_section "$file" "$name" 2> /dev/null)
    if [ -n "$body" ]; then
      count=$((count + 1))
      labels="${labels:+$labels, }$name"
      display="${display:+$display, }[$name]"
      merged="${merged:+$merged
}#### $name

$body
"
      last_name=$name
      last_body=$body
    else
      dr_info "No entries under '## [$name]'."
    fi
    [ "$i" = "$id" ] && break
    i=$((i + 1))
  done

  case "$count" in
    0)
      dr_info "No patch section with entries — using Unreleased."
      return 0
      ;;
    1)
      DR_C_LABEL=$last_name
      DR_C_BODY=$last_body
      ;;
    *)
      DR_C_LABEL=$labels
      # $(...) drops the trailing blank lines.
      DR_C_BODY=$(printf '%s' "$merged")
      ;;
  esac
  DR_C_DISPLAY=${display}
  [ "$count" = 1 ] && DR_C_DISPLAY="[$last_name]"
  return 0
}

# dr_resolve_changelog <kind> <version>
dr_resolve_changelog() {
  local kind=$1 version=$2 file=${DR_CHANGELOG_PATH:-CHANGELOG.md} mode=${DR_CHANGELOG_SECTION:-auto}
  DR_C_LABEL=
  DR_C_DISPLAY=
  DR_C_BODY=

  if [ ! -f "$file" ]; then
    dr_info "No changelog at '$file' — changelog section skipped."
    return 0
  fi

  case "$mode" in
    auto)
      if [ "$kind" = patch ]; then
        # A patch never ships its base release's notes: its own section(s)
        # when it has a patch id and they have entries, else whatever is
        # pending in Unreleased.
        DR_C_LABEL=Unreleased
        local patch_id
        patch_id=$(dr_resolve_patch_id)
        [ -z "$patch_id" ] || dr_patch_sections "$file" "$version" "$patch_id"
        if [ -n "$DR_C_BODY" ]; then
          return 0
        fi
      elif dr_changelog_has_section "$file" "$version"; then
        DR_C_LABEL=$version
      else
        DR_C_LABEL=Unreleased
      fi
      ;;
    version) DR_C_LABEL=$version ;;
    unreleased) DR_C_LABEL=Unreleased ;;
    *) DR_C_LABEL=$mode ;;
  esac

  DR_C_DISPLAY="[$DR_C_LABEL]"
  if ! dr_changelog_has_section "$file" "$DR_C_LABEL"; then
    dr_warn "Changelog '$file' has no '## [$DR_C_LABEL]' section."
    return 0
  fi
  DR_C_BODY=$(dr_changelog_section "$file" "$DR_C_LABEL")
}
