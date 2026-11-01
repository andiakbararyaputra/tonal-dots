--!nonstrict
-- Tracks unread notifications per app by watching the Notifications D-Bus traffic.
-- Noctalia exposes no unread list to plugins, so ids come from Notify replies.

local notifs = {}   -- notification id -> app key
local appInfo = {}  -- app key -> { name, icon }
local order = {}    -- app keys, oldest first
local pending = {}  -- "<caller>#<serial>" -> { app, icon candidates }
local iconCache = {}

local current = nil -- message being parsed
local RESOLVER = noctalia.pluginDir() .. "/resolve-icon.sh"

local publish

-- appIconPath scans the filesystem synchronously and blows the callback budget, so resolve in a subprocess
local function resolveIcon(key, candidates, idx)
  idx = idx or 1
  local c = candidates[idx]
  if c == nil then
    return
  end
  if c == "" then
    resolveIcon(key, candidates, idx + 1)
    return
  end
  local cached = iconCache[c]
  if cached ~= nil then
    if cached then
      appInfo[key].icon = cached
      publish()
    else
      resolveIcon(key, candidates, idx + 1)
    end
    return
  end
  noctalia.runAsync({ "bash", RESOLVER, c }, function(result)
    local path = noctalia.string.trim(result.stdout or "")
    iconCache[c] = path ~= "" and path or false
    if path ~= "" then
      appInfo[key].icon = path
      publish()
    else
      resolveIcon(key, candidates, idx + 1)
    end
  end)
end

function publish()
  local seen, list = {}, {}
  for _, key in ipairs(order) do
    if not seen[key] then
      for _, k in pairs(notifs) do
        if k == key then
          seen[key] = true
          table.insert(list, { name = appInfo[key].name, icon = appInfo[key].icon })
          break
        end
      end
    end
  end
  noctalia.state.set("deskclock.apps", list)
end

local function addNotification(id, msg)
  local key = string.lower(msg.desktopEntry ~= "" and msg.desktopEntry or msg.app)
  if key == "" then
    key = "unknown"
  end
  if appInfo[key] == nil then
    appInfo[key] = { name = msg.app ~= "" and msg.app or key }
    resolveIcon(key, { msg.desktopEntry, msg.appIcon, msg.app, msg.imagePath })
  end
  for i, k in ipairs(order) do
    if k == key then
      table.remove(order, i)
      break
    end
  end
  table.insert(order, key)
  notifs[id] = key
  publish()
end

local function header(line, kind)
  local fields = {}
  for k, v in string.gmatch(line, "(%w[%w_]*)=([^%s;]+)") do
    fields[k] = v
  end
  fields.kind = kind
  return fields
end

local function onLine(line)
  if string.sub(line, 1, 1) ~= " " then
    local kind = string.match(line, "^(%a+ ?%a*) time=")
    current = nil
    if kind == "method call" and string.find(line, "member=Notify", 1, true) then
      local h = header(line, kind)
      current = {
        type = "notify", key = h.sender .. "#" .. h.serial,
        strings = 0, app = "", appIcon = "", desktopEntry = "", imagePath = "", hintKey = nil,
      }
    elseif kind == "method return" then
      local h = header(line, kind)
      local key = (h.destination or "") .. "#" .. (h.reply_serial or "")
      if pending[key] then
        current = { type = "reply", msg = pending[key] }
        pending[key] = nil
      end
    elseif kind == "signal" and string.find(line, "member=NotificationClosed", 1, true) then
      current = { type = "closed", values = {} }
    end
    return
  end

  if current == nil then
    return
  end

  if current.type == "notify" then
    local top = string.match(line, "^   string \"(.*)\"$")
    if top then
      current.strings += 1
      if current.strings == 1 then
        current.app = top
      elseif current.strings == 2 then
        current.appIcon = top
      end
    end
    local hint = string.match(line, "^%s+string \"([%w%-]+)\"$")
    if hint == "desktop-entry" or hint == "image-path" then
      current.hintKey = hint
    end
    local value = string.match(line, "variant%s+string \"(.*)\"$")
    if value and current.hintKey then
      if current.hintKey == "desktop-entry" then
        current.desktopEntry = value
      else
        current.imagePath = value
      end
      current.hintKey = nil
    end
    if string.match(line, "^   int32 ") then
      pending[current.key] = current
      current = nil
    end
  elseif current.type == "reply" then
    local id = string.match(line, "^%s+uint32 (%d+)$")
    if id then
      addNotification(id, current.msg)
      current = nil
    end
  elseif current.type == "closed" then
    local v = string.match(line, "^%s+uint32 (%d+)$")
    if v then
      table.insert(current.values, v)
      if #current.values == 2 then
        local id, reason = current.values[1], current.values[2]
        -- reason 1 = toast expired; it is still unread in Noctalia's history
        if reason ~= "1" and notifs[id] then
          notifs[id] = nil
          publish()
        end
        current = nil
      end
    end
  end
end

noctalia.state.watch("deskclock.cmd", function(value)
  if value and string.sub(value, 1, 6) == "clear:" then
    notifs = {}
    order = {}
    publish()
  end
end)

-- noctalia msg plugin andiakbar/deskclock:notifs all dump
function onIpc(event)
  if event == "dump" then
    noctalia.log("unread apps: " .. (noctalia.json.encode(noctalia.state.get("deskclock.apps") or {}) or "?"))
  end
end

publish()
noctalia.runStream(
  "dbus-monitor --session \"interface='org.freedesktop.Notifications'\" \"type='method_return',sender='org.freedesktop.Notifications'\"",
  onLine
)
