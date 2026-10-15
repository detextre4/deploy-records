# shellcheck shell=bash disable=SC2154
# SC2154: DR_T_* come from tag.sh / the prepare state, loaded by main.sh.
# Records with side effects outside the job: the git tag and the GitHub
# Release. The release goes straight to the REST API with curl (present on
# every runner, Windows and self-hosted included) — no gh/action dependency,
# and make_latest=legacy is supported. JSON is built/parsed with perl's core
# JSON::PP so notes are always escaped correctly.

dr_uri_escape() {
  DR_RAW="$1" perl -e 'my $s = $ENV{DR_RAW}; $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge; print $s'
}

# dr_json_get <file> <key> — top-level scalar from a JSON object.
dr_json_get() {
  DR_KEY="$2" perl -MJSON::PP -e '
    local $/; my $d = eval { decode_json(<STDIN>) } or exit 0;
    my $v = ref($d) eq "HASH" ? $d->{$ENV{DR_KEY}} : undef;
    print $v if defined $v && !ref $v;
  ' < "$1"
}

# dr_json_asset_ids <file> <name> — ids of a release's assets with that name.
dr_json_asset_ids() {
  DR_NAME="$2" perl -MJSON::PP -e '
    local $/; my $d = eval { decode_json(<STDIN>) } or exit 0;
    for my $a (@{ $d->{assets} || [] }) { print "$a->{id}\n" if $a->{name} eq $ENV{DR_NAME} }
  ' < "$1"
}

# dr_release_payload <notes file> > json
dr_release_payload() {
  local make_latest=${DR_MAKE_LATEST:-true} draft=false prerelease=false
  dr_one_of "$make_latest" make-latest true false legacy
  dr_bool "${DR_DRAFT:-false}" draft && draft=true
  dr_bool "${DR_PRERELEASE:-false}" prerelease && prerelease=true
  DR_P_TAG=$DR_T_TAG DR_P_NAME=$DR_R_NAME DR_P_DRAFT=$draft DR_P_PRE=$prerelease DR_P_LATEST=$make_latest \
    perl -MJSON::PP -e '
      local $/; open my $fh, "<:raw", $ARGV[0] or die "notes: $!"; my $body = <$fh>;
      utf8::decode($body);
      print JSON::PP->new->utf8->canonical->encode({
        tag_name    => $ENV{DR_P_TAG},
        name        => $ENV{DR_P_NAME},
        body        => $body,
        draft       => $ENV{DR_P_DRAFT} eq "true" ? JSON::PP::true : JSON::PP::false,
        prerelease  => $ENV{DR_P_PRE} eq "true" ? JSON::PP::true : JSON::PP::false,
        make_latest => $ENV{DR_P_LATEST},
      });
    ' "$1"
}

# dr_http <method> <url> <response file> [curl args...] — sets DR_HTTP_STATUS.
dr_http() {
  local method=$1 url=$2 out=$3
  shift 3
  [ -n "${GH_TOKEN:-}" ] || dr_fail "No token for the GitHub API — pass 'token' (defaults to github.token)."
  DR_HTTP_STATUS=$(curl -sS -X "$method" "$url" \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -o "$out" -w '%{http_code}' "$@") || dr_fail "Request to $url failed (network)."
}

dr_api_fail() {
  local message
  message=$(dr_json_get "$2" message)
  dr_fail "$1 (HTTP $DR_HTTP_STATUS${message:+: $message})."
}

dr_push_tag() {
  local notes=$1 force=
  if [ "$DR_T_EXISTS" = true ] && [ "${DR_ON_EXISTING:-fail}" = overwrite ]; then
    git tag -d "$DR_T_TAG" > /dev/null
    force=--force
  fi

  # Annotated tags need a tagger, which actions/checkout doesn't configure.
  if [ -z "$(git config user.name || true)" ]; then
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  fi

  if [ "${DR_TAG:-annotated}" = annotated ]; then
    # verbatim: the default "strip" cleanup would drop every Markdown
    # heading, since git treats lines starting with '#' as comments.
    git tag -a "$DR_T_TAG" -F "$notes" --cleanup=verbatim
  else
    git tag "$DR_T_TAG"
  fi
  git push $force "${DR_REMOTE:-origin}" "refs/tags/$DR_T_TAG" ||
    dr_fail "Could not push tag $DR_T_TAG — the workflow needs 'permissions: contents: write'."
  dr_info "pushed ${DR_TAG:-annotated} tag $DR_T_TAG"
}

