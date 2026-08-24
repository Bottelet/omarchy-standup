#!/usr/bin/env bash
# Offline test suite. Builds throwaway git repos in a temp tree, runs the
# engine against them with a stub agent, and checks Model.js with qjs/node.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN=$(dirname "$HERE")
ENGINE="$PLUGIN/scripts/standup.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  [[ -n ${2:-} ]] && printf '       %s\n' "$2"
}

check() {
  local name=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then ok "$name"; else no "$name" "expected [$expected] got [$actual]"; fi
}

contains() {
  local name=$1 needle=$2 haystack=$3
  if [[ $haystack == *"$needle"* ]]; then ok "$name"; else no "$name" "missing [$needle] in [${haystack:0:200}]"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export OMARCHY_STANDUP_STATE="$WORK/state"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config --global user.email "me@example.com"
git config --global user.name "Test Me"
git config --global init.defaultBranch main

mkrepo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "me@example.com"
  git -C "$dir" config user.name "Test Me"
}

commit() {
  local dir=$1 subject=$2 email=${3:-me@example.com} name=${4:-Test Me}
  echo "$RANDOM$subject" >>"$dir/file.txt"
  git -C "$dir" add -A
  GIT_AUTHOR_NAME=$name GIT_AUTHOR_EMAIL=$email \
    GIT_COMMITTER_NAME=$name GIT_COMMITTER_EMAIL=$email \
    GIT_AUTHOR_DATE="${GIT_AUTHOR_DATE:-}" GIT_COMMITTER_DATE="${GIT_COMMITTER_DATE:-}" \
    git -C "$dir" commit -q -m "$subject"
}

echo "== fixtures =="
ROOTS="$WORK/projects"
mkrepo "$ROOTS/alpha"
commit "$ROOTS/alpha" "Add login form"
commit "$ROOTS/alpha" "Fix session timeout"
mkrepo "$ROOTS/beta"
commit "$ROOTS/beta" "Speed up the importer"
commit "$ROOTS/beta" "Colleague only change" "her@example.com" "Other Dev"
mkdir -p "$ROOTS/notarepo"
echo hello >"$ROOTS/notarepo/readme.md"
# A linked worktree of alpha: the scan must not report it as a second project.
git -C "$ROOTS/alpha" worktree add -q -b side "$ROOTS/alpha-side" >/dev/null 2>&1
ok "fixtures built"

echo
echo "== repo discovery =="
OUT=$("$ENGINE" repos "$ROOTS" 2)
check "counts logical repos, not worktrees" "2" "$(jq -r '.count' <<<"$OUT")"
contains "finds alpha" '"alpha"' "$OUT"
contains "finds beta" '"beta"' "$OUT"
if [[ $OUT != *"alpha-side"* ]]; then ok "worktree is not a separate project"; else no "worktree is not a separate project"; fi

OUT=$("$ENGINE" repos "$ROOTS/alpha" 2)
check "a root that is itself a repo" "1" "$(jq -r '.count' <<<"$OUT")"

OUT=$("$ENGINE" repos "$ROOTS,$ROOTS" 2)
check "duplicate roots do not double count" "2" "$(jq -r '.count' <<<"$OUT")"

OUT=$("$ENGINE" repos "" 2)
check "empty roots is an error" "false" "$(jq -r '.ok' <<<"$OUT")"

echo
echo "== collection =="
OUT=$("$ENGINE" collect --roots "$ROOTS" --window fixed --days 1 --author-mode me)
check "only my commits" "3" "$(jq -r '.commitCount' <<<"$OUT")"
if [[ $OUT != *"Colleague only change"* ]]; then ok "other authors excluded in me mode"; else no "other authors excluded in me mode"; fi

OUT=$("$ENGINE" collect --roots "$ROOTS" --window fixed --days 1 --author-mode all)
check "every author in all mode" "4" "$(jq -r '.commitCount' <<<"$OUT")"

OUT=$("$ENGINE" collect --roots "$ROOTS" --window fixed --days 1 --author-mode custom --authors "her@example.com")
check "custom author filter" "1" "$(jq -r '.commitCount' <<<"$OUT")"
contains "custom filter keeps the right commit" "Colleague only change" "$OUT"

OUT=$("$ENGINE" collect --roots "$ROOTS" --window fixed --days 1 --author-mode custom --authors "")
check "empty custom list falls back rather than matching nobody" "3" "$(jq -r '.commitCount' <<<"$OUT")"

