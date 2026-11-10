# shellcheck shell=bash disable=SC2034  # sets DR_C_* globals read by notes.sh
# Keep a Changelog section lookup. Sets DR_C_LABEL (section name used, empty
# when the file is missing) and DR_C_BODY (its content, may be empty).

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

# dr_resolve_changelog <kind> <version>
dr_resolve_changelog() {
  local kind=$1 version=$2 file=${DR_CHANGELOG_PATH:-CHANGELOG.md} mode=${DR_CHANGELOG_SECTION:-auto}
  DR_C_LABEL=
  DR_C_BODY=

  if [ ! -f "$file" ]; then
    dr_info "No changelog at '$file' — changelog section skipped."
    return 0
  fi

  case "$mode" in
    auto)
      if [ "$kind" = patch ]; then
        # A patch never ships its base release's notes: its own section
        # when it has a patch id and that section has entries, else
        # whatever is pending in Unreleased.
        DR_C_LABEL=Unreleased
        local patch_id patch_label
        patch_id=$(dr_resolve_patch_id)
        if [ -n "$patch_id" ]; then
          patch_label=$(dr_patch_section_name "$version" "$patch_id")
          if [ -n "$(dr_changelog_section "$file" "$patch_label" 2> /dev/null)" ]; then
            DR_C_LABEL=$patch_label
          else
            dr_info "No entries under '## [$patch_label]' — using Unreleased."
          fi
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

  if ! dr_changelog_has_section "$file" "$DR_C_LABEL"; then
    dr_warn "Changelog '$file' has no '## [$DR_C_LABEL]' section."
    return 0
  fi
  DR_C_BODY=$(dr_changelog_section "$file" "$DR_C_LABEL")
}
