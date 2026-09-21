# Security posture

## What this plugin does and does not do

- **One outbound destination, only when asked.** With no organizations and no
  remote repos configured — the default — the plugin opens no socket of its own
  at all. Naming a GitHub organization or an uncloned `owner/name` repo turns on
  exactly one network path: read-only GitHub API calls made through the `gh`
  CLI, which the user has already installed and authenticated. The plugin holds
  no token, stores no credential, and requests no scope; it inherits whatever
  `gh auth login` granted. The calls are `search/commits` (the digest) and
  `repo list` (the project count shown in settings) — both reads. Beyond that,
  any network traffic is the coding agent's own.
- **No writes outside its own state.** It writes only to
  `~/.local/share/omarchy-standup/` (created mode `700`) and to its own widget
  entry in `~/.config/omarchy/shell.json`. It never writes inside the scanned
  repositories; every git command it runs is a read (`log`, `rev-parse`,
  `config --local user.email`).
- **No privileged operations.** No sudo, no systemd units, no polkit, no
  filesystem mounts, no symlinks in the package.

## Untrusted input and where it goes

Commit subjects, author names, branch names and directory names come from
whatever repositories are on disk — including ones the user only cloned — and,
when an organization is configured, from every repo in that org the user
committed to. An org is a wider blast radius than a personal folder: a commit
subject written by a colleague, or by anyone who got a commit merged, arrives
here as text. It is treated as data everywhere, exactly as local history is:

| Sink | Handling |
| --- | --- |
| JSON output | Built with `jq --arg` / `--argjson` and `python3 json.dump`; never string-concatenated |
| Shell | No `eval`, no `sh -c`, no backticks. Every external call is argv (`git -C <dir> log ...`) |
| The agent prompt | Passed as inert text, on stdin where the CLI supports it |
| The panel | Every `Text` element sets `textFormat: Text.PlainText`, so no HTML or rich-text parsing happens and nothing can trigger a remote fetch |
| Clipboard | `Quickshell.execDetached(["wl-copy", "--", text])` — argv, with `--` terminating options |
| GitHub search queries | Org names and repo slugs are matched against `^[A-Za-z0-9][A-Za-z0-9-]*$` and `owner/name` before use, and anything else is dropped with a log line rather than escaped. Author values must look like an email or a login. The query is passed as a single argv value to `gh api -f q=...`, never through a shell |
| GitHub API responses | Projected to six fields with `--jq` at the call site, then parsed with `python3 json.loads` per line; a line that does not parse is skipped. Commit subjects from the API are truncated and capped exactly like local ones |

## Prompt injection

A hostile commit message can address the model directly. The mitigation is to
give the model nothing to act with: the agent runs with tools disabled where
its CLI offers the switch (`claude --tools ""`, `codex exec --sandbox
read-only`, `gemini --approval-mode plan`) and always with its working
directory set to an empty scratch folder, away from the user's projects and
any rules files in them. Agents without such a switch run with their own
defaults, which the README states plainly.

Configuring an organization widens who that text can come from. Previously the
untrusted set was "repos you chose to clone"; with an org it is every commit in
every repo of that org you touched, including commits written by people the
user has no relationship with. The handling is unchanged — the same truncation,
the same `jq --arg` and `json.dump` construction, the same `Text.PlainText`
rendering — but the population is larger, and that is worth stating plainly.

For the agents whose CLI has a tools switch, the worst case remains a
misleading standup: the model repeating text a commit message told it to.
Nothing in the pipeline executes the result; it is written to a file and drawn
as plain text.

For the agents that have no such switch — `opencode`, `copilot`, `grok`, `pi`,
`omp`, `crush` — the prompt reaches a model that may hold its own tools, so the
worst case is that model being talked into using them. The empty working
directory bounds what it can reach easily; it does not remove network or `$HOME`
access. Anyone pairing whole-organization collection with one of those agents
should understand that as a prompt-injection path into a tool-capable model,
and prefer `claude` or `codex`, where tools are switched off explicitly.

## Remote collection bounds

Per call: at most 3 pages of 100 commits per author query, a 2 MB ceiling on
the response body, and a 60 second timeout (`OMARCHY_STANDUP_GH_TIMEOUT`) on
every `gh` invocation.

Per run, which is what actually bounds the work: at most 5 author queries
(a custom author list is a fan-out multiplier — one paginated search each), a
4 MB ceiling on the bytes kept across all of them, at most 10 organizations,
and a 120 second wall-clock budget across every `gh` call
(`OMARCHY_STANDUP_REMOTE_BUDGET`). Without the per-run half, "3 pages, 2 MB,
60s" describes one request and says nothing about the total.

The per-repo cap and the whole-digest `MAX_COMMITS_TOTAL` are both applied to
the *merged* result, not only to the local walk, so an organization cannot add
its own full quota on top of the local one. Whenever any of these caps discards
data — the page cap, the per-repo cap, or the total — the digest reports
`truncated: true`.

Failure is non-fatal by design: a missing `gh`, an expired token, a rate limit
or a timeout degrades the run to the local repos and surfaces a warning, rather
than failing a standup that has perfectly good local history to report. The
warning travels with the generated entry as well as with the settings page, so
a scheduled run that silently lost its org coverage still says so.

One skew worth knowing about: all organizations and remote repos are searched
in a single query sorted by author date, so the commits fetched are the most
recent across the whole scope combined. In `Whose commits: everyone` over a busy
org, one high-traffic repo can crowd quieter projects out of a run.

## Resource bounds

Every stream that could be attacker-influenced is capped, so no input can
exhaust memory:

| Stream | Cap |
| --- | --- |
| `git log` output per repository | 200 KB |
| Commits per repository / per run | 40 / 300 |
| Commit subject | 120 characters |
| Author scan across all repos | 4 MB |
| Agent reply | 64 KB |
| Rendered lines | 40 |
| Stored standups | 60, older files pruned |

The agent call has a 240-second timeout, and generation takes a `flock` so two
runs cannot interleave.

## Path handling

Entry ids are unix timestamps and end up in a file path, so `show`, `delete`
and `seen` refuse anything that is not `^[0-9]+$` rather than trying to sanitise
it. Only a leading `~` is expanded in configured paths. `find` is not given
`-L`, so symlinked directories are not followed out of the scan roots.

An entry in **Individual repos** is classified by *shape*, never by what
happens to exist at the moment it is read. Anything anchored — absolute, or
explicitly `./` or `../` — is a path: it stays on this machine, and a missing
one is a configuration error rather than a fallback to something else. Anything
else can only ever be a GitHub `owner/name`, and is dropped if it does not match
that shape.

The distinction matters because the alternative — trying the filesystem first
and treating a miss as a repo slug — would make a mistyped relative path into a
search query sent to github.com, and would make *whether a private project name
leaves the machine* depend on the caller's working directory. Note the
consequence of the rule: a bare `group/project` is always treated as GitHub, so
a repo hosted elsewhere should be given as a path, not as a slug.

## The custom command setting

Choosing **Custom command** lets the user name any executable to write the
standup. It is split into argv words and executed directly — never through a
shell — so shell metacharacters in that setting are inert argument text rather
than commands. It receives the prompt on stdin and nothing else. This is the
user configuring their own machine, and it is the feature that makes a local
model possible.

## Reporting

Open an issue at https://github.com/Bottelet/omarchy-standup/issues.
