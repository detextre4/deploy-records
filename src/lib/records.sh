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
      # GitHub rejects release bodies over 125000 characters (HTTP 422).
      # The tag message and the job summary still carry the full notes.
      my $max = 125000;
      my $more = "\n\n… (truncated — the full notes are in the tag message and the workflow run summary)\n";
      if (length($body) > $max) {
        $body = substr($body, 0, $max - length($more)) . $more;
        print STDERR "::warning title=deploy-records::Release notes exceed GitHub'"'"'s 125000-character limit and were truncated in the release body.\n";
      }
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

# dr_json_payload key=value... > json — "!key=true|false" for booleans,
# "@key=<file>" to embed a file's (UTF-8) content.
dr_json_payload() {
  perl -MJSON::PP -e '
    my %h;
    for my $arg (@ARGV) {
      my ($k, $v) = split /=/, $arg, 2;
      if ($k =~ s/^!//) { $h{$k} = $v eq "true" ? JSON::PP::true : JSON::PP::false; next }
      if ($k =~ s/^@//) { local $/; open my $fh, "<:raw", $v or die "$v: $!"; $v = <$fh> }
      utf8::decode($v);
      $h{$k} = $v;
    }
    print JSON::PP->new->utf8->canonical->encode(\%h);
  ' "$@"
}

dr_api_init() {
  DR_API=${GITHUB_API_URL:-https://api.github.com}
  DR_REPO=${GITHUB_REPOSITORY:-}
  [ -n "$DR_REPO" ] || dr_fail "GITHUB_REPOSITORY is not set — can't call the GitHub API outside GitHub Actions."
  DR_API_TMP="$(dirname "$(dr_state_file)")/api-${DR_ID:-default}"
  mkdir -p "$DR_API_TMP"
}

# dr_api_ref <full ref, e.g. refs/tags/x> <sha> <overwrite: true|false>
# Creates the ref through the REST API (or moves it when overwriting).
dr_api_ref() {
  local ref=$1 sha=$2 overwrite=$3 path
  dr_api_init
  dr_json_payload "ref=$ref" "sha=$sha" > "$DR_API_TMP/ref.json"
  dr_http POST "$DR_API/repos/$DR_REPO/git/refs" "$DR_API_TMP/ref-out.json" --data-binary "@$DR_API_TMP/ref.json"
  [ "$DR_HTTP_STATUS" = 201 ] && return 0
  if [ "$DR_HTTP_STATUS" = 422 ] && [ "$overwrite" = true ]; then
    dr_api_update_ref "$ref" "$sha" true
    return 0
  fi
  dr_api_fail "Creating $ref through the API failed" "$DR_API_TMP/ref-out.json"
}

# dr_api_update_ref <full ref> <sha> <force: true|false> — moves an existing
# ref; without force GitHub only accepts a fast-forward.
dr_api_update_ref() {
  local ref=$1 sha=$2 force=$3 path
  dr_api_init
  path="${ref#refs/}"
  path="${path%%/*}/$(dr_uri_escape "${path#*/}")"
  dr_json_payload "sha=$sha" "!force=$force" > "$DR_API_TMP/ref.json"
  dr_http PATCH "$DR_API/repos/$DR_REPO/git/refs/$path" "$DR_API_TMP/ref-out.json" --data-binary "@$DR_API_TMP/ref.json"
  [ "$DR_HTTP_STATUS" = 200 ] || dr_api_fail "Updating $ref through the API failed" "$DR_API_TMP/ref-out.json"
}

# dr_git_push <refspec> [--force] — 0 pushed; 2 rejected by GitHub's
# "workflows" permission rule (the caller falls back to the API); any other
# failure stops the step with a message matching its cause.
dr_git_push() {
  local refspec=$1 force=${2:-} out
  # shellcheck disable=SC2086  # $force is empty or one flag
  if out=$(git push $force "${DR_REMOTE:-origin}" "$refspec" 2>&1); then
    printf '%s\n' "$out" >&2
    return 0
  fi
  printf '%s\n' "$out" >&2
  # shellcheck disable=SC2016  # literal backticks from GitHub's message
  case "$out" in
    *'without `workflows` permission'* | *"without 'workflows' permission"*)
      return 2
      ;;
    *'Permission to'*'denied'* | *'403'* | *'not allowed to push'*)
      dr_fail "Could not push $refspec — the token can't write to the repository. Add 'permissions: contents: write' to the workflow (or pass a token that can)."
      ;;
    *)
      dr_fail "Could not push $refspec (see the git output above)."
      ;;
  esac
}

dr_workflows_fallback_note() {
  dr_warn "git push of $1 was rejected by GitHub's rule that GITHUB_TOKEN can't push refs touching .github/workflows/ — creating it through the REST API instead."
}

dr_push_tag() {
  local notes=$1 force='' overwrite=false sha tag_sha rc
  if [ "$DR_T_EXISTS" = true ] && [ "${DR_ON_EXISTING:-fail}" = overwrite ]; then
    git tag -d "$DR_T_TAG" > /dev/null
    force=--force
    overwrite=true
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

  # shellcheck disable=SC2086  # $force is empty or one flag
  if dr_git_push "refs/tags/$DR_T_TAG" $force; then
    dr_info "pushed ${DR_TAG:-annotated} tag $DR_T_TAG"
    return 0
  else
    rc=$?
  fi
  [ "$rc" = 2 ] || return "$rc"

  dr_workflows_fallback_note "tag $DR_T_TAG"
  sha=$(git rev-parse HEAD)
  if [ "${DR_TAG:-annotated}" = annotated ]; then
    dr_api_init
    dr_json_payload "tag=$DR_T_TAG" "@message=$notes" "object=$sha" "type=commit" > "$DR_API_TMP/tag.json"
    dr_http POST "$DR_API/repos/$DR_REPO/git/tags" "$DR_API_TMP/tag-out.json" --data-binary "@$DR_API_TMP/tag.json"
    [ "$DR_HTTP_STATUS" = 201 ] || dr_api_fail "Creating the tag object $DR_T_TAG failed" "$DR_API_TMP/tag-out.json"
    tag_sha=$(dr_json_get "$DR_API_TMP/tag-out.json" sha)
  else
    tag_sha=$sha
  fi
  dr_api_ref "refs/tags/$DR_T_TAG" "$tag_sha" "$overwrite"
  dr_info "created ${DR_TAG:-annotated} tag $DR_T_TAG through the API"
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
  dr_api_init
  DR_R_NAME=${DR_RELEASE_NAME:-}
  if [ -z "$DR_R_NAME" ]; then
    DR_R_NAME="v$DR_V_FULL"
    # Patches of one release would otherwise all share its name.
    [ "${DR_N_KIND:-}" = patch ] && [ -n "${DR_T_PATCH:-}" ] && DR_R_NAME="$DR_R_NAME-patch$DR_T_PATCH"
    [ -n "${DR_PLATFORM:-}" ] && DR_R_NAME="$DR_PLATFORM $DR_R_NAME"
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

# dr_fast_forward_branch <name> — moves an existing version branch up to
# HEAD, only when HEAD descends from it (never a force push). Anything else
# is a warning, not a failure: this runs after the deploy itself succeeded.
dr_fast_forward_branch() {
  local name=$1 remote=${DR_REMOTE:-origin} tip head rc
  head=$(git rev-parse HEAD)
  if ! git fetch -q "$remote" "refs/heads/$name" 2> /dev/null; then
    dr_warn "Could not fetch branch $name from $remote — left as is."
    return 0
  fi
  tip=$(git rev-parse FETCH_HEAD)
  if [ "$tip" = "$head" ]; then
    dr_info "branch $name is already at the deployed commit."
    return 0
  fi
  if ! git merge-base --is-ancestor "$tip" "$head"; then
    dr_warn "Branch $name (${tip:0:8}) is not an ancestor of the deployed commit (${head:0:8}) — not fast-forwarded. Deploy from that branch (or a branch built on it) to advance it."
    return 0
  fi

  if dr_git_push "HEAD:refs/heads/$name"; then
    dr_info "fast-forwarded branch $name to ${head:0:8}"
  else
    rc=$?
    [ "$rc" = 2 ] || return "$rc"
    dr_workflows_fallback_note "branch $name"
    dr_api_update_ref "refs/heads/$name" "$head" false
    dr_info "fast-forwarded branch $name to ${head:0:8} through the API"
  fi
  dr_set_output branch-updated true
}

# Version branch at the deployed commit (support/hotfix line). An existing
# branch is left alone — a re-run must not rewrite a release line — unless
# branch-update=fast-forward, which only ever moves it forward.
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
  dr_set_output branch-updated false

  if git ls-remote --exit-code --heads "$remote" "$name" > /dev/null 2>&1; then
    dr_set_output branch-created false
    if [ "${DR_BRANCH_UPDATE:-never}" = fast-forward ]; then
      dr_fast_forward_branch "$name"
    else
      dr_info "branch $name already exists on $remote — left as is."
    fi
    return 0
  fi
  if dr_git_push "HEAD:refs/heads/$name"; then
    dr_info "pushed branch $name"
  else
    local rc=$?
    [ "$rc" = 2 ] || return "$rc"
    dr_workflows_fallback_note "branch $name"
    dr_api_ref "refs/heads/$name" "$(git rev-parse HEAD)" false
    dr_info "created branch $name through the API"
  fi
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
    dr_set_output branch-updated false
  fi
}