# A commit reachable from two refs (branch + worktree branch) is one commit.
git -C "$ROOTS/alpha" branch -q duplicate-ref
OUT=$("$ENGINE" collect --roots "$ROOTS" --window fixed --days 1 --author-mode me)
check "a commit on two refs counts once" "3" "$(jq -r '.commitCount' <<<"$OUT")"

OUT=$("$ENGINE" collect --roots "$ROOTS" --since "2027-01-01T00:00:00+00:00" --author-mode all)
check "future window finds nothing" "0" "$(jq -r '.commitCount' <<<"$OUT")"

# git silently drops a date filter it cannot parse, which would turn a standup
# into the entire history; the engine clamps instead.
OUT=$("$ENGINE" collect --roots "$ROOTS" --since "2999-01-01T00:00:00+00:00" --author-mode all)
check "an unrepresentable date does not disable the filter" "4" "$(jq -r '.commitCount' <<<"$OUT")"
OUT=$("$ENGINE" collect --roots "$ROOTS" --since "not a date at all" --author-mode all)
check "junk date falls back to the day window" "4" "$(jq -r '.commitCount' <<<"$OUT")"

echo
echo "== authors =="
OUT=$("$ENGINE" authors "$ROOTS" 2 30)
check "both authors discovered" "2" "$(jq -r '.authors | length' <<<"$OUT")"
OUT=$("$ENGINE" authors "$ROOTS" 2 30 options)
contains "options format is a bare array" '[{' "${OUT:0:2}{"
contains "options carry a value" '"value"' "$OUT"
contains "options carry a commit count" 'commit' "$OUT"

echo
echo "== agents =="
OUT=$("$ENGINE" agents)
check "agent list is ok" "true" "$(jq -r '.ok' <<<"$OUT")"
if (($(jq -r '.agents | length' <<<"$OUT") >= 5)); then ok "several agents discovered"; else no "several agents discovered"; fi
contains "claude is in the list" '"claude"' "$OUT"

echo
echo "== generate with a stub agent =="
STUB="$WORK/bin"
mkdir -p "$STUB"
cat >"$STUB/claude" <<'STUBEOF'
#!/usr/bin/env bash
# Echoes a tagged standup wrapped in the greeting and fences a real agent adds.
cat >/dev/null
printf 'Here is your standup:\n\n<standup>\n```\n- Added the login form and fixed session timeouts\n- Sped up the importer\n```\n</standup>\nHope that helps!\n'
STUBEOF
chmod +x "$STUB/claude"

OUT=$(PATH="$STUB:$PATH" "$ENGINE" generate --roots "$ROOTS" --window fixed --days 1 --agent claude --max-bullets 5)
check "generated" "true" "$(jq -r '.generated' <<<"$OUT")"
check "agent output used, not the fallback" "false" "$(jq -r '.fallback' <<<"$OUT")"
BODY=$(jq -r '.body' <<<"$OUT")
contains "keeps the first bullet" "- Added the login form" "$BODY"
contains "keeps the second bullet" "- Sped up the importer" "$BODY"
if [[ $BODY != *"Here is your standup"* ]]; then ok "drops the preamble"; else no "drops the preamble"; fi
if [[ $BODY != *'```'* ]]; then ok "drops code fences"; else no "drops code fences"; fi
if [[ $BODY != *"Hope that helps"* ]]; then ok "drops the sign-off"; else no "drops the sign-off"; fi
if [[ $BODY != *"<standup>"* ]]; then ok "drops the tags themselves"; else no "drops the tags themselves"; fi
check "nothing but the two bullets" "2" "$(printf '%s\n' "$BODY" | grep -c .)"

# The update is not required to be a bullet list, so a shape with headings and
# a paragraph has to survive intact.
cat >"$STUB/claude" <<'STUBEOF'
#!/usr/bin/env bash
cat >/dev/null
printf '<standup>\nAlice\n- Shipped the importer\nBob\n- Reviewed the login branch\n</standup>\n'
STUBEOF
OUT=$(PATH="$STUB:$PATH" "$ENGINE" generate --roots "$ROOTS" --window fixed --days 1 --agent claude --max-bullets 5)
BODY=$(jq -r '.body' <<<"$OUT")
contains "headings survive" "Alice" "$BODY"
contains "bullets under headings survive" "- Shipped the importer" "$BODY"
check "every line kept" "4" "$(printf '%s\n' "$BODY" | grep -c .)"

