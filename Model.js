// Pure helpers for the Standup panel. Nothing here touches QML types, so the
// whole file is exercised by the offline test suite.
.pragma library

var DEFAULTS = {
  roots: "~/Projects",
  scanDepth: 2,
  windowMode: "auto",
  days: 1,
  authorMode: "me",
  authors: "",
  agent: "default",
  customCommand: "",
  format: "bullets",
  formatText: "",
  autoGenerate: true,
  scheduleTime: "09:00",
  scheduleDays: "mon,tue,wed,thu,fri",
  maxBullets: 5
}

var WEEKDAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
var WEEKDAY_LABELS = ["S", "M", "T", "W", "T", "F", "S"]

// The shape of the generated update. The dropdown only seeds the text field -
// what actually reaches the agent is always formatText, so anything can be
// typed over a preset.
var FORMAT_PRESETS = [
  {
    value: "bullets",
    label: "Bullet list",
    description: "One flat list",
    text: "A flat bullet list. One line per bullet, plain past tense."
  },
  {
    value: "person",
    label: "Grouped by person",
    description: "A heading per person",
    text: "Group the work under each person's name as a heading, with bullets underneath."
  },
  {
    value: "project",
    label: "Grouped by project",
    description: "A heading per project",
    text: "Group the work under each project name as a heading, with bullets underneath."
  },
  {
    value: "standup",
    label: "Yesterday / Today / Blockers",
    description: "The classic three sections",
    text: "Three short sections: Yesterday, Today, Blockers. Leave Blockers out when nothing suggests one."
  },
  {
    value: "paragraph",
    label: "One paragraph",
    description: "No bullets at all",
    text: "A single short paragraph, no bullets."
  }
]

function formatPreset(value) {
  for (var i = 0; i < FORMAT_PRESETS.length; i++) {
    if (FORMAT_PRESETS[i].value === String(value)) return FORMAT_PRESETS[i]
  }
  return FORMAT_PRESETS[0]
}

function formatOptions() {
  var out = []
  for (var i = 0; i < FORMAT_PRESETS.length; i++) {
    out.push({
      value: FORMAT_PRESETS[i].value,
      label: FORMAT_PRESETS[i].label,
      description: FORMAT_PRESETS[i].description
    })
  }
  out.push({ value: "custom", label: "Custom", description: "Your own wording" })
  return out
}

// What actually gets sent. An edited field always wins; an untouched one falls
// back to the selected preset's wording.
function formatText(settings) {
  var s = settingsWithDefaults(settings)
  var typed = String(s.formatText || "").trim()
  if (typed !== "") return typed
  return formatPreset(s.format).text
}

function parseJson(text) {
  var raw = String(text || "").trim()
  if (raw === "") return null
  try {
    return JSON.parse(raw)
  } catch (e) {
    return null
  }
}

function settingsWithDefaults(settings) {
  var out = {}
  for (var k in DEFAULTS) out[k] = DEFAULTS[k]
  // An empty string usually means "the field was never filled in", so the
  // default should win. scheduleDays is the exception: clearing every weekday
  // is a deliberate "never run automatically", and falling back to the default
  // would quietly switch the schedule back on.
  var emptyIsMeaningful = { scheduleDays: true }
  if (settings) {
    for (var s in settings) {
      if (settings[s] === undefined || settings[s] === null) continue
      if (settings[s] === "" && !emptyIsMeaningful[s]) continue
      out[s] = settings[s]
    }
  }
  // Booleans arrive from shell.json as real booleans, but a hand-edited config
  // can hold the string form, and "false" is truthy.
  out.autoGenerate = toBool(out.autoGenerate, DEFAULTS.autoGenerate)
  out.days = clampInt(out.days, 1, 30, DEFAULTS.days)
  out.scanDepth = clampInt(out.scanDepth, 1, 5, DEFAULTS.scanDepth)
  out.maxBullets = clampInt(out.maxBullets, 1, 10, DEFAULTS.maxBullets)
  return out
}

function toBool(value, fallback) {
  if (value === true || value === false) return value
  var s = String(value).toLowerCase()
  if (s === "true" || s === "1" || s === "yes") return true
  if (s === "false" || s === "0" || s === "no") return false
  return fallback
}

