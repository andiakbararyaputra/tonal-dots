--!nonstrict
-- Shared formatting for the bar widgets.

local M = {}

function M.covered()
  local value = noctalia.state.get("deskclock.covered")
  return value ~= false
end

function M.stats()
  local s = noctalia.systemStats()
  local out = { cpu = "--%", temp = "--°C", ram = "-- GiB" }
  if s == nil then
    return out
  end
  if s.cpu and s.cpu.usagePercent then
    out.cpu = string.format("%d%%", math.floor(s.cpu.usagePercent + 0.5))
  end
  if s.cpu and s.cpu.tempC then
    out.temp = string.format("%d°C", math.floor(s.cpu.tempC + 0.5))
  end
  if s.ram and s.ram.usedMb then
    out.ram = string.format("%.1f GiB", s.ram.usedMb / 1024)
  end
  return out
end

function M.stat(glyph, text)
  return ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = glyph, size = 15 }),
    ui.label({ text = text }),
  })
end

return M