# A model that ignores the tags still gets ANSI and fences cleaned up.
cat >"$STUB/claude" <<'STUBEOF'
#!/usr/bin/env bash
cat >/dev/null
printf '\033[1;32m- Coloured bullet\033[0m\n```\n- Fenced bullet\n```\n'
STUBEOF
OUT=$(PATH="$STUB:$PATH" "$ENGINE" generate --roots "$ROOTS" --window fixed --days 1 --agent claude --max-bullets 5)
BODY=$(jq -r '.body' <<<"$OUT")
contains "untagged output still arrives" "- Coloured bullet" "$BODY"
if [[ $BODY != *$'\033'* ]]; then ok "ANSI stripped from untagged output"; else no "ANSI stripped from untagged output"; fi
if [[ $BODY != *'```'* ]]; then ok "fences stripped from untagged output"; else no "fences stripped from untagged output"; fi

echo
echo "== the format instruction reaches the agent =="
cat >"$STUB/claude" <<'STUBEOF'
#!/usr/bin/env bash
prompt=$(cat)
printf '<standup>\n'
[[ $prompt == *"under each person's name"* ]] && printf -- '- saw the format text\n'
[[ $prompt == *"at most 3 bullets"* ]] && printf -- '- saw the bullet cap\n'
printf '</standup>\n'
STUBEOF
OUT=$(PATH="$STUB:$PATH" "$ENGINE" generate --roots "$ROOTS" --window fixed --days 1 --agent claude \
  --max-bullets 3 --format-text "Group the work under each person's name as a heading, with bullets underneath.")
BODY=$(jq -r '.body' <<<"$OUT")
contains "the chosen format is in the prompt" "saw the format text" "$BODY"
contains "the bullet cap is in the prompt" "saw the bullet cap" "$BODY"

echo
echo "== fallback when no agent answers =="
cat >"$STUB/claude" <<'STUBEOF'
#!/usr/bin/env bash
cat >/dev/null
exit 1
STUBEOF
OUT=$(PATH="$STUB:$PATH" "$ENGINE" generate --roots "$ROOTS" --window fixed --days 1 --agent claude --max-bullets 5)
check "still produces a standup" "true" "$(jq -r '.generated' <<<"$OUT")"
check "marked as a fallback" "true" "$(jq -r '.fallback' <<<"$OUT")"
contains "fallback names a project" "alpha" "$(jq -r '.body' <<<"$OUT")"

OUT=$("$ENGINE" generate --roots "$ROOTS" --window fixed --days 1 --agent definitely-not-an-agent)
check "unknown agent falls back rather than failing" "true" "$(jq -r '.fallback' <<<"$OUT")"

echo
echo "== custom command =="
cat >"$STUB/fakellm" <<'STUBEOF'
#!/usr/bin/env bash
# A local model: reads the prompt on stdin, proves it by echoing a repo name.
prompt=$(cat)
if [[ $prompt == *"Add login form"* ]]; then
  printf -- '- Local model saw the commits\n'
else
  printf -- '- Local model got no prompt\n'
fi
STUBEOF
chmod +x "$STUB/fakellm"
OUT=$(PATH="$STUB:$PATH" "$ENGINE" generate --roots "$ROOTS" --window fixed --days 1 --agent custom --custom-command "fakellm" --max-bullets 3)
check "custom command used" "false" "$(jq -r '.fallback' <<<"$OUT")"
contains "prompt reached the custom command on stdin" "Local model saw the commits" "$(jq -r '.body' <<<"$OUT")"

OUT=$("$ENGINE" generate --roots "$ROOTS" --window fixed --days 1 --agent custom --custom-command "" --max-bullets 3)
check "empty custom command falls back" "true" "$(jq -r '.fallback' <<<"$OUT")"

echo
echo "== index, unread and history =="
OUT=$("$ENGINE" list)
if (($(jq -r '.entries | length' <<<"$OUT") >= 4)); then ok "entries accumulate"; else no "entries accumulate"; fi
UNREAD=$(jq -r '.unread' <<<"$OUT")
if ((UNREAD >= 4)); then ok "everything unread before seen"; else no "everything unread before seen" "got $UNREAD"; fi

OUT=$("$ENGINE" seen)
check "seen clears the badge" "0" "$(jq -r '.unread' <<<"$OUT")"

LATEST=$("$ENGINE" show)
check "show returns the newest by default" "true" "$(jq -r '.ok' <<<"$LATEST")"
ID=$(jq -r '.id' <<<"$LATEST")
OLD_ID=$("$ENGINE" list | jq -r '.entries[2].id')
OUT=$("$ENGINE" show "$OLD_ID")
check "show can reach an older entry" "$OLD_ID" "$(jq -r '.id' <<<"$OUT")"

