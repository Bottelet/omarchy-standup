#!/usr/bin/env bash
# Omarchy Standup engine.
#
# Collects git activity across a set of project roots and turns it into a short
# standup via the user's coding agent. Every command prints JSON on stdout so
# the QML side never has to parse prose; diagnostics go to stderr and the log.

set -uo pipefail

STATE_DIR="${OMARCHY_STANDUP_STATE:-$HOME/.local/share/omarchy-standup}"
ENTRIES_DIR="$STATE_DIR/entries"
INDEX_FILE="$STATE_DIR/index.json"
STATE_FILE="$STATE_DIR/state.json"
LOG_FILE="$STATE_DIR/standup.log"
LOCK_FILE="$STATE_DIR/.lock"

MENU_FILE="/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc"
DEFAULT_AGENT_BIN="omarchy-default-agent"

# Hard ceilings. The digest is prompt input, so it has to stay small enough to
# be cheap and to fit an argv-delivered prompt for agents without stdin input.
MAX_COMMITS_PER_REPO=40
MAX_COMMITS_TOTAL=300
MAX_SUBJECT_LEN=120
MAX_WINDOW_DAYS=14
AGENT_TIMEOUT="${OMARCHY_STANDUP_AGENT_TIMEOUT:-240}"
# A standup is a handful of lines. Anything past this is a wedged or hostile
# agent, and a command substitution has no size limit of its own.
MAX_AGENT_BYTES=65536
MAX_SCAN_BYTES=4000000
# State files are read on every status poll and every generate. They live in
# the user's own directory, but they are still files this script did not open
# with its own hands each time, so they get the same treatment as any other
# input: a bounded read that cannot be redirected by a swap.
MAX_INDEX_BYTES=1048576
MAX_STATE_BYTES=65536
MAX_ENTRY_BYTES=262144
# Remote collection. The search API caps a query at 1000 results and 100 per
# page; three pages is already far more commits than a standup can use, and it
# bounds a whole-org run that names no author.
MAX_REMOTE_PAGES=3
MAX_REMOTE_PER_PAGE=100
MAX_REMOTE_BYTES=2000000
# Per-call ceilings bound one request; these bound the whole run. A custom
# author list is a fan-out multiplier - one paginated search per author - so
# without a cap on the number of queries and on the bytes kept across them,
# "3 pages, 2 MB, 60s" is a per-call fact that says nothing about the total.
# One query per author is not a design choice but a constraint: GitHub honours
# only the first author-email: in a query and ignores the rest, so a team
# cannot be batched into one search. A hand-picked team of a dozen is ordinary,
# so the cap is set well above that and the wall-clock budget below is what
# actually bounds the work.
MAX_AUTHOR_QUERIES=20
# A ceiling on remote work for the whole process, not per call. Fan-out times
# pagination times GH_TIMEOUT is measured in tens of minutes, and the panel sits
# on `busy` with no timeout of its own for every second of it.
REMOTE_BUDGET_SECONDS="${OMARCHY_STANDUP_REMOTE_BUDGET:-120}"
MAX_REMOTE_TOTAL_BYTES=4000000
MAX_ORGS=10
MAX_ORG_REPO_LIST=200
GH_TIMEOUT="${OMARCHY_STANDUP_GH_TIMEOUT:-60}"
GH_BIN="${OMARCHY_STANDUP_GH_BIN:-gh}"

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG_FILE" 2>/dev/null; }

die() {
  log "ERROR: $*"
  jq -nc --arg e "$1" '{ok:false, error:$e}'
  exit 1
}

# Reads a file through exactly one descriptor, with a hard ceiling.
#
# The open uses O_NOFOLLOW so a symlink at the final component is refused
# outright, and O_NONBLOCK so a fifo cannot make the open hang. Type, owner and
# size are then read with fstat on that same descriptor, and the bytes come
# from that descriptor too. Nothing is ever looked up by pathname twice, so
# there is no window between checking and using: whatever was validated is
# exactly what is read.
#
# A symlinked config directory still works, since O_NOFOLLOW only governs the
# final component.
BOUNDED_READ_PY='
import os, stat, sys
path, cap, label = sys.argv[1], int(sys.argv[2]), sys.argv[3]

def refuse(reason):
    sys.stderr.write("%s refused: %s\n" % (label, reason))
    raise SystemExit(1)

try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError as e:
    refuse("cannot open (%s)" % e.strerror)
try:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        refuse("not a regular file")
    if st.st_uid != os.getuid():
        refuse("not owned by this user")
    if st.st_size > cap:
        refuse("larger than %d bytes" % cap)
    data = b""
    while len(data) <= cap:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        data += chunk
    if len(data) > cap:
        refuse("larger than %d bytes" % cap)
finally:
    os.close(fd)
sys.stdout.buffer.write(data)
'

read_bounded() { # read_bounded <path> <max-bytes>
  python3 -c "$BOUNDED_READ_PY" "$1" "$2" "$(basename "$1")" 2>>"$LOG_FILE"
}

# Replaces a file atomically without ever writing through a planted symlink.
# The temp name comes from mktemp rather than a guessable "<target>.tmp", which
# anything with write access to the directory could pre-create as a link.
write_atomic() { # write_atomic <path>   (content on stdin)
  local path=$1 dir tmp
  dir=$(dirname "$path")
  tmp=$(mktemp "$dir/.tmp.XXXXXXXX" 2>/dev/null) || return 1
  chmod 600 "$tmp" 2>/dev/null
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$path"
}

# A missing, refused or corrupt file reads as the empty document rather than
# taking the caller down with it.
read_index() {
  local raw
  raw=$(read_bounded "$INDEX_FILE" "$MAX_INDEX_BYTES") || raw=""
  printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1 ||
    raw='{"entries":[],"lastSeenTs":0}'
  printf '%s' "$raw"
}

read_state() {
  local raw
  raw=$(read_bounded "$STATE_FILE" "$MAX_STATE_BYTES") || raw=""
  printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1 ||
    raw='{"lastRunTs":0,"lastRunUntil":"","lastStatus":"","running":false}'
  printf '%s' "$raw"
}

ensure_dirs() {
  mkdir -p "$ENTRIES_DIR" || return 1
  # Commit subjects across every project the user works on: not a secret, but
  # not everyone-on-the-box readable either.
  chmod 700 "$STATE_DIR" 2>/dev/null
  [[ -f $INDEX_FILE ]] || printf '%s\n' '{"entries":[],"lastSeenTs":0}' | write_atomic "$INDEX_FILE"
  [[ -f $STATE_FILE ]] || printf '%s\n' '{"lastRunTs":0,"lastRunUntil":"","lastStatus":"","running":false}' | write_atomic "$STATE_FILE"
}

expand_home() {
  # Only a leading ~ is expanded; the rest is left verbatim so paths with odd
  # characters survive.
  local p=$1
  case "$p" in
  "~") printf '%s' "$HOME" ;;
  "~/"*) printf '%s/%s' "$HOME" "${p#\~/}" ;;
  *) printf '%s' "$p" ;;
  esac
}

# Roots arrive as one string so a single widget setting can hold them. Newline,
# comma and colon all separate, since every one of those is a habit somebody has.
split_roots() {
  local raw=$1
  # The trailing newline becomes the terminator for the final field; without it
  # read -d '' drops the last root on the floor.
  printf '%s\n' "$raw" | tr ',\n:' '\0\0\0' | while IFS= read -r -d '' item; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    # expand_home writes without a trailing newline so it can be used inline;
    # the caller reads line by line, so terminate each root here.
    [[ -n $item ]] && { expand_home "$item"; printf '\n'; }
  done
}

# Explicit repos and org names are split on comma and newline only. Colon has
# to survive: it is the separator in git@github.com:owner/repo.git.
split_list() {
  printf '%s\n' "$1" | tr ',\n' '\0\0' | while IFS= read -r -d '' item; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n $item ]] && { expand_home "$item"; printf '\n'; }
  done
}

