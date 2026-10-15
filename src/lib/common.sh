# shellcheck shell=bash
# Shared helpers. Bash 3.2-compatible (macOS runners ship bash 3.2): no
# associative arrays, no ${var,,}, no mapfile.

# Bash 5.2 makes "&" in a ${var//pattern/replacement} replacement expand to
# the matched text — a template value containing "&" would get mangled.
shopt -u patsub_replacement 2>/dev/null || true

dr_fail() {
  echo "::error title=deploy-records::$*" >&2
  exit 1
}

dr_warn() {
  echo "::warning title=deploy-records::$*" >&2
}

dr_info() {
  echo "deploy-records: $*" >&2
}

# dr_bool <value> <input name> — true/false with the usual spellings.
dr_bool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true | yes | on | 1) return 0 ;;
    false | no | off | 0 | '') return 1 ;;
    *) dr_fail "Input '$2' must be true or false, got '$1'." ;;
  esac
}

# dr_one_of <value> <input name> <allowed...>
dr_one_of() {
  local value=$1 name=$2 allowed
  shift 2
  for allowed in "$@"; do
    [ "$value" = "$allowed" ] && return 0
  done
  dr_fail "Input '$name' must be one of: $* (got '$value')."
}

# dr_set_output <name> <value> — to $GITHUB_OUTPUT (multi-line safe).
dr_set_output() {
  local name=$1 value=$2 delimiter
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  if [[ "$value" == *$'\n'* ]]; then
    delimiter="DR_EOF_$$_${RANDOM:-0}"
    {
      echo "${name}<<${delimiter}"
      printf '%s\n' "$value"
      echo "$delimiter"
    } >> "$GITHUB_OUTPUT"
  else
    echo "${name}=${value}" >> "$GITHUB_OUTPUT"
  fi
}

# --- State shared between a prepare step and a later finalize step -------

dr_state_file() {
  local base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/deploy-records"
  mkdir -p "$base"
  printf '%s/%s.state' "$base" "${DR_ID:-default}"
}

# dr_state_write <key> <value>... — single-line values only.
dr_state_write() {
  local file
  file=$(dr_state_file)
  : > "$file"
  while [ $# -ge 2 ]; do
    printf '%s=%s\n' "$1" "$2" >> "$file"
    shift 2
  done
}

# dr_state_get <key> — prints the value, empty if missing.
dr_state_get() {
  local file key=$1 line
  file=$(dr_state_file)
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "$key="*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done < "$file"
}

dr_state_exists() {
  [ -f "$(dr_state_file)" ]
}

# --- Templates ------------------------------------------------------------

# dr_render <template> <name> <value> [<name> <value>...]
# Replaces every {{name}} with value. Unknown placeholders are left as-is.
dr_render() {
  local out=$1
  shift
  while [ $# -ge 2 ]; do
    out=${out//"{{$1}}"/"$2"}
    shift 2
  done
  printf '%s' "$out"
}

# dr_unresolved <text> — prints the first {{placeholder}} left, if any.
dr_unresolved() {
  printf '%s' "$1" | grep -o '{{[A-Za-z0-9_]*}}' | head -n 1 || true
}

# dr_glob_from_template <rendered-or-partial template> — every remaining
# {{placeholder}} becomes "*" (for git tag globs).
dr_glob_from_template() {
  printf '%s' "$1" | sed 's/{{[A-Za-z0-9_]*}}/*/g; s/\*\*\**/*/g'
}