OUT=$("$ENGINE" delete "$OLD_ID")
if [[ $(jq -r '[.entries[].id] | index("'"$OLD_ID"'")' <<<"$OUT") == "null" ]]; then ok "delete removes the entry"; else no "delete removes the entry"; fi
if [[ ! -f $OMARCHY_STANDUP_STATE/entries/$OLD_ID.md ]]; then ok "delete removes the file"; else no "delete removes the file"; fi

echo
echo "== auto window =="
# After a run, the auto window resumes from where the last one stopped rather
# than re-reading the same days.
UNTIL=$(jq -r '.lastRunUntil' "$OMARCHY_STANDUP_STATE/state.json")
if [[ -n $UNTIL && $UNTIL != null ]]; then ok "last run boundary recorded"; else no "last run boundary recorded"; fi
OUT=$("$ENGINE" collect --roots "$ROOTS" --window auto --days 7 --author-mode all)
check "auto window resumes from the boundary" "$UNTIL" "$(jq -r '.since' <<<"$OUT")"
check "nothing new since the boundary" "0" "$(jq -r '.commitCount' <<<"$OUT")"

# Every run moves the cursor to now, so the window right after a run is empty.
# That must not make Generate now a dead button: it widens to the day window.
cat >"$STUB/claude" <<'STUBEOF'
#!/usr/bin/env bash
cat >/dev/null
printf -- '- Summarised the real commits\n'
STUBEOF
chmod +x "$STUB/claude"
OUT=$(PATH="$STUB:$PATH" "$ENGINE" generate --roots "$ROOTS" --window auto --days 7 --agent claude --force)
check "an exhausted cursor window widens instead of reporting nothing" "true" "$(jq -r '.generated' <<<"$OUT")"
check "and says so" "true" "$(jq -r '.widened // false' <<<"$OUT")"
contains "the widened run summarises real work" "Summarised the real commits" "$(jq -r '.body' <<<"$OUT")"
if (($(jq -r '.commits' <<<"$OUT") > 0)); then ok "the widened run found commits"; else no "the widened run found commits"; fi

BEFORE=$("$ENGINE" list | jq -r '.entries | length')
OUT=$(PATH="$STUB:$PATH" "$ENGINE" generate --roots "$ROOTS" --window auto --days 7 --agent claude --force)
AFTER=$("$ENGINE" list | jq -r '.entries | length')
check "pressing generate again replaces today's manual entry" "$BEFORE" "$AFTER"

# A window with genuinely nothing in it - not even after widening - is reported
# honestly rather than handed to an agent to invent something from.
STALE="$WORK/stale"
mkrepo "$STALE/ancient"
GIT_AUTHOR_DATE="60 days ago" GIT_COMMITTER_DATE="60 days ago" commit "$STALE/ancient" "Ancient work"
cat >"$STUB/claude" <<'STUBEOF'
#!/usr/bin/env bash
cat >/dev/null
printf -- '- The agent was asked to invent something\n'
STUBEOF
OUT=$(PATH="$STUB:$PATH" "$ENGINE" generate --roots "$STALE" --window fixed --days 1 --agent claude)
check "a scheduled run over an empty window generates nothing" "false" "$(jq -r '.generated' <<<"$OUT")"

OUT=$(PATH="$STUB:$PATH" "$ENGINE" generate --roots "$STALE" --window fixed --days 1 --agent claude --force)
check "a forced empty run still writes an entry" "true" "$(jq -r '.generated' <<<"$OUT")"
contains "and says there was nothing" "No commits in this window" "$(jq -r '.body' <<<"$OUT")"
if [[ $(jq -r '.body' <<<"$OUT") != *"invent"* ]]; then ok "the agent is not called for an empty window"; else no "the agent is not called for an empty window"; fi

commit "$ROOTS/alpha" "Something brand new"
OUT=$("$ENGINE" collect --roots "$ROOTS" --window auto --days 7 --author-mode all)
check "a fresh commit lands in the next window" "1" "$(jq -r '.commitCount' <<<"$OUT")"

echo
echo "== concurrency =="
cat >"$STUB/claude" <<'STUBEOF'
#!/usr/bin/env bash
cat >/dev/null
sleep 2
printf -- '- Slow agent finished\n'
STUBEOF
PATH="$STUB:$PATH" "$ENGINE" generate --roots "$ROOTS" --window fixed --days 1 --agent claude >"$WORK/slow.json" 2>/dev/null &
SLOW=$!
sleep 0.7
OUT=$(PATH="$STUB:$PATH" "$ENGINE" generate --roots "$ROOTS" --window fixed --days 1 --agent claude)
check "a second run is refused while one is in flight" "false" "$(jq -r '.ok' <<<"$OUT")"
wait $SLOW
check "the first run still completed" "true" "$(jq -r '.generated' <"$WORK/slow.json")"

