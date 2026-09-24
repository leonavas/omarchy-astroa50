.pragma library

// Pure helpers for the Astro widget. Nothing here runs a process or reads a
// file — the QML hands in the parsed status and gets strings and numbers back.

// ---------------------------------------------------------------- settings

function truthy(value, fallback) {
  if (value === undefined || value === null) return fallback
  if (typeof value === "boolean") return value
  if (typeof value === "number") return value !== 0
  var text = String(value).toLowerCase()
  if (text === "true" || text === "1" || text === "yes") return true
  if (text === "false" || text === "0" || text === "no") return false
  return fallback
}

function clampInt(value, low, high) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return low
  return Math.max(low, Math.min(high, n))
}

// ------------------------------------------------------------------ status

// What `astro-a50 status` printed, or a disconnected stub when the output is
// not JSON (a crashed interpreter, an empty read).
function parseStatus(raw) {
  try {
    var parsed = JSON.parse(String(raw))
    if (parsed && typeof parsed === "object") return parsed
  } catch (e) {}
  return { connected: false, error: "io", message: "Unreadable answer from astro-a50" }
}

// A deep copy, so an optimistic edit never mutates the object a binding is
// already holding — QML only re-evaluates when the property is reassigned.
function copy(state) {
  return JSON.parse(JSON.stringify(state || {}))
}

function active(state, key, fallback) {
  var entry = state ? state[key] : undefined
  if (entry && typeof entry === "object" && entry.active !== undefined) return entry.active
  return fallback
}

// A battery figure is only worth showing while the headset is on or sitting
// in the dock charging. Switched off and away from the base, the station
// reports whatever it last heard, which is not a reading.
function hasReading(state) {
  if (!state || !state.connected || state.error) return false
  var headset = state.headset || {}
  var battery = state.battery || {}
  return (headset.on || headset.docked) && Number(battery.percent) > 0
}

function stateLabel(state) {
  if (!state || state.error === "absent") return "Base station not connected"
  if (state.error === "permission") return "No access to the base station"
  if (state.error) return "Base station not answering"
  var headset = state.headset || {}
  var battery = state.battery || {}
  if (battery.charging) return "Charging"
  if (headset.docked && !headset.on) return "Docked"
  if (headset.docked) return "On · docked"
  if (headset.on) return "On battery"
  return "Headset off"
}

// Which alert a reading calls for: "critical" at or under the critical line,
// "low" at or under the low line, "" otherwise. A charging headset is on its
// way back up and never low.
function alertLevel(percent, charging, lowThreshold, criticalThreshold) {
  if (charging) return ""
  var n = Number(percent)
  if (!isFinite(n) || n <= 0) return ""
  var low = Number(lowThreshold)
  var critical = Math.min(low, Number(criticalThreshold))
  if (n <= critical) return "critical"
  if (n <= low) return "low"
  return ""
}

// The same ten-step ramp the first-party power panel paints.
function batteryIcon(percent, charging) {
  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = clampInt(Math.floor(Number(percent) / 10), 0, 9)
  return charging ? chargingIcons[index] : defaultIcons[index]
}

// ------------------------------------------------------------------ labels

// Gen 4 calls the open gate "Streaming"; Gen 5 calls it "Off". Both use the
// same four values on the wire side of bin/astro-a50.
function noiseGateOptions(generation) {
  return [
    { value: "streaming", label: generation === "Gen 5" ? "Off" : "Streaming", tooltip: "Gate open: every sound gets through" },
    { value: "night", label: "Night", tooltip: "Light gating for a quiet room" },
    { value: "home", label: "Home", tooltip: "Moderate gating for everyday noise" },
    { value: "tournament", label: "Tournament", tooltip: "Heavy gating for a loud venue" }
  ]
}

// The station keeps a name per EQ slot (ASTRO+, PRO, STUDIO out of the box).
// Empty names fall back to the slot number.
function eqOptions(names) {
  var out = []
  for (var i = 0; i < 3; i++) {
    var name = names && names[i] ? String(names[i]) : ""
    out.push({ value: String(i + 1), label: name.length > 0 ? name : "EQ " + (i + 1) })
  }
  return out
}

// Balance runs 0 (all game) to 255 (all chat).
function balanceLabel(value) {
  var chat = Math.round(clampInt(value, 0, 255) / 255 * 100)
  return "Game " + (100 - chat) + " · Voice " + chat
}

// "game" or "chat" for the station's two PipeWire sinks, "" for anything else.
// Gen 4 lands on the gaming-headset profile (stereo-game / stereo-chat); Gen 5
// on pro-audio, where pro-output-1 is game and pro-output-0 is voice.
function astroSinkKind(name) {
  var text = String(name || "")
  if (text.indexOf("Astro_Gaming_Astro_A50") !== -1) {
    if (/stereo-game$/.test(text)) return "game"
    if (/stereo-chat$/.test(text)) return "chat"
  }
  if (text.indexOf("Logitech_A50") !== -1) {
    if (/pro-output-1$/.test(text)) return "game"
    if (/pro-output-0$/.test(text)) return "chat"
  }
  return ""
}

function sameGains(a, b) {
  if (!a || !b || a.length !== b.length) return false
  for (var i = 0; i < a.length; i++) {
    if (Math.round(Number(a[i])) !== Math.round(Number(b[i]))) return false
  }
  return true
}

// The template whose curve the station holds right now, "" for a custom one.
function matchTemplate(templates, gains) {
  if (!templates) return ""
  for (var name in templates) {
    if (sameGains(templates[name], gains)) return name
  }
  return ""
}

function freqLabel(hz) {
  var n = Number(hz)
  if (n >= 1000) return (Math.round(n / 100) / 10) + "k"
  return String(n)
}

// Gen 5's dial reads 0 (all voice) to 100 (all game).
function dialLabel(chatmix) {
  var game = clampInt(chatmix ? chatmix.game : 50, 0, 100)
  return "Game " + game + " · Voice " + (100 - game)
}

function gainLabel(db) {
  var n = Math.round(Number(db) || 0)
  return (n > 0 ? "+" : "") + n
}

// ------------------------------------------------------------------ theme

// One "#rrggbb" out of the theme's colors.toml, by the first of `keys` set.
function themeColor(raw, keys, fallback) {
  var wanted = keys || []
  var found = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (match) found[match[1]] = match[2]
  }
  for (var k = 0; k < wanted.length; k++) {
    if (found[wanted[k]]) return found[wanted[k]]
  }
  return fallback || ""
}
