--!nonstrict
-- Clock while a window covers the desktop clock; CPU / temperature / RAM otherwise.

local common = require("./lib/common.luau")

local function render()
  if common.covered() then
    barWidget.render(ui.label({
      text = noctalia.formatTime("{:%a, %d/%m/%y %H:%M}"),
      fontFamily = "JetBrainsMono Nerd Font Propo",
      fontWeight = "semibold",
    }))
  else
    local s = common.stats()
    barWidget.render(ui.row({ gap = 14, align = "center" }, {
      common.stat("cpu", s.cpu),
      common.stat("temperature", s.temp),
      common.stat("cpu-2", s.ram),
    }))
  end
end

function update()
  render()
end

-- Same targets as the built-in clock and sysmon widgets
function onClick()
  local tab = common.covered() and "calendar" or "system"
  noctalia.runAsync({ "noctalia", "msg", "panel-toggle", "control-center", tab })
end

noctalia.state.watch("deskclock.covered", function()
  render()
end)

noctalia.setUpdateInterval(1000)
render()