echo
echo "== hardening =="
OUT=$("$ENGINE" show "../../../../etc/passwd" 2>/dev/null)
check "show refuses a traversing id" "false" "$(jq -r '.ok' <<<"$OUT")"
OUT=$("$ENGINE" delete "../../../../tmp/x" 2>/dev/null)
check "delete refuses a traversing id" "false" "$(jq -r '.ok' <<<"$OUT")"
OUT=$("$ENGINE" seen "; rm -rf /" 2>/dev/null)
check "seen refuses a non-numeric marker" "false" "$(jq -r '.ok' <<<"$OUT")"

check "the state directory is not world readable" "700" "$(stat -c '%a' "$OMARCHY_STANDUP_STATE")"

# A runaway agent must not be buffered without limit.
cat >"$STUB/claude" <<'STUBEOF'
#!/usr/bin/env bash
cat >/dev/null
printf '<standup>\n'
head -c 5000000 /dev/zero | tr '\0' 'x'
STUBEOF
chmod +x "$STUB/claude"
OUT=$(PATH="$STUB:$PATH" "$ENGINE" generate --roots "$ROOTS" --window fixed --days 1 --agent claude --force)
SIZE=$(jq -r '.body' <<<"$OUT" | wc -c)
if ((SIZE < 200000)); then ok "a runaway agent reply is capped ($SIZE bytes)"; else no "a runaway agent reply is capped" "got $SIZE bytes"; fi

# Commit subjects come from whatever repos are on disk, including cloned ones.
HOSTILE="$WORK/hostile"
mkrepo "$HOSTILE/evil"
commit "$HOSTILE/evil" 'subject with <img src=http://example.com/x> and $(id) and `id` and "quotes"'
OUT=$("$ENGINE" collect --roots "$HOSTILE" --window fixed --days 1 --author-mode all)
check "a hostile subject is collected as data" "1" "$(jq -r '.commitCount' <<<"$OUT")"
contains "and survives verbatim in json" 'and $(id) and' "$(jq -r '.repos[0].commits[0].s' <<<"$OUT")"
if [[ ! -f /tmp/standup-pwned ]]; then ok "no command substitution was executed"; else no "no command substitution was executed"; fi

cat >"$STUB/claude" <<'STUBEOF'
#!/usr/bin/env bash
prompt=$(cat)
printf '<standup>\n'
[[ $prompt == *'$(id)'* ]] && printf -- '- subject reached the prompt unexecuted\n'
printf '</standup>\n'
STUBEOF
OUT=$(PATH="$STUB:$PATH" "$ENGINE" generate --roots "$HOSTILE" --window fixed --days 1 --author-mode all --agent claude --force)
contains "hostile subjects reach the agent as inert text" "unexecuted" "$(jq -r '.body' <<<"$OUT")"

# State files are read on every poll and rewritten on every run, so they get
# the same bounded, descriptor-bound treatment as any other input.
STATE_DIR="$OMARCHY_STANDUP_STATE"

cp "$STATE_DIR/index.json" "$WORK/index.good.json"
head -c 2000000 /dev/zero | tr '\0' 'x' >"$STATE_DIR/index.json"
check "an oversized index reads as empty rather than being buffered" "0" \
  "$("$ENGINE" list | jq -r '.entries | length')"
cp "$WORK/index.good.json" "$STATE_DIR/index.json"

printf '%s' 'not json' >"$STATE_DIR/index.json"
check "a corrupt index reads as empty" "0" "$("$ENGINE" list | jq -r '.entries | length')"
cp "$WORK/index.good.json" "$STATE_DIR/index.json"

printf '%s' 'not json' >"$STATE_DIR/state.json"
check "a corrupt state file falls back to defaults" "true" "$("$ENGINE" status | jq -r '.ok')"

rm -f "$STATE_DIR/index.json"
mkfifo "$STATE_DIR/index.json"
OUT=$(timeout 10 "$ENGINE" list 2>/dev/null)
check "a fifo in place of the index is refused promptly" "0" "$(jq -r '.entries | length' <<<"${OUT:-'{"entries":[]}'}" 2>/dev/null || echo 0)"
rm -f "$STATE_DIR/index.json"
cp "$WORK/index.good.json" "$STATE_DIR/index.json"

