--!nonstrict
-- Shows the "desktop" bar while no window on the visible workspace overlaps the
-- desktop clock tile, and the "default" bar otherwise.

local CLOCK_WIDGET = "desktop_widgets.widget.deskclock"
local POLL_TICKS = 8 -- 8 x 250ms: catches mouse drags/resizes Hyprland sends no event for

local dirty = true
local busy = false
local ticks = 0
local covered = nil

local function clockRect()
  local w = noctalia.getSetting(CLOCK_WIDGET)
  if w == nil then
    return nil
  end
  local bw, bh = w.box_width or 0, w.box_height or 0
  return {
    x = (w.cx or 0) - bw / 2,
    y = (w.cy or 0) - bh / 2,
    w = bw,
    h = bh,
    output = w.output,
  }
end

local function overlaps(c, r)
  local x, y, w, h = c.at[1], c.at[2], c.size[1], c.size[2]
  return x < r.x + r.w and x + w > r.x and y < r.y + r.h and y + h > r.y
end

local function apply(isCovered)
  if isCovered == covered then
    return
  end
  covered = isCovered
  noctalia.state.set("deskclock.covered", isCovered)
end

local function evaluate()
  local rect = clockRect()
  if rect == nil then
    apply(true)
    return
  end
  busy = true
  local cmd = "printf '{\"monitors\":'; hyprctl -j monitors; printf ',\"clients\":'; hyprctl -j clients; printf '}'"
  noctalia.runAsync(cmd, function(result)
    busy = false
    if result.exitCode ~= 0 then
      return
    end
    local data = noctalia.json.decode(result.stdout)
    if data == nil then
      return
    end
    local visible = {}
    local monitorX, monitorY = 0, 0
    for _, m in ipairs(data.monitors) do
      if rect.output == nil or m.name == rect.output then
        visible[m.activeWorkspace.id] = true
        if m.specialWorkspace and m.specialWorkspace.id then
          visible[m.specialWorkspace.id] = true
        end
        monitorX, monitorY = m.x, m.y
      end
    end
    local abs = { x = rect.x + monitorX, y = rect.y + monitorY, w = rect.w, h = rect.h }
    local hit = false
    for _, c in ipairs(data.clients) do
      if c.mapped and not c.hidden and visible[c.workspace.id] and overlaps(c, abs) then
        hit = true
        break
      end
    end
    apply(hit)
  end)
end

function update()
  ticks += 1
  if ticks >= POLL_TICKS then
    ticks = 0
    dirty = true
  end
  if dirty and not busy then
    dirty = false
    evaluate()
  end
end

local runtime = noctalia.getenv("XDG_RUNTIME_DIR")
local signature = noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE")
if runtime and signature then
  noctalia.runStream(
    "socat -U - UNIX-CONNECT:" .. runtime .. "/hypr/" .. signature .. "/.socket2.sock",
    function(_line)
      dirty = true
    end
  )
else
  noctalia.log("deskclock: Hyprland socket not found; polling only")
end

noctalia.setUpdateInterval(250)