function clampInt(value, min, max, fallback) {
  var n = parseInt(value, 10)
  if (isNaN(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

// ------------------------------------------------------------------ commands

function scriptCommand(scriptPath, args) {
  // Invoked through bash rather than directly: a plugin folder copied around
  // by hand does not reliably keep its execute bit.
  return ["bash", scriptPath].concat(args)
}

function generateArgs(settings, force) {
  var s = settingsWithDefaults(settings)
  var args = ["generate",
              "--roots", String(s.roots),
              "--depth", String(s.scanDepth),
              "--window", s.windowMode === "fixed" ? "fixed" : "auto",
              "--days", String(s.days),
              "--author-mode", authorMode(s),
              "--max-bullets", String(s.maxBullets),
              "--format-text", formatText(s),
              "--agent", String(s.agent || "default")]
  if (authorMode(s) === "custom") args = args.concat(["--authors", authorList(s)])
  if (String(s.agent) === "custom") args = args.concat(["--custom-command", String(s.customCommand || "")])
  if (force) args.push("--force")
  return args
}

// "custom" only survives if people were actually picked; an empty list would
// otherwise filter every commit away and produce a permanently empty standup.
function authorMode(settings) {
  var s = settingsWithDefaults(settings)
  var mode = String(s.authorMode || "me")
  if (mode === "custom" && authorList(s) === "") return "me"
  if (mode !== "me" && mode !== "all" && mode !== "custom") return "me"
  return mode
}

function authorList(settings) {
  var raw = settings ? settings.authors : ""
  if (raw instanceof Array) return raw.join(",")
  return String(raw || "").trim()
}

function authorValues(settings) {
  var list = authorList(settings)
  if (list === "") return []
  return list.split(",").map(function(v) { return v.trim() }).filter(function(v) { return v !== "" })
}

function authorsOptionsArgs(settings) {
  var s = settingsWithDefaults(settings)
  return ["authors", String(s.roots), String(s.scanDepth), "30", "options"]
}

function reposArgs(settings) {
  var s = settingsWithDefaults(settings)
  return ["repos", String(s.roots), String(s.scanDepth)]
}

// ------------------------------------------------------------------ schedule

function scheduleDays(settings) {
  var s = settingsWithDefaults(settings)
  var raw = s.scheduleDays
  if (raw instanceof Array) raw = raw.join(",")
  var parts = String(raw || "").toLowerCase().split(",")
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var d = parts[i].trim().slice(0, 3)
    if (WEEKDAYS.indexOf(d) !== -1 && out.indexOf(d) === -1) out.push(d)
  }
  return out
}

function parseTimeOfDay(text, fallbackMinutes) {
  var m = String(text || "").match(/^\s*(\d{1,2})\s*[:.]?\s*(\d{2})?\s*$/)
  if (!m) return fallbackMinutes
  var h = parseInt(m[1], 10)
  var min = m[2] === undefined ? 0 : parseInt(m[2], 10)
  if (isNaN(h) || h > 23 || isNaN(min) || min > 59) return fallbackMinutes
  return h * 60 + min
}

function formatTimeOfDay(minutes) {
  var h = Math.floor(minutes / 60)
  var m = minutes % 60
  return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
}

// True when a scheduled standup is overdue right now.
//
// The comparison is against today's target time rather than an interval, which
// is what makes a machine that was asleep at 09:00 still produce the standup
// when it wakes at 09:40 — and produce exactly one, not one per tick.
function scheduleDue(settings, now, lastRunTs) {
  var s = settingsWithDefaults(settings)
  if (!s.autoGenerate) return false
  var days = scheduleDays(s)
  if (days.length === 0) return false
  if (days.indexOf(WEEKDAYS[now.getDay()]) === -1) return false

  var targetMinutes = parseTimeOfDay(s.scheduleTime, parseTimeOfDay(DEFAULTS.scheduleTime, 540))
  var nowMinutes = now.getHours() * 60 + now.getMinutes()
  if (nowMinutes < targetMinutes) return false

  var target = new Date(now.getTime())
  target.setHours(Math.floor(targetMinutes / 60), targetMinutes % 60, 0, 0)
  return Number(lastRunTs || 0) * 1000 < target.getTime()
}

// ------------------------------------------------------------------- display

function bulletsOf(text) {
  var lines = String(text || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/\s+$/, "")
    if (line === "") continue
    out.push(line.replace(/^\s*[-*•]\s*/, ""))
  }
  return out
}

// The panel renders whatever shape the agent was asked for, so a line is only
// given a bullet dot when it actually is one. Headings and paragraphs from the
// grouped and prose formats keep their own look.
function displayLines(text) {
  var lines = String(text || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var raw = lines[i].replace(/\s+$/, "")
    if (raw.trim() === "") continue
    var m = raw.match(/^(\s*)[-*•]\s+(.*)$/)
    if (m) out.push({ kind: "bullet", text: stripMarkdown(m[2]), indent: Math.min(2, Math.floor(m[1].length / 2)) })
    else out.push({ kind: "text", text: stripMarkdown(raw.replace(/^\s*#{1,6}\s+/, "").trim()), indent: 0 })
  }
  return out
}

// Agents reach for markdown whatever the format asks for. The panel draws
// plain text - deliberately, since an agent's output is not trusted enough to
// hand to a rich-text renderer - so the markers are removed rather than shown
// as literal asterisks.
function stripMarkdown(text) {
  return String(text || "")
    .replace(/\*\*(.+?)\*\*/g, "$1")
    .replace(/__(.+?)__/g, "$1")
    .replace(/`([^`]+)`/g, "$1")
    .trim()
}

function joinBullets(bullets) {
  return bullets.map(function(b) { return "- " + b }).join("\n")
}

function entryDate(entry) {
  return entry && entry.date ? String(entry.date) : ""
}

// "Today" / "Yesterday" / "Mon 18 Aug" — the panel never shows a bare ISO date.
function relativeDay(dateText, now) {
  var parts = String(dateText || "").split("-")
  if (parts.length !== 3) return String(dateText || "")
  var d = new Date(parseInt(parts[0], 10), parseInt(parts[1], 10) - 1, parseInt(parts[2], 10))
  var today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  var diff = Math.round((today.getTime() - d.getTime()) / 86400000)
  if (diff === 0) return "Today"
  if (diff === 1) return "Yesterday"
  var names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  return names[d.getDay()] + " " + d.getDate() + " " + months[d.getMonth()]
}

function timeOfDay(ts) {
  var d = new Date(Number(ts || 0) * 1000)
  var h = d.getHours()
  var m = d.getMinutes()
  return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
}

function unreadCount(index) {
  if (!index || !(index.entries instanceof Array)) return 0
  var seen = Number(index.lastSeenTs || 0)
  var n = 0
  for (var i = 0; i < index.entries.length; i++) {
    if (Number(index.entries[i].ts || 0) > seen) n++
  }
  return n
}

// Summary line under the header: where the bullets came from.
function sourceLine(entry) {
  if (!entry) return ""
  var bits = []
  var commits = Number(entry.commits || 0)
  var repos = Number(entry.repos || 0)
  bits.push(commits + " commit" + (commits === 1 ? "" : "s"))
  bits.push(repos + " project" + (repos === 1 ? "" : "s"))
  if (entry.fallback) bits.push("no agent - raw summary")
  else if (entry.agent) bits.push("via " + entry.agent)
  return bits.join("  ·  ")
}

function agentOptions(payload, settings) {
  var out = []
  var data = payload || {}
  var def = String(data.defaultAgent || "")
  out.push({
    value: "default",
    label: def === "" ? "Omarchy default (none set)" : "Omarchy default (" + def + ")",
    description: "Follows omarchy default agent"
  })
  var agents = data.agents instanceof Array ? data.agents : []
  for (var i = 0; i < agents.length; i++) {
    out.push({
      value: String(agents[i].id),
      label: String(agents[i].label || agents[i].id),
      description: agents[i].available ? "" : "not installed"
    })
  }
  out.push({
    value: "custom",
    label: "Custom command",
    description: "Any CLI that reads a prompt on stdin"
  })
  return out
}

function formatSummary(settings) {
  var s = settingsWithDefaults(settings)
  if (String(s.format) === "custom" || String(s.formatText || "").trim() !== "") return "Custom"
  return formatPreset(s.format).label
}

function windowSummary(settings) {
  var s = settingsWithDefaults(settings)
  if (s.windowMode === "fixed") return "Last " + s.days + " day" + (s.days === 1 ? "" : "s")
  return "Since last standup"
}

function authorSummary(settings) {
  var mode = authorMode(settings)
  if (mode === "all") return "Everyone"
  if (mode === "custom") {
    var n = authorValues(settings).length
    return n + " person" + (n === 1 ? "" : "s")
  }
  return "Only me"
}