# The old code wrote through a guessable "<target>.tmp". Anything that can write
# to the state directory could pre-create that name as a symlink and have the
# next write land somewhere else entirely.
printf 'untouched' >"$WORK/canary"
ln -sf "$WORK/canary" "$STATE_DIR/index.json.tmp"
"$ENGINE" seen >/dev/null 2>&1
check "a planted temp-name symlink is not written through" "untouched" "$(cat "$WORK/canary")"
check "and the real index still updated" "true" "$("$ENGINE" list | jq -r '.lastSeenTs >= 0')"
rm -f "$STATE_DIR/index.json.tmp"

if [[ -z $(find "$STATE_DIR" -maxdepth 1 -name '*.json.tmp' -not -type l) ]]; then
  ok "no predictable temp files are left behind"
else
  no "no predictable temp files are left behind"
fi

# The read is bound to one descriptor: the open itself refuses a symlinked final
# component and cannot block, so there is no window between checking a pathname
# and opening it.
rm -f "$STATE_DIR/index.json"
mkfifo "$STATE_DIR/index.json"
START=$(date +%s)
timeout 10 "$ENGINE" status >/dev/null 2>&1
RC=$?
ELAPSED=$(( $(date +%s) - START ))
if ((RC != 124)) && ((ELAPSED < 5)); then ok "a fifo swapped in cannot block the open"; else no "a fifo swapped in cannot block the open" "rc=$RC elapsed=${ELAPSED}s"; fi
rm -f "$STATE_DIR/index.json"

# A symlink whose target is a fifo is the same attack wearing a hat.
mkfifo "$WORK/trap.fifo"
ln -sf "$WORK/trap.fifo" "$STATE_DIR/index.json"
START=$(date +%s)
timeout 10 "$ENGINE" status >/dev/null 2>&1
RC=$?
ELAPSED=$(( $(date +%s) - START ))
if ((RC != 124)) && ((ELAPSED < 5)); then ok "a symlink to a fifo cannot block the open either"; else no "a symlink to a fifo cannot block the open either" "rc=$RC elapsed=${ELAPSED}s"; fi
rm -f "$STATE_DIR/index.json" "$WORK/trap.fifo"

# O_NOFOLLOW: the final component must be a real file, so a swapped symlink is
# not silently accepted just because its target happens to be same-owner.
printf '%s' '{"entries":[{"id":"9","ts":9,"date":"2026-01-01"}],"lastSeenTs":0}' >"$WORK/decoy.json"
ln -sf "$WORK/decoy.json" "$STATE_DIR/index.json"
check "a symlinked state file is refused, not followed" "0" "$("$ENGINE" list | jq -r '.entries | length')"
rm -f "$STATE_DIR/index.json"
cp "$WORK/index.good.json" "$STATE_DIR/index.json"
check "and the real file still reads afterwards" "true" "$("$ENGINE" list | jq -r '.ok')"

echo
echo "== Model.js =="
JSRUN=""
command -v node >/dev/null 2>&1 && JSRUN=node
command -v qjs >/dev/null 2>&1 && [[ -z $JSRUN ]] && JSRUN=qjs
if [[ -z $JSRUN ]]; then
  echo "  skip (no node or qjs on PATH)"
else
  cat >"$WORK/model_test.js" <<'JSEOF'
var fs = require("fs")
var src = fs.readFileSync(process.argv[2], "utf8").replace(".pragma library", "")
var M = {}
new Function("exports", src + "\n;Object.assign(exports, {DEFAULTS:DEFAULTS, WEEKDAYS:WEEKDAYS, settingsWithDefaults:settingsWithDefaults, generateArgs:generateArgs, authorMode:authorMode, authorValues:authorValues, scheduleDays:scheduleDays, parseTimeOfDay:parseTimeOfDay, formatTimeOfDay:formatTimeOfDay, scheduleDue:scheduleDue, bulletsOf:bulletsOf, displayLines:displayLines, stripMarkdown:stripMarkdown, relativeDay:relativeDay, unreadCount:unreadCount, sourceLine:sourceLine, agentOptions:agentOptions, formatOptions:formatOptions, formatPreset:formatPreset, formatText:formatText, formatSummary:formatSummary, parseJson:parseJson, toBool:toBool, clampInt:clampInt})")(M)

var pass = 0, fail = 0
function eq(name, expected, actual) {
  var a = JSON.stringify(actual), e = JSON.stringify(expected)
  if (a === e) { pass++; console.log("  ok   " + name) }
  else { fail++; console.log("  FAIL " + name + "\n       expected " + e + " got " + a) }
}

