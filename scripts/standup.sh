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

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG_FILE" 2>/dev/null; }

die() {
  log "ERROR: $*"
  jq -nc --arg e "$1" '{ok:false, error:$e}'
  exit 1
}

# Reads a file through a single descriptor with a hard ceiling.
#
# Type and owner are checked on the open descriptor rather than re-checked by
# pathname, so replacing the file between the check and the read cannot change
# what was validated. The type is also checked before the open, because opening
# a fifo blocks until a writer appears and would hang the caller before any
# descriptor check could run.
read_bounded() { # read_bounded <path> <max-bytes>
  local path=$1 max=$2 fd info kind owner content bytes
  [[ -e $path ]] || return 1
  if [[ $(stat -c '%u' "$path" 2>/dev/null) != "$UID" ]]; then
    log "refused, not owned by this user: $path"
    return 1
  fi
  if [[ ! -f $path ]]; then
    log "refused, not a regular file: $path"
    return 1
  fi
  # Braces matter: a bare `exec ... 2>/dev/null` would point this shell's
  # stderr at /dev/null for good.
  if ! { exec {fd}<"$path"; } 2>/dev/null; then
    log "refused, cannot open: $path"
    return 1
  fi
  info=$(stat -L -c '%F|%u' "/proc/self/fd/$fd" 2>/dev/null)
  kind=${info%%|*}
  owner=${info##*|}
  if [[ $kind != "regular file" || $owner != "$UID" ]]; then
    exec {fd}<&-
    log "refused, descriptor is not a regular file owned by this user: $path"
    return 1
  fi
  content=$(head -c $((max + 1)) <&"$fd")
  exec {fd}<&-
  bytes=$(printf '%s' "$content" | wc -c)
  if ((bytes > max)); then
    log "refused, larger than $max bytes: $path"
    return 1
  fi
  printf '%s' "$content"
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
  local -a roots=()
  while IFS= read -r r; do [[ -n $r ]] && roots+=("$r"); done < <(split_roots "$roots_raw")
  ((${#roots[@]})) || die "no project folders configured"

  local -a repos=()
  while IFS= read -r r; do [[ -n $r ]] && repos+=("$r"); done < <(scan_repos "$depth" "${roots[@]}" | unique_repos)

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
  if [[ $author_mode == me ]]; then
    local e
    while IFS= read -r e; do
      [[ -n $e ]] && author_args+=(--author="$e")
    done < <(printf '%s\n' "${repos[@]}" | my_emails | sort -u)
    # No git identity configured anywhere: the login name is the last clue left.
    ((${#author_args[@]})) || author_args=(--author="$(whoami)")
  fi

  local total=0 truncated=false
  local repos_json="[]" dir
  for dir in "${repos[@]}"; do
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

    repos_json=$(jq -c --arg name "$(basename "$dir")" --arg path "$dir" --arg branch "$branch" \
      --argjson commits "$commits_json" \
      '. + [{name:$name, path:$path, branch:$branch, commits:$commits}]' <<<"$repos_json")
  done

  jq -nc --arg since "$SINCE_ISO" --arg until "$UNTIL_ISO" --arg mode "$author_mode" \
    --argjson repos "$repos_json" --argjson total "$total" --argjson trunc "$truncated" \
    '{ok:true, since:$since, until:$until, authorMode:$mode, repoCount:($repos|length),
      commitCount:$total, truncated:$trunc, repos:$repos}'
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
    "## " + .name + " (" + .branch + ")",
    (.commits[] | "- " + .d + " [" + .an + "] " + .s),
    ""
  ' <<<"$1"
}

DEFAULT_FORMAT="A flat bullet list. One line per bullet, plain past tense."

build_prompt() {
  local digest=$1 max_bullets=$2 author_mode=$3 format_text=$4
  local who="the developer"
  [[ $author_mode == all ]] && who="the team"
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
  local agent=default custom="" max_bullets=5 force=false format_text=""
  while (($#)); do
    case "$1" in
    --roots) roots=$2; shift 2 ;;
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

  read_state | jq -c '.running = true | .lastStatus = "collecting"' | write_atomic "$STATE_FILE"

  local digest
  digest=$(collect_json "$roots" "$depth" "$mode" "$days" "$explicit" "$author_mode" "$authors")
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
    wide=$(collect_json "$roots" "$depth" fixed "$days" "" "$author_mode" "$authors")
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
    jq -nc --argjson d "$digest" '{ok:true, generated:false, reason:"no commits", digest:$d}'
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
    prompt=$(build_prompt "$(digest_markdown "$digest")" "$max_bullets" "$author_mode" "$format_text")
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

  local since until
  since=$(jq -r '.since' <<<"$digest")
  until=$(jq -r '.until' <<<"$digest")

  jq -c --arg id "$ts" --argjson ts "$ts" --arg date "$(date -d "@$ts" +%Y-%m-%d)" \
    --arg since "$since" --arg until "$until" --arg agent "$resolved" \
    --argjson commits "$count" --argjson repos "$(jq -r '.repoCount' <<<"$digest")" \
    --argjson fallback "$used_fallback" --argjson manual "$force" --argjson widened "$widened" \
    '.entries = ([{id:$id, ts:$ts, date:$date, since:$since, until:$until, agent:$agent,
                   commits:$commits, repos:$repos, fallback:$fallback, manual:$manual,
                   widened:$widened}]
                 + [.entries[] | select((.manual and $manual and .date == $date) | not)])[:60]' \
    <<<"$(read_index)" | write_atomic "$INDEX_FILE"

  prune_entries
  finish_state "ok"
  jq -nc --arg id "$ts" --arg body "$body" --argjson commits "$count" --argjson fallback "$used_fallback" \
    --argjson widened "$widened" \
    '{ok:true, generated:true, id:$id, body:$body, commits:$commits, fallback:$fallback, widened:$widened}'
}

finish_state() {
  local status=$1
  local until=${UNTIL_ISO:-$(date -Is)}
  jq -c --arg status "$status" --arg until "$until" --argjson ts "$(date +%s)" \
    '.running = false | .lastStatus = $status | .lastRunTs = $ts | .lastRunUntil = $until' \
    <<<"$(read_state)" | write_atomic "$STATE_FILE"
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
  local roots=${1:-} depth=${2:-2}
  local -a rootv=()
  while IFS= read -r r; do [[ -n $r ]] && rootv+=("$r"); done < <(split_roots "$roots")
  ((${#rootv[@]})) || die "no project folders configured"
  local out="[]" dir
  while IFS= read -r dir; do
    [[ -n $dir ]] || continue
    out=$(jq -c --arg name "$(basename "$dir")" --arg path "$dir" '. + [{name:$name, path:$path}]' <<<"$out")
  done < <(scan_repos "$depth" "${rootv[@]}" | unique_repos)
  jq -nc --argjson repos "$out" '{ok:true, count:($repos|length), repos:$repos}'
}

# Feeds the author picker in settings: who actually shows up in these repos.
cmd_authors() {
  local roots=${1:-} depth=${2:-2} days=${3:-30} format=${4:-full}
  local -a rootv=()
  while IFS= read -r r; do [[ -n $r ]] && rootv+=("$r"); done < <(split_roots "$roots")
  ((${#rootv[@]})) || die "no project folders configured"
  local dir since
  since=$(date -Is -d "$days days ago")
  {
    while IFS= read -r dir; do
      [[ -n $dir ]] || continue
      git -C "$dir" log --all --no-merges --since="$since" --pretty=format:'%an%x1f%ae%x1e' 2>/dev/null
    done < <(scan_repos "$depth" "${rootv[@]}" | unique_repos)
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

  generate [--roots S] [--depth N] [--window auto|fixed] [--days N] [--since ISO]
           [--author-mode me|all|custom] [--authors S] [--agent ID|default|custom]
           [--custom-command CMD] [--max-bullets N] [--format-text S] [--force]
  collect  same scan options as generate; prints the digest without calling an agent
  list     index of stored standups
  status   unread count, latest entry, run state
  show     [id]
  seen     [ts]
  delete   <id>
  repos    <roots> [depth]
  authors  <roots> [depth] [days]
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
    while (($#)); do
      case "$1" in
      --roots) roots=$2; shift 2 ;;
      --depth) depth=$2; shift 2 ;;
      --window) mode=$2; shift 2 ;;
      --days) days=$2; shift 2 ;;
      --since) explicit=$2; shift 2 ;;
      --author-mode) author_mode=$2; shift 2 ;;
      --authors) authors=$2; shift 2 ;;
      *) shift ;;
      esac
    done
    collect_json "$roots" "$depth" "$mode" "$days" "$explicit" "$author_mode" "$authors"
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
