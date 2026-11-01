--!nonstrict
-- CPU pill next to the clock (hover shows temperature and RAM); hidden while the stats are already on the bar.

local common = require("./lib/common.luau")

local hovered = false

local function render()
  if not common.covered() then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)
  local s = common.stats()
  local items = { common.stat("cpu", s.cpu) }
  if hovered then
    table.insert(items, common.stat("temperature", s.temp))
    table.insert(items, common.stat("cpu-2", s.ram))
  end
  barWidget.render(ui.row({ gap = 12, align = "center", onHover = "onHover" }, items))
end

function onHover(state)
  hovered = state == "true"
  render()
end

function update()
  render()
end

function onClick()
  noctalia.runAsync({ "noctalia", "msg", "panel-toggle", "control-center", "system" })
end

noctalia.state.watch("deskclock.covered", function()
  render()
end)

noctalia.setUpdateInterval(2000)
render()