eq("defaults fill in", "~/Projects", M.settingsWithDefaults({}).roots)
eq("a set value wins", "~/Work", M.settingsWithDefaults({roots: "~/Work"}).roots)
eq("an empty string does not override", "~/Projects", M.settingsWithDefaults({roots: ""}).roots)
eq("string false is false", false, M.settingsWithDefaults({autoGenerate: "false"}).autoGenerate)
eq("days are clamped", 30, M.settingsWithDefaults({days: 900}).days)
eq("junk days fall back", 1, M.settingsWithDefaults({days: "banana"}).days)

eq("me is the default author mode", "me", M.authorMode({}))
eq("custom with nobody picked degrades to me", "me", M.authorMode({authorMode: "custom", authors: ""}))
eq("custom with people stays custom", "custom", M.authorMode({authorMode: "custom", authors: "a@b.c"}))
eq("an unknown mode degrades to me", "me", M.authorMode({authorMode: "nonsense"}))
eq("author values split and trim", ["a@b.c", "d@e.f"], M.authorValues({authors: " a@b.c , d@e.f "}))

var args = M.generateArgs({windowMode: "fixed", days: 3, maxBullets: 4}, true)
eq("fixed window is passed through", "fixed", args[args.indexOf("--window") + 1])
eq("days are passed through", "3", args[args.indexOf("--days") + 1])
eq("force is passed through", true, args.indexOf("--force") !== -1)
eq("no author list unless custom", -1, M.generateArgs({}, false).indexOf("--authors"))
eq("custom command only for the custom agent", -1, M.generateArgs({agent: "claude"}, false).indexOf("--custom-command"))
eq("custom agent carries its command", "ollama run x",
   (function(a) { return a[a.indexOf("--custom-command") + 1] })(M.generateArgs({agent: "custom", customCommand: "ollama run x"}, false)))

eq("weekdays parse", ["mon", "tue", "wed", "thu", "fri"], M.scheduleDays({}))
eq("weekday junk is dropped", ["mon", "sat"], M.scheduleDays({scheduleDays: "mon,blursday,sat"}))
eq("time parses", 9 * 60 + 30, M.parseTimeOfDay("09:30", -1))
eq("time without a colon parses", 9 * 60, M.parseTimeOfDay("9", -1))
eq("nonsense time falls back", -1, M.parseTimeOfDay("half past ten", -1))
eq("out of range time falls back", -1, M.parseTimeOfDay("99:99", -1))
eq("time formats back", "09:05", M.formatTimeOfDay(9 * 60 + 5))

// 2026-08-24 is a Monday.
var monday0830 = new Date(2026, 7, 24, 8, 30)
var monday0930 = new Date(2026, 7, 24, 9, 30)
var saturday0930 = new Date(2026, 7, 22, 9, 30)
var cfg = {autoGenerate: true, scheduleTime: "09:00", scheduleDays: "mon,tue,wed,thu,fri"}
eq("not due before the time", false, M.scheduleDue(cfg, monday0830, 0))
eq("due after the time", true, M.scheduleDue(cfg, monday0930, 0))
eq("not due on an unscheduled day", false, M.scheduleDue(cfg, saturday0930, 0))
eq("not due twice the same day", false,
   M.scheduleDue(cfg, monday0930, new Date(2026, 7, 24, 9, 10).getTime() / 1000))
eq("still due when the last run predates today's slot", true,
   M.scheduleDue(cfg, monday0930, new Date(2026, 7, 23, 9, 10).getTime() / 1000))
eq("a late wake-up still catches up", true, M.scheduleDue(cfg, new Date(2026, 7, 24, 23, 59), 0))
eq("off means never due", false, M.scheduleDue({autoGenerate: false}, monday0930, 0))
eq("no days means never due", false, M.scheduleDue({autoGenerate: true, scheduleDays: ""}, monday0930, 0))

eq("bullets strip their marker", ["one", "two"], M.bulletsOf("- one\n\n- two\n"))
eq("bullets survive without a marker", ["plain"], M.bulletsOf("plain"))
eq("empty text has no bullets", [], M.bulletsOf(""))

var now = new Date(2026, 7, 24, 12, 0)
eq("today", "Today", M.relativeDay("2026-08-24", now))
eq("yesterday", "Yesterday", M.relativeDay("2026-08-23", now))
eq("older dates name the day", "Wed 19 Aug", M.relativeDay("2026-08-19", now))
eq("junk dates pass through", "nope", M.relativeDay("nope", now))

eq("unread counts entries after the marker", 2,
   M.unreadCount({lastSeenTs: 10, entries: [{ts: 30}, {ts: 20}, {ts: 5}]}))
