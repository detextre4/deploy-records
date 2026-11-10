# shellcheck shell=bash disable=SC2034  # sets DR_V_*/DR_T_* globals read by main.sh
# Version resolution. Sets DR_V_FULL, DR_V_NAME (without +build) and
# DR_V_BUILD (the +build suffix, may be empty).

dr_version_format_for() {
  case "$(basename "$1")" in
    pubspec.yaml | pubspec.yml) echo pubspec ;;
    package.json) echo package-json ;;
    *) echo plain ;;
  esac
}

dr_read_version_file() {
  local file=$1 format=$2
  [ -f "$file" ] || dr_fail "version-file '$file' not found (set 'version' or point 'version-file' at the right file)."

  case "$format" in
    pubspec)
      sed -n 's/^version:[[:space:]]*//p' "$file" | head -n 1 | tr -d " \"'\r"
      ;;
    package-json)
      # Top-level "version" — the first one in a standard package.json.
      sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1
      ;;
    plain)
      grep -v '^[[:space:]]*$' "$file" | head -n 1 | tr -d ' \r'
      ;;
    regex)
      [ -n "${DR_VERSION_REGEX:-}" ] || dr_fail "version-format=regex requires 'version-regex'."
      DR_RE="$DR_VERSION_REGEX" perl -ne 'if (/$ENV{DR_RE}/) { print $1; exit }' "$file"
      ;;
    *)
      dr_fail "Unknown version-format '$format' (auto, pubspec, package-json, plain, regex)."
      ;;
  esac
}

# dr_resolve_patch_id — the changelog patch id: an explicit patch-id input,
# else the patch-id-key field of version-file (default app_patch in a
# pubspec, appPatch in a package.json). Empty when neither is set, which
# keeps patches on the Unreleased section. Unrelated to the per-platform
# {{patch}} counter derived from tags.
dr_resolve_patch_id() {
  local file=${DR_VERSION_FILE:-pubspec.yaml} format=${DR_VERSION_FORMAT:-auto} key value
  if [ -n "${DR_PATCH_ID:-}" ]; then
    printf '%s' "$DR_PATCH_ID"
    return 0
  fi
  [ -f "$file" ] || return 0
  [ "$format" = auto ] && format=$(dr_version_format_for "$file")

  case "$format" in
    pubspec)
      key=${DR_PATCH_ID_KEY:-app_patch}
      value=$(sed -n "s/^${key}:[[:space:]]*//p" "$file" | head -n 1 | sed 's/[[:space:]]*#.*$//' | tr -d " \"'\r")
      ;;
    package-json)
      key=${DR_PATCH_ID_KEY:-appPatch}
      value=$(sed -n "s/^[[:space:]]*\"${key}\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$file" | head -n 1 | tr -d ' \r')
      ;;
    *) value= ;;
  esac
  printf '%s' "$value"
}

dr_resolve_version() {
  local version format
  if [ -n "${DR_VERSION:-}" ]; then
    version=$DR_VERSION
  else
    format=${DR_VERSION_FORMAT:-auto}
    [ "$format" = auto ] && format=$(dr_version_format_for "${DR_VERSION_FILE:-pubspec.yaml}")
    version=$(dr_read_version_file "${DR_VERSION_FILE:-pubspec.yaml}" "$format")
  fi

  [ -n "$version" ] || dr_fail "Could not resolve a version (empty value from '${DR_VERSION_FILE:-pubspec.yaml}')."

  if dr_bool "${DR_REQUIRE_BUILD_NUMBER:-false}" require-build-number; then
    printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$' ||
      dr_fail "Version '$version' must be major.minor.patch+build (e.g. 1.3.0+1) — require-build-number is on."
  fi

  DR_V_FULL=$version
  DR_V_NAME=${version%%+*}
  case "$version" in
    *+*) DR_V_BUILD=${version#*+} ;;
    *) DR_V_BUILD= ;;
  esac
}
