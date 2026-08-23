#!/usr/bin/env bash
# Fills the state directory with synthetic standups so a screenshot can be
# taken without publishing real project names or commit messages.
#
#   tests/demo-data.sh install   # back up real state, write the demo
#   tests/demo-data.sh restore   # put the real state back
set -euo pipefail

STATE="${OMARCHY_STANDUP_STATE:-$HOME/.local/share/omarchy-standup}"
BACKUP="$STATE.real"

install_demo() {
  [[ -d $BACKUP ]] && {
    echo "a backup already exists at $BACKUP - restore first" >&2
    exit 1
  }
  [[ -d $STATE ]] && mv "$STATE" "$BACKUP"
  mkdir -p "$STATE/entries"

  local now today yesterday
  now=$(date +%s)
  today=$(date -d "@$now" +%Y-%m-%d)
  yesterday=$(date -d "@$((now - 86400))" +%Y-%m-%d)

  cat >"$STATE/entries/$now.md" <<'ENTRY'
- Finished the checkout retry flow and shipped it behind a flag
- Fixed the invoice PDF ordering bug customers reported on Friday
- Cut billing-web's first paint from 2.1s to 900ms by deferring the chart bundle
- Reviewed the mobile-app offline sync branch, left notes on conflict handling
ENTRY

  cat >"$STATE/entries/$((now - 86400)).md" <<'ENTRY'
- Migrated the payments service to the new webhook signing scheme
- Added contract tests around the refund path
- Unblocked infra on the staging database restore
ENTRY

  cat >"$STATE/entries/$((now - 172800)).md" <<'ENTRY'
- Drafted the checkout retry design and got sign-off
- Cleared the last of the search relevance tickets
ENTRY

  jq -n --argjson now "$now" --arg today "$today" --arg yesterday "$yesterday" \
    --arg before "$(date -d "@$((now - 172800))" +%Y-%m-%d)" '
    {
      entries: [
        {id:($now|tostring), ts:$now, date:$today, agent:"claude", commits:23, repos:4, fallback:false},
        {id:(($now-86400)|tostring), ts:($now-86400), date:$yesterday, agent:"claude", commits:17, repos:3, fallback:false},
        {id:(($now-172800)|tostring), ts:($now-172800), date:$before, agent:"claude", commits:9, repos:2, fallback:false}
      ],
      lastSeenTs: ($now - 86400)
    }' >"$STATE/index.json"

  jq -n --argjson now "$now" '{lastRunTs:$now, lastRunUntil:"", lastStatus:"ok", running:false}' >"$STATE/state.json"
  echo "demo state written to $STATE (real state parked at $BACKUP)"
}

restore_demo() {
  [[ -d $BACKUP ]] || {
    echo "no backup at $BACKUP" >&2
    exit 1
  }
  rm -rf "$STATE"
  mv "$BACKUP" "$STATE"
  echo "real state restored"
}

case "${1:-}" in
install) install_demo ;;
restore) restore_demo ;;
*)
  echo "usage: demo-data.sh install|restore" >&2
  exit 2
  ;;
esac