eq("nothing unread when caught up", 0, M.unreadCount({lastSeenTs: 30, entries: [{ts: 30}]}))
eq("no index means nothing unread", 0, M.unreadCount(null))

eq("source line reads naturally", "1 commit  ·  2 projects  ·  via claude",
   M.sourceLine({commits: 1, repos: 2, agent: "claude"}))
eq("fallback is called out", "3 commits  ·  1 project  ·  no agent - raw summary",
   M.sourceLine({commits: 3, repos: 1, agent: "none", fallback: true}))

var opts = M.agentOptions({defaultAgent: "claude", agents: [{id: "codex", label: "Codex", available: true}]}, {})
eq("default option comes first", "default", opts[0].value)
eq("default option names the agent", "Omarchy default (claude)", opts[0].label)
eq("discovered agents are listed", "codex", opts[1].value)
eq("custom is always offered", "custom", opts[opts.length - 1].value)
eq("no default set is spelled out", "Omarchy default (none set)", M.agentOptions({}, {})[0].label)

eq("the default format is the bullet list",
   "A flat bullet list. One line per bullet, plain past tense.", M.formatText({}))
eq("a preset supplies its own wording",
   "Group the work under each person's name as a heading, with bullets underneath.",
   M.formatText({format: "person"}))
eq("typed wording wins over the preset", "Only what I asked for.",
   M.formatText({format: "person", formatText: "  Only what I asked for.  "}))
eq("an unknown preset falls back to the first",
   "A flat bullet list. One line per bullet, plain past tense.", M.formatText({format: "nope"}))
eq("custom is offered last", "custom", M.formatOptions()[M.formatOptions().length - 1].value)
eq("every preset is offered", 6, M.formatOptions().length)
eq("the format reaches the engine args",
   "A single short paragraph, no bullets.",
   (function(a) { return a[a.indexOf("--format-text") + 1] })(M.generateArgs({format: "paragraph"}, false)))
eq("edited wording shows as custom", "Custom", M.formatSummary({format: "bullets", formatText: "my own"}))
eq("an untouched preset shows its name", "Grouped by project", M.formatSummary({format: "project"}))

eq("a bullet line is a bullet", [{kind: "bullet", text: "did a thing", indent: 0}],
   M.displayLines("- did a thing"))
eq("a star is a bullet too", [{kind: "bullet", text: "did a thing", indent: 0}],
   M.displayLines("* did a thing"))
eq("a heading is not a bullet", [{kind: "text", text: "Alice", indent: 0}], M.displayLines("Alice"))
eq("indented bullets keep their depth", 1, M.displayLines("  - nested").pop().indent)
eq("blank lines are dropped", 2, M.displayLines("- one\n\n\n- two").length)
eq("a paragraph is one text line", [{kind: "text", text: "We shipped the thing.", indent: 0}],
   M.displayLines("We shipped the thing."))
eq("markdown headings lose their hashes", [{kind: "text", text: "Alice", indent: 0}],
   M.displayLines("## Alice"))
eq("bold markers do not reach the panel", "crowdbook: shipped it",
   M.displayLines("- **crowdbook:** shipped it").pop().text)
eq("code ticks do not reach the panel", "renamed pos-access",
   M.displayLines("- renamed `pos-access`").pop().text)
eq("a lone asterisk is left alone", "2 * 3 is 6", M.stripMarkdown("2 * 3 is 6"))

eq("bad json is null", null, M.parseJson("{nope"))
eq("empty json is null", null, M.parseJson("   "))

console.log("\n  Model.js: " + pass + " passed, " + fail + " failed")
process.exit(fail === 0 ? 0 : 1)
JSEOF
  if "$JSRUN" "$WORK/model_test.js" "$PLUGIN/Model.js"; then
    ok "Model.js suite"
  else
    no "Model.js suite"
  fi
fi

echo
echo "== packaging =="
check "manifest is valid json" "bottelet.standup" "$(jq -r '.id' "$PLUGIN/manifest.json")"
check "schema version is a number" "number" "$(jq -r '.schemaVersion | type' "$PLUGIN/manifest.json")"
check "bar widget entry point exists" "true" "$([[ -f $PLUGIN/$(jq -r '.entryPoints.barWidget' "$PLUGIN/manifest.json") ]] && echo true || echo false)"
if [[ -z $(find "$PLUGIN" -type l -not -path '*/.git/*') ]]; then ok "no symlinks in the plugin folder"; else no "no symlinks in the plugin folder"; fi
bash -n "$ENGINE" && ok "engine parses" || no "engine parses"

echo
echo "-------------------------------------"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0)) || exit 1