dr_upload_assets() {
  local upload_url=$1 release_json=$2 pattern file name id matched tmp
  [ -n "${DR_FILES:-}" ] || return 0
  tmp=$(dirname "$release_json")
  upload_url=${upload_url%%\{*}
  while IFS= read -r pattern; do
    pattern=${pattern%$'\r'}
    [ -n "${pattern//[[:space:]]/}" ] || continue
    matched=false
    for file in $pattern; do
      [ -f "$file" ] || continue
      matched=true
      name=$(basename "$file")
      # overwrite: replace an asset of the same name instead of failing.
      for id in $(dr_json_asset_ids "$release_json" "$name"); do
        dr_http DELETE "$DR_API/repos/$DR_REPO/releases/assets/$id" "$tmp/delete.json"
      done
      dr_http POST "$upload_url?name=$(dr_uri_escape "$name")" "$tmp/asset.json" \
        -H "Content-Type: application/octet-stream" --data-binary "@$file"
      [ "$DR_HTTP_STATUS" = 201 ] || dr_api_fail "Uploading $file failed" "$tmp/asset.json"
      dr_info "attached $name"
    done
    [ "$matched" = true ] || dr_warn "files: '$pattern' matched no file — nothing attached for it."
  done <<EOF
$DR_FILES
EOF
}

dr_publish_release() {
  local notes=$1 tmp tag_path id upload_url url
  DR_API=${GITHUB_API_URL:-https://api.github.com}
  DR_REPO=${GITHUB_REPOSITORY:-}
  [ -n "$DR_REPO" ] || dr_fail "GITHUB_REPOSITORY is not set — can't publish a release outside GitHub Actions."
  DR_R_NAME=${DR_RELEASE_NAME:-}
  if [ -z "$DR_R_NAME" ]; then
    if [ -n "${DR_PLATFORM:-}" ]; then DR_R_NAME="$DR_PLATFORM v$DR_V_FULL"; else DR_R_NAME="v$DR_V_FULL"; fi
  fi

  tmp="$(dirname "$(dr_state_file)")/release-${DR_ID:-default}"
  mkdir -p "$tmp"
  dr_release_payload "$notes" > "$tmp/payload.json"
  tag_path=$(dr_uri_escape "$DR_T_TAG")

  dr_http GET "$DR_API/repos/$DR_REPO/releases/tags/$tag_path" "$tmp/existing.json"
  if [ "$DR_HTTP_STATUS" = 200 ]; then
    [ "${DR_ON_EXISTING:-fail}" = overwrite ] ||
      dr_fail "A release for $DR_T_TAG already exists — set on-existing to overwrite to update it."
    id=$(dr_json_get "$tmp/existing.json" id)
    dr_http PATCH "$DR_API/repos/$DR_REPO/releases/$id" "$tmp/release.json" --data-binary "@$tmp/payload.json"
    [ "$DR_HTTP_STATUS" = 200 ] || dr_api_fail "Updating the release for $DR_T_TAG failed" "$tmp/release.json"
  elif [ "$DR_HTTP_STATUS" = 404 ]; then
    dr_http POST "$DR_API/repos/$DR_REPO/releases" "$tmp/release.json" --data-binary "@$tmp/payload.json"
    [ "$DR_HTTP_STATUS" = 201 ] || dr_api_fail "Creating the release for $DR_T_TAG failed" "$tmp/release.json"
  else
    dr_api_fail "Looking up the release for $DR_T_TAG failed" "$tmp/existing.json"
  fi

  upload_url=$(dr_json_get "$tmp/release.json" upload_url)
  url=$(dr_json_get "$tmp/release.json" html_url)
  dr_upload_assets "$upload_url" "$tmp/release.json"
  dr_info "release published: $url"
  dr_set_output release-url "$url"
}

# Version branch at the deployed commit (support/hotfix line). An existing
# branch is never moved — a re-run must not rewrite a release line.
dr_push_branch() {
  local template=${DR_BRANCH_TEMPLATE:-} name unresolved remote=${DR_REMOTE:-origin}
  if [ -z "$template" ]; then
    if [ -n "${DR_PLATFORM:-}" ]; then template='version/{{platform_lower}}/{{version}}'; else template='version/{{version}}'; fi
  fi
  name=$(dr_render "$(dr_render_version "$(dr_render_context "$template")" "$DR_V_FULL" "$DR_V_BUILD")" tag "$DR_T_TAG")
  unresolved=$(dr_unresolved "$name")
  [ -z "$unresolved" ] || dr_fail "branch-template has an unknown placeholder $unresolved."
  git check-ref-format --branch "$name" > /dev/null 2>&1 || dr_fail "'$name' is not a valid branch name (from branch-template)."
  dr_set_output branch "$name"

  if git ls-remote --exit-code --heads "$remote" "$name" > /dev/null 2>&1; then
    dr_info "branch $name already exists on $remote — left as is."
    dr_set_output branch-created false
    return 0
  fi
  git push "$remote" "HEAD:refs/heads/$name" ||
    dr_fail "Could not push branch $name — the workflow needs 'permissions: contents: write'."
  dr_info "pushed branch $name"
  dr_set_output branch-created true
}

# dr_records <notes file>
dr_records() {
  local notes=$1 want_tag=true
  [ "${DR_TAG:-annotated}" = none ] && want_tag=false

  if [ "$DR_T_EXISTS" = true ] && [ "${DR_ON_EXISTING:-fail}" = skip ]; then
    dr_info "tag $DR_T_TAG already exists (on-existing=skip) — no tag or release created."
    dr_set_output tag-created false
    dr_set_output release-url ""
    return 0
  fi

  if [ "$DR_T_EXISTS" = true ] && [ "${DR_ON_EXISTING:-fail}" = use ]; then
    dr_info "using the existing tag $DR_T_TAG."
    dr_set_output tag-created false
  elif [ "$want_tag" = true ]; then
    dr_push_tag "$notes"
    dr_set_output tag-created true
  else
    dr_set_output tag-created false
  fi

  if dr_bool "${DR_RELEASE:-false}" release; then
    dr_publish_release "$notes"
  else
    dr_set_output release-url ""
  fi

  if dr_bool "${DR_BRANCH:-false}" branch; then
    dr_push_branch
  else
    dr_set_output branch ""
    dr_set_output branch-created false
  fi
}
