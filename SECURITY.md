# Security posture

## What this plugin does and does not do

- **No network access.** The plugin never opens a socket. It reads local git
  repositories and runs a coding-agent CLI that the user has already installed
  and authenticated. Any network traffic is that agent's own.
- **No writes outside its own state.** It writes only to
  `~/.local/share/omarchy-standup/` (created mode `700`) and to its own widget
  entry in `~/.config/omarchy/shell.json`. It never writes inside the scanned
  repositories; every git command it runs is a read (`log`, `rev-parse`,
  `config --local user.email`).
- **No privileged operations.** No sudo, no systemd units, no polkit, no
  filesystem mounts, no symlinks in the package.

## Untrusted input and where it goes

Commit subjects, author names, branch names and directory names come from
whatever repositories are on disk — including ones the user only cloned. They
are treated as data everywhere:

| Sink | Handling |
| --- | --- |
| JSON output | Built with `jq --arg` / `--argjson` and `python3 json.dump`; never string-concatenated |
| Shell | No `eval`, no `sh -c`, no backticks. Every external call is argv (`git -C <dir> log ...`) |
| The agent prompt | Passed as inert text, on stdin where the CLI supports it |
| The panel | Every `Text` element sets `textFormat: Text.PlainText`, so no HTML or rich-text parsing happens and nothing can trigger a remote fetch |
| Clipboard | `Quickshell.execDetached(["wl-copy", "--", text])` — argv, with `--` terminating options |

## Prompt injection

A hostile commit message can address the model directly. The mitigation is to
give the model nothing to act with: the agent runs with tools disabled where
its CLI offers the switch (`claude --tools ""`, `codex exec --sandbox
read-only`, `gemini --approval-mode plan`) and always with its working
directory set to an empty scratch folder, away from the user's projects and
any rules files in them. Agents without such a switch run with their own
defaults, which the README states plainly.

The worst case that remains is a misleading standup — the model repeating text
a commit message told it to. Nothing in the pipeline executes the result; it is
written to a file and drawn as plain text.

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

## The custom command setting

Choosing **Custom command** lets the user name any executable to write the
standup. It is split into argv words and executed directly — never through a
shell — so shell metacharacters in that setting are inert argument text rather
than commands. It receives the prompt on stdin and nothing else. This is the
user configuring their own machine, and it is the feature that makes a local
model possible.

## Reporting

Open an issue at https://github.com/Bottelet/omarchy-standup/issues.
