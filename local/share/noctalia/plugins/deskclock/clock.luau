--!nonstrict
-- Desktop tile: date, time, and one icon per app with unread notifications.

local apps = noctalia.state.get("deskclock.apps") or {}

local function render()
  local rows = {
    ui.label({
      text = noctalia.formatTime("{:%A, %d %B %Y}"),
      fontSize = 17,
      color = "on_surface/0.8",
    }),
    ui.label({
      text = noctalia.formatTime("{:%H:%M}"),
      fontSize = 64,
      fontWeight = "bold",
      fontFamily = "JetBrainsMono Nerd Font Propo",
      color = "on_surface",
    }),
  }

  if #apps > 0 then
    local icons = {}
    for _, app in ipairs(apps) do
      if app.icon then
        table.insert(icons, ui.image({ key = app.name, path = app.icon, width = 22, height = 22 }))
      else
        table.insert(icons, ui.glyph({ key = app.name, name = "bell", size = 20 }))
      end
    end
    table.insert(rows, ui.row({
      gap = 10,
      align = "center",
      justify = "center",
      onClick = "onIconsClicked",
    }, icons))
  end

  desktopWidget.render(ui.column({ gap = 6, align = "center", justify = "center" }, rows))
end

function update()
  render()
end

function onIconsClicked()
  noctalia.state.set("deskclock.cmd", "clear:" .. tostring(noctalia.nowMs()))
  noctalia.runAsync({ "noctalia", "msg", "panel-toggle", "control-center", "notifications" })
end

noctalia.state.watch("deskclock.apps", function(value)
  apps = value or {}
  render()
end)

desktopWidget.setWantsSecondTicks(true)
render()