# ------------------------------------------------------- explicit and remote

# Collapses every spelling of a GitHub repo - owner/name, an https clone URL,
# an ssh one - down to owner/name. Anything else is refused, because the result
# is interpolated into a search query and into argv.
remote_repo_slug() {
  local e=$1
  e=${e%/}
  e=${e%.git}
  # Peeled in fixed steps - scheme, then userinfo, then host - rather than
  # matched spelling by spelling, so the steps cannot interfere with each
  # other. user:token@ is a shape git itself emits; the credential is dropped
  # here and is never logged, stored or transmitted by this script.
  e=${e#https://}
  e=${e#http://}
  e=${e#git+ssh://}
  e=${e#ssh://}
  e=${e#*@}
  e=${e#github.com/}
  e=${e#github.com:}
  e=${e%/}
  e=${e%.git}
  [[ $e =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  printf '%s' "$e"
}

valid_org() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]
}

# An explicit entry is either a checkout on this disk or a repo on GitHub.
# A directory that exists wins: a local clone has the full history, and the
# API only ever sees what was pushed.
# A rejected entry is never echoed. `https://<token>@github.com/o/r` is a
# spelling git itself emits and CI docs recommend, it is rejected here, and
# writing it to the log would persist a credential in plaintext for good.
declare -a EXPLICIT_LOCAL=() EXPLICIT_REMOTE=()
classify_explicit() {
  EXPLICIT_LOCAL=()
  EXPLICIT_REMOTE=()
  local e slug
  while IFS= read -r e; do
    [[ -n $e ]] || continue
    # A path and a repo slug are decided by shape, not by what happens to exist
    # right now. Anything anchored - absolute, or explicitly ./ or ../ - is a
    # path and stays on this machine even when it is missing; anything else can
    # only ever be owner/name. Without that split a mistyped relative path
    # silently becomes a search query sent to github.com, so whether a private
    # project name leaves the machine would depend on the caller's cwd.
    if [[ $e == /* || $e == ./* || $e == ../* ]]; then
      if [[ -d $e ]]; then
        EXPLICIT_LOCAL+=("$e")
      else
        log "ignoring repo entry: path does not exist (${#e} chars)"
      fi
    elif slug=$(remote_repo_slug "$e"); then
      EXPLICIT_REMOTE+=("$slug")
    else
      log "ignoring unusable repo entry: not a path or owner/name (${#e} chars)"
    fi
  done < <(split_list "$1")
}

declare -a ORG_LIST=()
classify_orgs() {
  ORG_LIST=()
  local o
  while IFS= read -r o; do
    [[ -n $o ]] || continue
    o=${o#@}
    if ! valid_org "$o"; then
      log "ignoring unusable org name (${#o} chars)"
    elif ((${#ORG_LIST[@]} >= MAX_ORGS)); then
      log "ignoring org beyond the first $MAX_ORGS"
    else
      ORG_LIST+=("$o")
    fi
  done < <(split_list "$1")
}

# ---------------------------------------------------------------- repo scan

# Prints "commondir<TAB>worktree" for every git checkout found under the roots.
# The common dir is what makes 20 sibling worktrees of one repo collapse into
# one logical project instead of 20 duplicated standup lines.
scan_repos() {
  local depth=$1 root
  shift
  for root in "$@"; do
    [[ -d $root ]] || continue
    if [[ -e $root/.git ]]; then
      emit_repo "$root"
      continue
    fi
    while IFS= read -r gitpath; do
      emit_repo "${gitpath%/.git}"
    done < <(find "$root" -mindepth 2 -maxdepth $((depth + 1)) \
      \( -name node_modules -o -name vendor -o -name .cache -o -name target -o -name dist \) -prune -o \
      -name .git -print 2>/dev/null)
  done
}

# Explicit paths skip the find walk entirely: the user named this directory, so
# it is used as given rather than searched underneath.
explicit_repos() {
  local dir
  for dir in "$@"; do
    [[ -d $dir ]] || continue
    emit_repo "$dir"
  done
}

emit_repo() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  [[ -n $common ]] || return 0
  common=$(readlink -f "$common" 2>/dev/null || printf '%s' "$common")
  printf '%s\t%s\n' "$common" "$dir"
}

# One line per logical repo: the shortest path wins, which is the main checkout
# rather than a wt-* sibling.
unique_repos() {
  awk -F'\t' '{ if (!(($1) in best) || length($2) < length(best[$1])) best[$1]=$2 }
              END { for (k in best) print best[k] }' | sort
}

# ------------------------------------------------------------------ authors

my_emails() {
  local e
  e=$(git config --global user.email 2>/dev/null)
  [[ -n $e ]] && printf '%s\n' "$e"
  # Repo-local identities matter: work repos often carry a company address that
  # the global config never mentions.
  local d
  while IFS= read -r d; do
    e=$(git -C "$d" config --local user.email 2>/dev/null)
    [[ -n $e ]] && printf '%s\n' "$e"
  done
  printf '%s\n' "${OMARCHY_STANDUP_EXTRA_EMAILS:-}" | tr ',' '\n'
}

# -------------------------------------------------------------- remote (API)

# Remote collection is best-effort by design: a missing gh, an expired token or
# a rate limit must degrade to "local repos only", never take the run down.
# Both answers are cached for the life of the process. cmd_generate calls
# collect_json twice whenever the since-last-standup window comes back empty,
# which is the common case, and without this each of these would be paid twice.
GH_READY_CACHE=""
gh_ready() {
  if [[ -z $GH_READY_CACHE ]]; then
    if command -v "$GH_BIN" >/dev/null 2>&1 &&
      timeout "$GH_TIMEOUT" "$GH_BIN" auth status >/dev/null 2>&1; then
      GH_READY_CACHE=yes
    else
      GH_READY_CACHE=no
    fi
  fi
  [[ $GH_READY_CACHE == yes ]]
}

GH_LOGIN_CACHE=""
GH_LOGIN_DONE=""
gh_login() {
  if [[ -z $GH_LOGIN_DONE ]]; then
    GH_LOGIN_DONE=yes
    GH_LOGIN_CACHE=$(timeout "$GH_TIMEOUT" "$GH_BIN" api user --jq '.login' 2>/dev/null)
    [[ $GH_LOGIN_CACHE =~ ^[A-Za-z0-9-]+$ ]] || GH_LOGIN_CACHE=""
  fi
  printf '%s' "$GH_LOGIN_CACHE"
}

# One line per search to run. GitHub ANDs qualifiers of different kinds, so
# `author:me author-email:me@example.com` matches only the commits that satisfy
# both and silently loses the rest; same-kind OR is not documented firmly
# enough to lean on either. One query per author value avoids the whole
# question, and the default case is a single query.
#
# A blank line means "no author qualifier", which is what author-mode `all`
# wants. No lines at all means there is nobody to search for.
remote_author_queries() {
  local author_mode=$1 authors_raw=$2 login=$3 me_emails=$4 a any=false
  if [[ $author_mode == all ]]; then
    printf '\n'
    return
  fi
  if [[ $author_mode == custom ]]; then
    while IFS= read -r a; do
      a="${a#"${a%%[![:space:]]*}"}"
      a="${a%"${a##*[![:space:]]}"}"
      [[ -n $a ]] || continue
      if [[ $a =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+$ ]]; then
        printf 'author-email:%s\n' "$a"
        any=true
      elif [[ $a =~ ^[A-Za-z0-9-]+$ ]]; then
        printf 'author:%s\n' "$a"
        any=true
      else
        log "author '$a' is not usable as a GitHub search term"
      fi
    done < <(printf '%s\n' "$authors_raw" | tr ',' '\n' | sort -u)
    # Whether or not anything was usable, a custom list is answered only with
    # the people it named. Falling through to the `me` branch here would search
    # for the current user and then present the result under authorMode
    # "custom" - your own commits, attributed to the people you asked about.
    return
  fi
  # author-mode `me`. Local collection matches on every identity the user
  # commits under, including per-repo work addresses; the remote side has to
  # cover the same set or an org would silently miss work the local scan finds.
  {
    [[ -n $login ]] && printf 'author:%s\n' "$login"
    while IFS= read -r a; do
      [[ -n $a ]] || continue
      [[ $a =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] && printf 'author-email:%s\n' "$a"
    done <<<"$me_emails"
  } | sort -u
}

# Streams one compact JSON object per matching commit. Projecting with --jq at
# the call site keeps a page of search results from arriving as a megabyte of
# fields nothing reads.
REMOTE_DEADLINE=0
remote_budget_left() {
  ((REMOTE_DEADLINE == 0)) && REMOTE_DEADLINE=$(($(date +%s) + REMOTE_BUDGET_SECONDS))
  (($(date +%s) < REMOTE_DEADLINE))
}

gh_search_stream() {
  local scope=$1 author_q=$2 page=1 out n
  # SINCE_ISO can come from --since, where anything `date -d` parses is allowed
  # - including values carrying spaces, which would land in the query as stray
  # free-text terms rather than as a date range.
  if [[ ! $SINCE_ISO =~ ^[0-9T:+-]+$ || ! $UNTIL_ISO =~ ^[0-9T:+-]+$ ]]; then
    log "window is not a plain ISO range; skipping remote collection"
    return 0
  fi
  while ((page <= MAX_REMOTE_PAGES)); do
    remote_budget_left || {
      log "remote time budget of ${REMOTE_BUDGET_SECONDS}s exhausted"
      break
    }
    out=$(timeout "$GH_TIMEOUT" "$GH_BIN" api -X GET search/commits \
      -f q="$scope $author_q author-date:$SINCE_ISO..$UNTIL_ISO" \
      -f sort=author-date -f order=desc \
      -f per_page="$MAX_REMOTE_PER_PAGE" -f page="$page" \
      --jq '.items[] | {sha:.sha, repo:(.repository.full_name // ""),
                        an:(.commit.author.name // ""), ae:(.commit.author.email // ""),
                        d:(.commit.author.date // ""),
                        s:((.commit.message // "") | split("\n")[0])}' \
      2>/dev/null | head -c "$MAX_REMOTE_BYTES")
    [[ -n $out ]] || break
    printf '%s\n' "$out"
    n=$(printf '%s\n' "$out" | grep -c '^{')
    ((n < MAX_REMOTE_PER_PAGE)) && break
    page=$((page + 1))
    # Still a full page on the way out of the loop means the cap stopped us,
    # not the data running out. gh_search_stream runs in a command
    # substitution, so this cannot be reported through a variable.
    ((page > MAX_REMOTE_PAGES)) && printf '{"__page_cap__":true}\n'
  done
}

# Groups the commit stream into repo entries shaped exactly like the ones the
# local scan produces, dropping every commit already reported from a clone on
# this disk so a cloned org repo is not counted twice.
REMOTE_JSON="[]"
REMOTE_WARNING=""
REMOTE_TRUNCATED=false
collect_remote() {
  local author_mode=$1 authors_raw=$2 local_shas=$3 me_emails=${4:-}
  REMOTE_JSON="[]"
  REMOTE_WARNING=""
  REMOTE_TRUNCATED=false

  local -a scope=()
  local o r
  for o in ${ORG_LIST[@]+"${ORG_LIST[@]}"}; do scope+=("org:$o"); done
  for r in ${EXPLICIT_REMOTE[@]+"${EXPLICIT_REMOTE[@]}"}; do scope+=("repo:$r"); done
  ((${#scope[@]})) || return 0

  if ! gh_ready; then
    REMOTE_WARNING="GitHub not reachable (gh missing or not logged in) - used local repos only"
    log "$REMOTE_WARNING"
    return 0
  fi

  # Resolved here rather than inside the loop below: that loop reads from a
  # process substitution, and a cache populated in that subshell dies with it.
  local login=""
  login=$(gh_login)

  local stream="" aq chunk ran=false queries=0
  while IFS= read -r aq; do
    if ((queries >= MAX_AUTHOR_QUERIES)); then
      # Dropping people silently would under-report their work as "no commits".
      REMOTE_WARNING="only the first $MAX_AUTHOR_QUERIES selected authors were searched on GitHub"
      log "$REMOTE_WARNING"
      break
    fi
    queries=$((queries + 1))
    ran=true
    chunk=$(gh_search_stream "${scope[*]}" "$aq")
    [[ -n $chunk ]] && stream+="$chunk"$'\n'
    if ((${#stream} > MAX_REMOTE_TOTAL_BYTES)); then
      REMOTE_WARNING="remote results hit the size ceiling; some authors were not searched"
      REMOTE_TRUNCATED=true
      log "$REMOTE_WARNING"
      break
    fi
  done < <(remote_author_queries "$author_mode" "$authors_raw" "$login" "$me_emails")

  if [[ $ran == false ]]; then
    if [[ $author_mode == custom ]]; then
      REMOTE_WARNING="none of the selected authors could be searched for on GitHub - org and remote repos were skipped"
    else
      REMOTE_WARNING="no GitHub identity to search for - set a git email or log in with gh"
    fi
    log "$REMOTE_WARNING"
    return 0
  fi

  [[ $stream == *'"__page_cap__"'* ]] && REMOTE_TRUNCATED=true

  REMOTE_JSON=$(printf '%s' "$stream" |
    LOCAL_SHAS="$local_shas" LIMIT=$MAX_COMMITS_PER_REPO SUBJ=$MAX_SUBJECT_LEN python3 -c '
import collections, json, os, sys
limit = int(os.environ["LIMIT"]); subj = int(os.environ["SUBJ"])
local = {l.strip().lower() for l in os.environ.get("LOCAL_SHAS", "").split("\n") if l.strip()}
repos, seen = collections.OrderedDict(), set()
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        c = json.loads(line)
    except ValueError:
        continue
    sha = str(c.get("sha") or "")
    full = str(c.get("repo") or "")
    # A commit already found in a clone on this disk is the same work; the
    # local copy wins because it carries the branch it sits on.
    if not sha or not full or sha.lower() in local or sha in seen:
        continue
    seen.add(sha)
    e = repos.setdefault(full, {"name": full.split("/")[-1], "path": full, "slug": full,
                                "source": "github", "branch": "", "commits": []})
    if len(e["commits"]) >= limit:
        continue
    e["commits"].append({"h": sha[:8], "an": str(c.get("an") or "")[:60],
                         "ae": str(c.get("ae") or "")[:80],
                         "d": str(c.get("d") or "")[:16].replace("T", " "),
                         "s": str(c.get("s") or "")[:subj]})
json.dump([e for e in repos.values() if e["commits"]], sys.stdout, ensure_ascii=False)
' 2>/dev/null)
  printf '%s' "$REMOTE_JSON" | jq -e 'type == "array"' >/dev/null 2>&1 || REMOTE_JSON="[]"
}

# Folds the remote entries into the local ones. A repo that exists both as a
# clone and on GitHub stays one line in the standup.
#
# The whole-digest commit budget is spent here, not only the per-repo one. The
# local walk stops at MAX_COMMITS_TOTAL on its own, so without carrying that
# budget across the append path an organization would add its own full quota on
# top and the prompt would be twice the size the cap exists to guarantee.
# Reports the totals it actually produced rather than leaving the caller to
# recount, since the caller cannot see where the budget ran out.
merge_repos() { # merge_repos <local-json> <remote-json>
  LIMIT=$MAX_COMMITS_PER_REPO TOTAL=$MAX_COMMITS_TOTAL python3 -c '
import json, os, sys
limit = int(os.environ["LIMIT"]); cap = int(os.environ["TOTAL"])
local = json.loads(sys.argv[1]); remote = json.loads(sys.argv[2])
by_slug = {}
for e in local:
    slug = str(e.get("slug") or "").lower()
    if slug:
        by_slug.setdefault(slug, e)
out = list(local)
total = sum(len(e["commits"]) for e in local)
truncated = False
for r in remote:
    if total >= cap:
        truncated = True
        break
    target = by_slug.get(str(r.get("slug") or "").lower())
    if target is None:
        room = min(len(r["commits"]), cap - total)
        if room < len(r["commits"]):
            truncated = True
        r["commits"] = r["commits"][:room]
        if r["commits"]:
            out.append(r)
            total += room
        continue
    room = min(limit - len(target["commits"]), cap - total)
    if room > 0:
        target["commits"].extend(r["commits"][:room])
        target["source"] = "local+github"
        total += min(room, len(r["commits"]))
    if room < len(r["commits"]):
        truncated = True
json.dump({"repos": [e for e in out if e["commits"]], "total": total,
           "truncated": truncated}, sys.stdout, ensure_ascii=False)
' "$1" "$2"
}

# --------------------------------------------------------------- collection


# Sets SINCE_ISO / UNTIL_ISO for this run.
resolve_window() {
  local mode=$1 days=$2 explicit=$3
  UNTIL_ISO=$(date -Is)
  if [[ -n $explicit ]]; then
    SINCE_ISO=$explicit
    return
  fi
  local floor
  floor=$(date -Is -d "$MAX_WINDOW_DAYS days ago")
  if [[ $mode == auto ]]; then
    local last=""
    last=$(read_state | jq -r '.lastRunUntil // ""' 2>/dev/null)
    if [[ -n $last && $last != null ]]; then
      # Clamp: coming back from two weeks off should not dump a fortnight of
      # commits into a standup meant to be read in ten seconds.
      if [[ $last < $floor ]]; then SINCE_ISO=$floor; else SINCE_ISO=$last; fi
      return
    fi
  fi
  SINCE_ISO=$(date -Is -d "$days days ago")
}

# git's approxidate silently ignores a date it cannot represent - a year past
# 2100, say - and then quietly returns every commit ever made, which would turn
# a standup into the whole history. Any window that git cannot be trusted with
# is replaced by the plain N-days-ago one.
#
# A window that merely starts in the future needs no special handling: git
# honours those and returns nothing, which is the right answer.
clamp_window() {
  local days=$1 since_epoch
  since_epoch=$(date -d "$SINCE_ISO" +%s 2>/dev/null)
  if [[ -z $since_epoch ]] || ((since_epoch > 4102444800 || since_epoch < 0)); then
    SINCE_ISO=$(date -Is -d "$days days ago")
  fi
  date -d "$UNTIL_ISO" +%s >/dev/null 2>&1 || UNTIL_ISO=$(date -Is)
}

collect_json() {
  local roots_raw=$1 depth=$2 mode=$3 days=$4 explicit=$5 author_mode=$6 authors_raw=$7
  local repos_raw=${8:-} orgs_raw=${9:-}

  local -a roots=()
  while IFS= read -r r; do [[ -n $r ]] && roots+=("$r"); done < <(split_roots "$roots_raw")
  classify_explicit "$repos_raw"
  classify_orgs "$orgs_raw"

  # Any one of the three sources is enough. Only a run with nothing at all
  # pointed at it is a misconfiguration.
  ((${#roots[@]} + ${#EXPLICIT_LOCAL[@]} + ${#EXPLICIT_REMOTE[@]} + ${#ORG_LIST[@]})) ||
    die "no project folders, repos or organizations configured"

  local -a repos=()
  while IFS= read -r r; do [[ -n $r ]] && repos+=("$r"); done < <(
    {
      ((${#roots[@]})) && scan_repos "$depth" "${roots[@]}"
      ((${#EXPLICIT_LOCAL[@]})) && explicit_repos "${EXPLICIT_LOCAL[@]}"
    } | unique_repos
  )

  resolve_window "$mode" "$days" "$explicit"
  clamp_window "$days"

  local -a author_args=()
  if [[ $author_mode == custom ]]; then
    local a
    while IFS= read -r a; do
      a="${a#"${a%%[![:space:]]*}"}"
      a="${a%"${a##*[![:space:]]}"}"
      [[ -n $a ]] && author_args+=(--author="$a")
    done < <(printf '%s\n' "$authors_raw" | tr ',' '\n')
    # A custom filter that names nobody would match nothing at all, which reads
    # as "you did no work" rather than as a misconfiguration. Fall back to the
    # user's own identities instead.
    ((${#author_args[@]})) || author_mode=me
  fi
  local me_emails=""
  if [[ $author_mode == me ]]; then
    local e
    me_emails=$(printf '%s\n' ${repos[@]+"${repos[@]}"} | my_emails | sort -u)
    while IFS= read -r e; do
      [[ -n $e ]] && author_args+=(--author="$e")
    done <<<"$me_emails"
    # No git identity configured anywhere: the login name is the last clue left.
    ((${#author_args[@]})) || author_args=(--author="$(whoami)")
  fi

  local total=0 truncated=false
  local repos_json="[]" dir
  # Full hashes of everything found locally, so the same commit arriving from
  # the API can be recognised and dropped.
  local local_shas=""
  for dir in ${repos[@]+"${repos[@]}"}; do
    ((total >= MAX_COMMITS_TOTAL)) && {
      truncated=true
      break
    }
    local branch
    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    [[ $branch == HEAD ]] && branch="(detached)"

    local raw
    raw=$(git -C "$dir" log --all --no-merges --regexp-ignore-case \
      --since="$SINCE_ISO" --until="$UNTIL_ISO" \
      "${author_args[@]}" \
      --date=format:'%Y-%m-%d %H:%M' \
      --pretty=format:'%H%x1f%an%x1f%ae%x1f%ad%x1f%s%x1e' 2>/dev/null |
      head -c 200000)
    [[ -n $raw ]] || continue

    local commits_json
    commits_json=$(printf '%s' "$raw" | LIMIT=$MAX_COMMITS_PER_REPO SUBJ=$MAX_SUBJECT_LEN python3 -c '
import json, os, sys
raw = sys.stdin.buffer.read().decode("utf-8", "replace")
limit = int(os.environ["LIMIT"]); subj = int(os.environ["SUBJ"])
out, seen = [], set()
for rec in raw.split("\x1e"):
    rec = rec.strip("\n")
    if not rec:
        continue
    f = rec.split("\x1f")
    if len(f) < 5:
        continue
    h, an, ae, ad, s = f[0], f[1], f[2], f[3], f[4]
    # --all walks every ref, so a commit on both a local branch and its remote
    # shows up twice. Keyed on the sha, not the subject: rebases are new work.
    if h in seen:
        continue
    seen.add(h)
    out.append({"h": h[:8], "an": an[:60], "ae": ae[:80], "d": ad, "s": s[:subj]})
    if len(out) >= limit:
        break
json.dump(out, sys.stdout, ensure_ascii=False)
' 2>/dev/null)
    [[ -n $commits_json ]] || continue

    local n
    n=$(printf '%s' "$commits_json" | jq 'length')
    ((n == 0)) && continue
    total=$((total + n))
    # Every hash in the window, not just the ones that made the per-repo cut:
    # a commit trimmed here is still one the API copy should not re-report.
    local_shas+=$(printf '%s' "$raw" | tr '\036' '\n' | cut -d$'\037' -f1)$'\n'

    # The origin slug is what lets a clone and its GitHub counterpart collapse
    # into one project instead of appearing twice.
    local slug=""
    slug=$(remote_repo_slug "$(git -C "$dir" remote get-url origin 2>/dev/null)" 2>/dev/null) || slug=""

    repos_json=$(jq -c --arg name "$(basename "$dir")" --arg path "$dir" --arg branch "$branch" \
      --arg slug "$slug" --argjson commits "$commits_json" \
      '. + [{name:$name, path:$path, branch:$branch, slug:$slug, source:"local", commits:$commits}]' <<<"$repos_json")
  done

  collect_remote "$author_mode" "$authors_raw" "$local_shas" "$me_emails"
  [[ $REMOTE_TRUNCATED == true ]] && truncated=true
  if [[ $REMOTE_JSON != "[]" ]]; then
    local merged
    merged=$(merge_repos "$repos_json" "$REMOTE_JSON" 2>/dev/null)
    if printf '%s' "$merged" | jq -e '(type == "object") and (.repos | type == "array")' >/dev/null 2>&1; then
      repos_json=$(jq -c '.repos' <<<"$merged")
      total=$(jq -r '.total' <<<"$merged")
      [[ $(jq -r '.truncated' <<<"$merged") == true ]] && truncated=true
    fi
  fi

  local warnings="[]"
  [[ -n $REMOTE_WARNING ]] && warnings=$(jq -nc --arg w "$REMOTE_WARNING" '[$w]')

  local orgs_json="[]"
  ((${#ORG_LIST[@]})) && orgs_json=$(printf '%s\n' "${ORG_LIST[@]}" | jq -Rnc '[inputs | select(length > 0)]')

  jq -nc --arg since "$SINCE_ISO" --arg until "$UNTIL_ISO" --arg mode "$author_mode" \
    --argjson repos "$repos_json" --argjson total "$total" --argjson trunc "$truncated" \
    --argjson warnings "$warnings" --argjson orgs "$orgs_json" \
    '{ok:true, since:$since, until:$until, authorMode:$mode, repoCount:($repos|length),
      commitCount:$total, truncated:$trunc, orgs:$orgs, warnings:$warnings, repos:$repos}'
}

# ------------------------------------------------------------------- agents

# Omarchy has no `agent list` command; the arg spec on omarchy-default-agent is
# the authoritative set, and the menu file carries the display labels. Both are
# read at runtime so a new agent in Omarchy shows up here without a release.
agent_ids() {
  local spec=""
  if command -v "$DEFAULT_AGENT_BIN" >/dev/null 2>&1; then
    spec=$(grep -oP '^# omarchy:args=\[\K[^]]+' "$(command -v "$DEFAULT_AGENT_BIN")" 2>/dev/null)
  fi
  if [[ -z $spec && -f $MENU_FILE ]]; then
    spec=$(grep -oP '"setup\.default\.agent\.\K[a-z0-9-]+' "$MENU_FILE" 2>/dev/null | tr '\n' '|')
  fi
  [[ -z $spec ]] && spec="claude|codex|gemini|opencode|crush|copilot|grok|pi|omp"
  # Ids are interpolated into a grep pattern and into argv, so only the shape
  # Omarchy actually uses is allowed through.
  printf '%s' "$spec" | tr '|' '\n' | grep -xE '[a-z][a-z0-9-]*' | sort -u
}

agent_label() {
  local id=$1 label=""
  if [[ -f $MENU_FILE ]]; then
    label=$(grep -oP "\"setup\.default\.agent\.$id\":.*?\"label\":\"\K[^\"]+" "$MENU_FILE" 2>/dev/null | head -1)
  fi
  [[ -n $label ]] || label="$id"
  printf '%s' "$label"
}

cmd_agents() {
  local default_id="" id out="[]"
  command -v "$DEFAULT_AGENT_BIN" >/dev/null 2>&1 && default_id=$("$DEFAULT_AGENT_BIN" 2>/dev/null)
  while IFS= read -r id; do
    local avail=false
    command -v "$id" >/dev/null 2>&1 && avail=true
    out=$(jq -c --arg id "$id" --arg label "$(agent_label "$id")" --argjson avail "$avail" \
      '. + [{id:$id, label:$label, available:$avail}]' <<<"$out")
  done < <(agent_ids)
  jq -nc --arg def "$default_id" --argjson agents "$out" \
    '{ok:true, defaultAgent:$def, agents:$agents}'
}

# Builds the argv for a headless run. The prompt goes on stdin where the CLI
# supports it, because a digest can outgrow a comfortable argv.
#
# Where the CLI can be told to run without tools or write access, it is: the
# prompt carries commit subjects from every repo in scope, and those are
# attacker-controlled in any repo the user merely cloned. Agents with no such
# switch (opencode, copilot, pi, omp, grok) run with their own defaults - the
# README says so.
declare -a AGENT_CMD=()
AGENT_STDIN=false
build_agent_cmd() {
  local agent=$1 custom=$2 prompt_len=$3
  AGENT_CMD=()
  AGENT_STDIN=false
  case "$agent" in
  custom)
    [[ -n $custom ]] || return 1
    # Deliberately word-split: this is a user-authored command line, and it is
    # only ever run with the prompt on stdin, never with interpolated content.
    read -r -a AGENT_CMD <<<"$custom"
    AGENT_STDIN=true
    ;;
  claude)
    # No tools: the digest is already in the prompt, and commit subjects are
    # attacker-controlled text in any repo you did not write yourself. A model
    # with a shell is a model that can be talked into using it.
    AGENT_CMD=(claude -p --output-format text --tools "")
    AGENT_STDIN=true
    ;;
  codex)
    AGENT_CMD=(codex exec --skip-git-repo-check --sandbox read-only -)
    AGENT_STDIN=true
    ;;
  crush)
    AGENT_CMD=(crush run)
    AGENT_STDIN=true
    ;;
  gemini)
    AGENT_CMD=(gemini -o text --approval-mode plan -p "@@PROMPT@@")
    ;;
  opencode)
    AGENT_CMD=(opencode run "@@PROMPT@@")
    ;;
  copilot)
    AGENT_CMD=(copilot -p "@@PROMPT@@")
    ;;
  grok)
    AGENT_CMD=(grok -p "@@PROMPT@@")
    ;;
  pi)
    AGENT_CMD=(pi "@@PROMPT@@")
    ;;
  omp)
    AGENT_CMD=(omp -- "@@PROMPT@@")
    ;;
  *) return 1 ;;
  esac
  # Argv-delivered prompts have a hard kernel limit and fail silently past it.
  if [[ $AGENT_STDIN == false ]] && ((prompt_len > 100000)); then
    return 2
  fi
  return 0
}

run_agent() {
  local agent=$1 custom=$2 prompt=$3
  build_agent_cmd "$agent" "$custom" "${#prompt}"
  local rc=$?
  ((rc == 1)) && {
    log "agent '$agent' unsupported or custom command empty"
    return 1
  }
  ((rc == 2)) && {
    log "prompt too large for argv delivery to '$agent'"
    return 1
  }

  local -a cmd=()
  local part
  for part in "${AGENT_CMD[@]}"; do
    [[ $part == "@@PROMPT@@" ]] && part=$prompt
    cmd+=("$part")
  done

  # A neutral working directory keeps the agent away from project rules files
  # and from anything it might decide to edit.
  local workdir="$STATE_DIR/run"
  mkdir -p "$workdir"

  local out
  if [[ $AGENT_STDIN == true ]]; then
    out=$(printf '%s' "$prompt" | (cd "$workdir" && NO_COLOR=1 timeout "$AGENT_TIMEOUT" "${cmd[@]}" 2>>"$LOG_FILE") | head -c "$MAX_AGENT_BYTES")
  else
    out=$(cd "$workdir" && NO_COLOR=1 timeout "$AGENT_TIMEOUT" "${cmd[@]}" </dev/null 2>>"$LOG_FILE" | head -c "$MAX_AGENT_BYTES")
  fi
  rc=${PIPESTATUS[0]}
  if ((rc != 0)); then
    log "agent '$agent' exited $rc"
    [[ -n $out ]] || return 1
  fi
  printf '%s' "$out"
}

# ------------------------------------------------------------------ prompting

digest_markdown() {
  jq -r '
    .repos[] |
    "## " + .name + (if (.branch // "") == "" then "" else " (" + .branch + ")" end),
    (.commits[] | "- " + .d + " [" + .an + "] " + .s),
    ""
  ' <<<"$1"
}

DEFAULT_FORMAT="A flat bullet list. One line per bullet, plain past tense."

build_prompt() {
  local digest=$1 max_bullets=$2 author_mode=$3 format_text=$4 author_count=${5:-1}
  # A hand-picked list of several people is a team standup exactly as much as
  # "everyone" is. Describing it as "the developer" told the model to write
  # about one person, and it obeyed - folding a whole team's work under
  # whichever name had committed most and dropping the rest.
  local who="the developer"
  if [[ $author_mode == all ]] || { [[ $author_mode == custom ]] && ((author_count > 1)); }; then
    who="the team"
  fi
  [[ -n $format_text ]] || format_text=$DEFAULT_FORMAT
  cat <<PROMPT
Write a daily standup update for $who from the git activity below.

Shape of the update:
$format_text

Rules:
- Put the finished update between <standup> and </standup>, and write nothing outside those tags.
- Keep it short: at most $max_bullets bullets.
- Under 16 words per line. Plain language.
- Group related commits together. Never list commits one by one.
- Name the project when more than one project appears.
- Say what changed and why it matters, not which files moved.
- Never invent work that is not in the data below.

Git activity:

$digest
PROMPT
}

# Agents wrap their answer in greetings and code fences no matter how firmly
# they are asked not to. The <standup> tags give the update an unambiguous
# boundary, which is what lets any output shape through - a bullet list, a
# grouped list, a paragraph - instead of only lines starting with "- ".
#
# Everything outside the tags is dropped. Output with no tags at all (a model
# that ignored the instruction) is still stripped of ANSI and fences and capped,
# so a chatty answer is untidy rather than unusable.
MAX_OUTPUT_LINES=40

sanitize_output() {
  sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\r$//' |
    python3 -c '
import re, sys
text = sys.stdin.read()
m = re.search(r"<standup>(.*?)</standup>", text, re.S | re.I)
if m:
    text = m.group(1)
lines = [ln.rstrip() for ln in text.split("\n") if not ln.strip().startswith("```")]
while lines and not lines[0].strip():
    lines.pop(0)
while lines and not lines[-1].strip():
    lines.pop()
sys.stdout.write("\n".join(lines[:int(sys.argv[1])]))
' "$MAX_OUTPUT_LINES"
}

fallback_bullets() {
  local digest=$1 max=$2
  jq -r --argjson max "$max" '
    [ .repos[] | {name, n: (.commits|length), top: (.commits[0].s // "")} ]
    | sort_by(-.n) | .[:$max]
    | .[] | "- " + .name + ": " + (.n|tostring) + " commit" + (if .n == 1 then "" else "s" end)
            + (if .top == "" then "" else " - " + .top end)
  ' <<<"$digest"
}

# ----------------------------------------------------------------- generate

cmd_generate() {
  local roots="" depth=2 mode=auto days=1 explicit="" author_mode=me authors=""
  local repos_opt="" orgs_opt=""
  local agent=default custom="" max_bullets=5 force=false format_text=""
  while (($#)); do
    case "$1" in
    --roots) roots=$2; shift 2 ;;
    --repos) repos_opt=$2; shift 2 ;;
    --orgs) orgs_opt=$2; shift 2 ;;
    --depth) depth=$2; shift 2 ;;
    --window) mode=$2; shift 2 ;;
    --days) days=$2; shift 2 ;;
    --since) explicit=$2; shift 2 ;;
    --author-mode) author_mode=$2; shift 2 ;;
    --authors) authors=$2; shift 2 ;;
    --agent) agent=$2; shift 2 ;;
    --custom-command) custom=$2; shift 2 ;;
    --max-bullets) max_bullets=$2; shift 2 ;;
    --format-text) format_text=$2; shift 2 ;;
    --force) force=true; shift ;;
    *) shift ;;
    esac
  done

  ensure_dirs || die "cannot create $STATE_DIR"

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    die "a standup is already being generated"
  fi

  # Whatever ends this run early - a die, a signal, a shell that tears the
  # process down - must not leave "running" set, or the panel wedges on a
  # spinner and never starts another run. Only a signal that kills the
  # process outright escapes this; reconcile_running covers that case.
  GENERATE_FINISHED=false
  trap '[[ $GENERATE_FINISHED == true ]] || mark_interrupted' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  read_state | jq -c '.running = true | .lastStatus = "collecting"' | write_atomic "$STATE_FILE"

  local digest
  digest=$(collect_json "$roots" "$depth" "$mode" "$days" "$explicit" "$author_mode" "$authors" "$repos_opt" "$orgs_opt")
  if [[ $(jq -r '.ok' <<<"$digest" 2>/dev/null) != true ]]; then
    finish_state "error"
    printf '%s\n' "$digest"
    return 1
  fi

  local count widened=false
  count=$(jq -r '.commitCount' <<<"$digest")

  # Every run moves the "since the last standup" cursor to now, so a second
  # press of Generate now would otherwise always land on an empty window and
  # report nothing - which reads as a broken button. When the cursor window is
  # empty, fall back to the plain N-day window so a manual run still shows the
  # work that is actually there.
  if ((count == 0)) && [[ $mode == auto && -z $explicit ]]; then
    local wide
    wide=$(collect_json "$roots" "$depth" fixed "$days" "" "$author_mode" "$authors" "$repos_opt" "$orgs_opt")
    if [[ $(jq -r '.ok' <<<"$wide" 2>/dev/null) == true ]] && (($(jq -r '.commitCount' <<<"$wide") > 0)); then
      digest=$wide
      count=$(jq -r '.commitCount' <<<"$digest")
      widened=true
      # collect_json reset the window while building the wider digest; keep the
      # cursor at the wider run's end so the next standup starts from here.
      SINCE_ISO=$(jq -r '.since' <<<"$digest")
      UNTIL_ISO=$(jq -r '.until' <<<"$digest")
    fi
  fi

  if ((count == 0)) && [[ $force == false ]]; then
    # Nothing happened in the window. Recording the run anyway keeps the auto
    # window moving forward instead of re-scanning the same empty span forever.
    finish_state "empty"
    jq -nc --argjson d "$digest" --argjson w "$(jq -c '.warnings // []' <<<"$digest")" \
      '{ok:true, generated:false, reason:"no commits", warnings:$w, digest:$d}'
    return 0
  fi

  local resolved=$agent
  if [[ $agent == default ]]; then
    resolved=$(command -v "$DEFAULT_AGENT_BIN" >/dev/null 2>&1 && "$DEFAULT_AGENT_BIN" 2>/dev/null)
    [[ -n $resolved ]] || resolved=""
  fi

  read_state | jq -c '.lastStatus = "generating"' | write_atomic "$STATE_FILE"

  local body="" used_fallback=false
  if ((count == 0)); then
    # Forced run over an empty window. "Nothing to report" is a legitimate
    # standup; handing an empty digest to a model only invites invention.
    body="- No commits in this window."
    resolved="none"
  elif [[ -n $resolved ]]; then
    local prompt
    local author_count=1
    [[ $author_mode == custom ]] &&
      author_count=$(printf '%s\n' "$authors" | tr ',' '\n' | sed '/^[[:space:]]*$/d' | wc -l)
    prompt=$(build_prompt "$(digest_markdown "$digest")" "$max_bullets" "$author_mode" \
      "$format_text" "$author_count")
    body=$(run_agent "$resolved" "$custom" "$prompt" | sanitize_output)
  fi
  if [[ -z $body ]]; then
    used_fallback=true
    resolved="${resolved:-none}"
    body=$(fallback_bullets "$digest" "$max_bullets")
  fi
  [[ -n $body ]] || body="- No activity found in the selected projects."

  local ts entry
  ts=$(date +%s)
  entry="$ENTRIES_DIR/$ts.md"
  printf '%s\n' "$body" | write_atomic "$entry"

  local since until warnings
  since=$(jq -r '.since' <<<"$digest")
  until=$(jq -r '.until' <<<"$digest")
  # A scheduled run that could not reach GitHub still writes a standup, and
  # without this the entry would look complete while silently missing every org
  # repo. The warning rides along with the entry so the panel can say so.
  warnings=$(jq -c '.warnings // []' <<<"$digest")

  # One standup per day per kind. A manual run replaces an earlier manual run
  # from the same day, and a scheduled run replaces an earlier scheduled one,
  # so a schedule that fires twice leaves one entry rather than two near
  # identical ones. The two kinds stay separate: pressing refresh after the
  # morning run is a deliberate second look, not a duplicate of it.
  jq -c --arg id "$ts" --argjson ts "$ts" --arg date "$(date -d "@$ts" +%Y-%m-%d)" \
    --arg since "$since" --arg until "$until" --arg agent "$resolved" \
    --argjson commits "$count" --argjson repos "$(jq -r '.repoCount' <<<"$digest")" \
    --argjson fallback "$used_fallback" --argjson manual "$force" --argjson widened "$widened" \
    --argjson warnings "$warnings" \
    '.entries = ([{id:$id, ts:$ts, date:$date, since:$since, until:$until, agent:$agent,
                   commits:$commits, repos:$repos, fallback:$fallback, manual:$manual,
                   widened:$widened, warnings:$warnings}]
                 + [.entries[] | select((.date == $date and (.manual // false) == $manual) | not)])[:60]' \
    <<<"$(read_index)" | write_atomic "$INDEX_FILE"

  prune_entries
  finish_state "ok"
  jq -nc --arg id "$ts" --arg body "$body" --argjson commits "$count" --argjson fallback "$used_fallback" \
    --argjson widened "$widened" --argjson warnings "$warnings" \
    '{ok:true, generated:true, id:$id, body:$body, commits:$commits, fallback:$fallback,
      widened:$widened, warnings:$warnings}'
}

finish_state() {
  local status=$1
  GENERATE_FINISHED=true
  local until=${UNTIL_ISO:-$(date -Is)}
  jq -c --arg status "$status" --arg until "$until" --argjson ts "$(date +%s)" \
    '.running = false | .lastStatus = $status | .lastRunTs = $ts | .lastRunUntil = $until' \
    <<<"$(read_state)" | write_atomic "$STATE_FILE"
}

# A generate run holds LOCK_FILE for its whole life, and the kernel drops that
# lock the instant the process dies, however it dies. The "running" flag in
# the state file, by contrast, is only cleared by a run that reaches
# finish_state. A run killed part-way (shell restart, panel unload, SIGKILL)
# therefore leaves the flag set forever, the panel shows a spinner forever,
# and it refuses to start another run because it believes one is in
# progress. The lock is the truth; the flag is only a cache of it.
mark_interrupted() {
  jq -c '.running = false | .lastStatus = "interrupted"' <<<"$(read_state)" | write_atomic "$STATE_FILE"
}

reconcile_running() {
  [[ $(read_state | jq -r '.running // false' 2>/dev/null) == true ]] || return 0
  # flock -n on the path succeeds only when nobody holds the lock.
  if flock -n "$LOCK_FILE" true 2>/dev/null; then
    log "clearing stale running flag: no generate process holds the lock"
    mark_interrupted
  fi
}

prune_entries() {
  local keep f
  keep=$(read_index | jq -r '.entries[].id' 2>/dev/null | tr '\n' ' ')
  for f in "$ENTRIES_DIR"/*.md; do
    [[ -e $f ]] || continue
    local id
    id=$(basename "$f" .md)
    [[ " $keep " == *" $id "* ]] || rm -f "$f"
  done
}

# -------------------------------------------------------------------- reads

cmd_list() {
  ensure_dirs
  jq -c '{ok:true, lastSeenTs:(.lastSeenTs // 0),
          unread:([.entries[] | select(.ts > (.lastSeenTs // 0))] | length),
          entries:.entries}' <<<"$(read_index)" 2>/dev/null ||
    printf '%s\n' '{"ok":true,"lastSeenTs":0,"unread":0,"entries":[]}'
}

cmd_status() {
  ensure_dirs
  reconcile_running
  local seen
  seen=$(read_index | jq -r '.lastSeenTs // 0')
  jq -nc \
    --argjson idx "$(read_index)" \
    --argjson st "$(read_state)" \
    --argjson seen "$seen" \
    '{ok:true, running:($st.running // false), lastStatus:($st.lastStatus // ""),
      lastRunTs:($st.lastRunTs // 0), lastSeenTs:$seen,
      unread:([$idx.entries[] | select(.ts > $seen)] | length),
      latest:($idx.entries[0] // null)}'
}

# Entry ids are unix timestamps and end up in a file path. Anything else is
# refused rather than sanitised, so no caller can walk out of the entries dir.
valid_id() { [[ $1 =~ ^[0-9]+$ ]]; }

cmd_show() {
  ensure_dirs
  local id=${1:-}
  [[ -n $id ]] || id=$(read_index | jq -r '.entries[0].id // ""')
  if [[ -n $id ]] && ! valid_id "$id"; then
    jq -nc '{ok:false, error:"invalid id"}'
    return 1
  fi
  [[ -n $id && -f $ENTRIES_DIR/$id.md ]] || {
    jq -nc '{ok:true, id:"", body:""}'
    return 0
  }
  local body
  body=$(read_bounded "$ENTRIES_DIR/$id.md" "$MAX_ENTRY_BYTES") || body=""
  jq -nc --arg id "$id" --arg body "$body" '{ok:true, id:$id, body:$body}'
}

cmd_seen() {
  ensure_dirs
  local ts=${1:-}
  [[ -n $ts ]] || ts=$(read_index | jq -r '.entries[0].ts // 0')
  valid_id "${ts:-0}" || die "invalid timestamp"
  jq -c --argjson ts "${ts:-0}" '.lastSeenTs = (if $ts > (.lastSeenTs // 0) then $ts else .lastSeenTs end)' \
    <<<"$(read_index)" | write_atomic "$INDEX_FILE"
  cmd_status
}

cmd_delete() {
  ensure_dirs
  local id=${1:?id required}
  valid_id "$id" || die "invalid id"
  read_index | jq -c --arg id "$id" '.entries = [.entries[] | select(.id != $id)]' | write_atomic "$INDEX_FILE"
  rm -f "$ENTRIES_DIR/$id.md"
  cmd_list
}

cmd_repos() {
  local roots=${1:-} depth=${2:-2} repos_raw=${3:-} orgs_raw=${4:-}
  local -a rootv=()
  while IFS= read -r r; do [[ -n $r ]] && rootv+=("$r"); done < <(split_roots "$roots")
  classify_explicit "$repos_raw"
  classify_orgs "$orgs_raw"
  ((${#rootv[@]} + ${#EXPLICIT_LOCAL[@]} + ${#EXPLICIT_REMOTE[@]} + ${#ORG_LIST[@]})) ||
    die "no project folders, repos or organizations configured"

  local out="[]" dir slug org
  while IFS= read -r dir; do
    [[ -n $dir ]] || continue
    # Carried so a clone and the org listing of the same repo collapse into one
    # line here, the way they do in the digest.
    slug=$(remote_repo_slug "$(git -C "$dir" remote get-url origin 2>/dev/null)" 2>/dev/null) || slug=""
    out=$(jq -c --arg name "$(basename "$dir")" --arg path "$dir" --arg slug "$slug" \
      '. + [{name:$name, path:$path, slug:$slug, source:"local"}]' <<<"$out")
  done < <(
    {
      ((${#rootv[@]})) && scan_repos "$depth" "${rootv[@]}"
      ((${#EXPLICIT_LOCAL[@]})) && explicit_repos "${EXPLICIT_LOCAL[@]}"
    } | unique_repos
  )

  for slug in ${EXPLICIT_REMOTE[@]+"${EXPLICIT_REMOTE[@]}"}; do
    out=$(jq -c --arg name "${slug##*/}" --arg path "$slug" --arg slug "$slug" \
      '. + [{name:$name, path:$path, slug:$slug, source:"github"}]' <<<"$out")
  done

  # Org membership is a live question, so the count only means anything if the
  # API can actually be reached. Nothing is invented when it cannot.
  #
  # This lists what is *visible* in the org, which is deliberately not the same
  # set the digest reports: the digest covers only repos you committed to in the
  # window. The count is a reachability check - "the org resolves and has this
  # many repos" - and the panel labels it as scope, not as standup content.
  local warnings="[]" listed=0
  if ((${#ORG_LIST[@]})); then
    if gh_ready; then
      for org in "${ORG_LIST[@]}"; do
        listed=0
        while IFS= read -r slug; do
          [[ $slug == */* ]] || continue
          listed=$((listed + 1))
          out=$(jq -c --arg name "${slug##*/}" --arg path "$slug" --arg slug "$slug" \
            '. + [{name:$name, path:$path, slug:$slug, source:"github"}]' <<<"$out")
        done < <(timeout "$GH_TIMEOUT" "$GH_BIN" repo list "$org" --limit "$MAX_ORG_REPO_LIST" \
          --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null)
        ((listed >= MAX_ORG_REPO_LIST)) &&
          warnings=$(jq -nc --arg o "$org" --argjson n "$MAX_ORG_REPO_LIST" \
            '["only the first \($n) repos of \($o) were counted; the standup itself is not limited this way"]')
      done
    else
      warnings=$(jq -nc '["GitHub not reachable (gh missing or not logged in) - organization repos not counted"]')
    fi
  fi

  # A clone of an org repo is one project, listed once. The origin slug is the
  # identity where there is one, so the clone and the API listing collapse; a
  # repo with no GitHub origin falls back to its path.
  out=$(jq -c 'reduce .[] as $r ({seen:{}, list:[]};
        ((if ($r.slug // "") == "" then $r.path else $r.slug end) | ascii_downcase) as $k |
        if .seen[$k] then . else .seen[$k] = true | .list += [$r] end) | .list' <<<"$out")

  jq -nc --argjson repos "$out" --argjson warnings "$warnings" \
    '{ok:true, count:($repos|length), warnings:$warnings, repos:$repos}'
}

# Feeds the author picker in settings: who actually shows up in these repos.
cmd_authors() {
  local roots=${1:-} depth=${2:-2} days=${3:-30} format=${4:-full} repos_raw=${5:-}
  local -a rootv=()
  while IFS= read -r r; do [[ -n $r ]] && rootv+=("$r"); done < <(split_roots "$roots")
  classify_explicit "$repos_raw"
  # The picker offers the people who show up in local history. An org-only
  # setup has no local history to read, so it offers nobody rather than failing
  # the settings page.
  ((${#rootv[@]} + ${#EXPLICIT_LOCAL[@]})) || {
    [[ $format == options ]] && { printf '[]'; return 0; }
    jq -nc '{ok:true, authors:[]}'
    return 0
  }
  local dir since
  since=$(date -Is -d "$days days ago")
  {
    while IFS= read -r dir; do
      [[ -n $dir ]] || continue
      git -C "$dir" log --all --no-merges --since="$since" --pretty=format:'%an%x1f%ae%x1e' 2>/dev/null
    done < <(
      {
        ((${#rootv[@]})) && scan_repos "$depth" "${rootv[@]}"
        ((${#EXPLICIT_LOCAL[@]})) && explicit_repos "${EXPLICIT_LOCAL[@]}"
      } | unique_repos
    )
  } | head -c "$MAX_SCAN_BYTES" | FORMAT="$format" python3 -c '
import json, os, sys, collections
raw = sys.stdin.buffer.read().decode("utf-8", "replace")
counts = collections.Counter()
names = {}
for rec in raw.split("\x1e"):
    rec = rec.strip("\n")
    if not rec or "\x1f" not in rec:
        continue
    an, ae = rec.split("\x1f", 1)
    ae = ae.strip().lower()
    if not ae:
        continue
    counts[ae] += 1
    names.setdefault(ae, an.strip())
fmt = os.environ.get("FORMAT", "full")
rows = [{"email": e, "name": names.get(e, e), "count": c} for e, c in counts.most_common(60)]
if fmt == "options":
    # Shape the qs.Ui MultiSelect expects from a dynamic optionsCommand.
    opts = [{"value": r["email"], "label": r["name"],
             "description": "%d commit%s" % (r["count"], "" if r["count"] == 1 else "s")}
            for r in rows]
    json.dump(opts, sys.stdout, ensure_ascii=False)
else:
    json.dump({"ok": True, "authors": rows}, sys.stdout, ensure_ascii=False)
'
}

usage() {
  cat >&2 <<'USAGE'
standup.sh <command> [options]

  generate [--roots S] [--repos S] [--orgs S] [--depth N] [--window auto|fixed]
           [--days N] [--since ISO] [--author-mode me|all|custom] [--authors S]
           [--agent ID|default|custom] [--custom-command CMD] [--max-bullets N]
           [--format-text S] [--force]
  collect  same scan options as generate; prints the digest without calling an agent

  --roots  folders to walk for git checkouts (comma, newline or colon separated)
  --repos  individual repos, comma or newline separated: a path on this machine,
           or a GitHub repo as owner/name or a clone URL
  --orgs   GitHub organizations, comma separated. Every repo in the org that you
           committed to in the window is included, whether or not it is cloned
           here; needs the gh CLI logged in
  list     index of stored standups
  status   unread count, latest entry, run state
  show     [id]
  seen     [ts]
  delete   <id>
  repos    <roots> [depth] [repos] [orgs]
  authors  <roots> [depth] [days] [format] [repos]
  agents   available coding agents and the configured default
USAGE
  exit 2
}

main() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v git >/dev/null 2>&1 || die "git is required"
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  ensure_dirs
  local cmd=${1:-}
  shift || true
  case "$cmd" in
  generate) cmd_generate "$@" ;;
  collect)
    local roots="" depth=2 mode=auto days=1 explicit="" author_mode=me authors=""
    local repos_opt="" orgs_opt=""
    while (($#)); do
      case "$1" in
      --roots) roots=$2; shift 2 ;;
      --repos) repos_opt=$2; shift 2 ;;
      --orgs) orgs_opt=$2; shift 2 ;;
      --depth) depth=$2; shift 2 ;;
      --window) mode=$2; shift 2 ;;
      --days) days=$2; shift 2 ;;
      --since) explicit=$2; shift 2 ;;
      --author-mode) author_mode=$2; shift 2 ;;
      --authors) authors=$2; shift 2 ;;
      *) shift ;;
      esac
    done
    collect_json "$roots" "$depth" "$mode" "$days" "$explicit" "$author_mode" "$authors" "$repos_opt" "$orgs_opt"
    ;;
  list) cmd_list ;;
  status) cmd_status ;;
  show) cmd_show "$@" ;;
  seen) cmd_seen "$@" ;;
  delete) cmd_delete "$@" ;;
  repos) cmd_repos "$@" ;;
  authors) cmd_authors "$@" ;;
  agents) cmd_agents ;;
  *) usage ;;
  esac
}

main "$@"
