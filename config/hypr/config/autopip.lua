-- Auto picture-in-picture: when leaving a workspace with a playing video, show it as a pinned PiP
-- so it follows you; it is restored when you return to its workspace (or press SUPER + SHIFT + P).
-- Firefox (not in fullscreen) uses its own PiP; everything else is shrunk and pinned.
-- On a workspace with no other windows the PiP is large (IDLE_SIZE), otherwise small; both centred.
-- Playing state comes from scripts/mpris-playing.sh (started in autostart.lua), which calls
-- M.playing_changed() through hyprctl; nothing polls while no video is on screen.

local PLAYING_FILE     = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/hypr-pip-playing"
local STATE_FILE       = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/hypr-pip-state"
local PIP_HEIGHT       = 0.25 -- fraction of monitor height
local IDLE_SIZE        = { w = 0.768, h = 0.769 } -- fractions of the monitor
local SKIP_WS          = { gaming = true }
local NATIVE_PIP_CLASS = "^firefox" -- Ctrl+Shift+] opens the browser's own PiP
local NATIVE_PIP_WAIT  = 2000 -- ms to wait for that PiP window before falling back
-- Apps whose playback is always video (they don't inhibit idle or set a content type)
local VIDEO_CLASSES    = { "^com%-nuvio%-app%-MainKt$", "^mpv$", "^vlc$" }
local SAMPLE_DELAY     = 1000 -- ms after a change before snapshotting idle inhibitors
local SAMPLE_POLL      = 5000 -- ms between snapshots while a playing window is on screen

local M              = {}
local prev_ws        = {} -- monitor id -> last active workspace id
local inhibit_cache  = {} -- window address -> inhibiting_idle while it was last on screen
local saved          = nil -- state of the current PiP (kind = "shrink" | "native")
local pending_native = nil -- native PiP we are waiting for
local fixup_timer    = nil
local relayout_timer = nil
local sample_delay   = nil -- delay of the pending snapshot timer (M.timer)

local function playing_pids()
    local pids = {}
    local f = io.open(PLAYING_FILE, "r")
    if not f then return pids end
    for line in f:lines() do
        local pid = tonumber(line)
        if pid then pids[pid] = true end
    end
    f:close()
    return pids
end

local playing = playing_pids()

local function is_video_app(w)
    for _, pat in ipairs(VIDEO_CLASSES) do
        if w.class:match(pat) then return true end
    end
    return false
end

local function is_pip_title(title)
    return title:match("^[Pp]icture[-%s]?[Ii]n[-%s]?[Pp]icture") ~= nil
end

-- Hidden surfaces may drop their idle inhibitor, so also use what we saw while visible
local function inhibiting(w)
    return w.inhibiting_idle or inhibit_cache[w.address] == true
end

local function video_hint(w)
    return inhibiting(w) or w.content_type == "video" or w.fullscreen == 2 or w.fullscreen_client == 2
end

-- Returns "native", "shrink" or nil
local function pip_kind(w, pids)
    if w.pinned or w.hidden or not w.mapped or w.content_type == "game" or is_pip_title(w.title) then return nil end

    if pids[w.pid] then
        if is_video_app(w) then return "shrink" end
        -- Firefox doesn't expose video playback in a normal window, so let its own PiP decide
        if w.fullscreen_client ~= 2 and w.class:match(NATIVE_PIP_CLASS) then return "native" end
        return video_hint(w) and "shrink" or nil
    end
    -- Fallback for players with neither MPRIS nor an audio stream
    return (w.content_type == "video" and inhibiting(w)) and "shrink" or nil
end

local function find_video(ws_id, mon)
    local pids = playing_pids()
    -- An app with a PiP already open is already following you (and the shortcut would toggle it off)
    for _, w in ipairs(hl.get_windows()) do
        if is_pip_title(w.title) then pids[w.pid] = nil end
    end
    local best, best_kind
    for _, w in ipairs(hl.get_windows()) do
        if w.workspace and w.workspace.id == ws_id and w.monitor and w.monitor.id == mon.id then
            local kind = pip_kind(w, pids)
            if kind and (not best or w.focus_history_id < best.focus_history_id) then best, best_kind = w, kind end
        end
    end
    return best, best_kind
end

local function pip_box(mon, aspect, min_w, idle)
    local mw, mh = mon.width / mon.scale, mon.height / mon.scale
    local res    = mon.reserved or {}
    local pw, ph
    if idle then
        pw, ph = math.floor(mw * IDLE_SIZE.w), math.floor(mh * IDLE_SIZE.h)
    else
        ph = math.floor(math.max(150, mh * PIP_HEIGHT))
        pw = math.floor(math.min(mw * 0.4, ph * aspect))
    end
    if min_w and min_w > pw then
        pw, ph = min_w, math.floor(min_w / aspect)
    end
    local left, top = res.left or 0, res.top or 0
    local uw, uh    = mw - left - (res.right or 0), mh - top - (res.bottom or 0)
    return pw, ph,
        math.floor(mon.x + left + (uw - pw) / 2),
        math.floor(mon.y + top + (uh - ph) / 2)
end

-- Pinned windows (the PiP itself) don't count
local function is_idle(mon)
    local ws = hl.get_active_workspace(mon)
    if not ws then return false end
    for _, w in ipairs(hl.get_windows()) do
        if w.workspace and w.workspace.id == ws.id and w.mapped and not w.hidden and not w.pinned then return false end
    end
    return true
end

local function place_pip(win, mon, aspect, min_w)
    local idle = is_idle(mon)
    local pw, ph, x, y = pip_box(mon, aspect, min_w, idle)
    hl.dispatch(hl.dsp.window.resize({ x = pw, y = ph, window = win }))
    hl.dispatch(hl.dsp.window.move({ x = x, y = y, relative = false, window = win }))
    if not saved then return end
    saved.idle = idle

    -- Apps with a minimum width (Firefox: 500) end up wider once they ack; refit keeping aspect
    local s, addr = saved, win.address
    fixup_timer = hl.timer(function()
        local cur = saved == s and hl.get_window("address:" .. addr)
        if not cur or cur.size.x <= pw then return end
        s.min_w = cur.size.x
        local npw, nph, nx, ny = pip_box(mon, aspect, s.min_w, idle)
        hl.dispatch(hl.dsp.window.resize({ x = npw, y = nph, window = cur }))
        hl.dispatch(hl.dsp.window.move({ x = nx, y = ny, relative = false, window = cur }))
    end, { timeout = 300, type = "oneshot" })
end

local function make_shrink(w, mon)
    saved = {
        kind     = "shrink",
        address  = w.address,
        ws_id    = w.workspace.id,
        ws_name  = w.workspace.name,
        floating = w.floating,
        at       = { x = w.at.x, y = w.at.y },
        size     = { x = w.size.x, y = w.size.y },
        fs       = w.fullscreen,
        fsc      = w.fullscreen_client,
        aspect   = w.size.x / math.max(1, w.size.y),
    }

    -- Keep the app in its own fullscreen (e.g. browser video-only view) while Hyprland treats it as windowed
    local fake_fs = hl.dsp.window.fullscreen_state({ internal = 0, client = w.fullscreen_client, window = w })
    if w.fullscreen ~= 0 then hl.dispatch(fake_fs) end
    if not w.floating then
        hl.dispatch(hl.dsp.window.float({ action = "on", window = w }))
    end
    place_pip(w, mon, saved.aspect)
    hl.dispatch(hl.dsp.window.pin({ action = "on", window = w }))
    -- float/pin reset the client fullscreen state, so re-apply it
    if saved.fsc ~= 0 then hl.dispatch(fake_fs) end
end

local function make_native(w, mon, hinted)
    local s = { kind = "native", address = w.address, ws_id = w.workspace.id, ws_name = w.workspace.name }
    saved = s

    local n = { s = s, pid = w.pid, mon = mon, existing = {} }
    for _, p in ipairs(hl.get_windows()) do n.existing[p.address] = true end
    local back_to = hl.get_active_window()
    n.back_to = back_to and back_to.address
    if pending_native then pending_native.timer:set_enabled(false) end
    pending_native = n

    hl.dispatch(hl.dsp.send_shortcut({ mods = "CTRL SHIFT", key = "bracketright", window = w }))

    n.timer = hl.timer(function()
        if pending_native ~= n then return end
        pending_native = nil
        if saved ~= s then return end
        saved = nil
        local win = hl.get_window("address:" .. s.address)
        if hinted and win and win.workspace and not win.workspace.visible then make_shrink(win, mon) end
    end, { timeout = NATIVE_PIP_WAIT, type = "oneshot" })
end

-- Called on window.open / window.title: the browser's PiP may get its title after mapping
local function adopt_native(p)
    local n = pending_native
    if not n or not p or p.pid ~= n.pid or n.existing[p.address] or not is_pip_title(p.title) then return end
    pending_native = nil
    n.timer:set_enabled(false)
    local s, addr = n.s, p.address

    -- Let window rules settle before placing it
    fixup_timer = hl.timer(function()
        local pip = hl.get_window("address:" .. addr)
        if not pip then return end
        -- Returned to the video before the PiP showed up
        if saved ~= s then
            hl.dispatch(hl.dsp.window.close({ window = pip }))
            return
        end
        s.pip_address = addr
        s.aspect = pip.size.x / math.max(1, pip.size.y)
        place_pip(pip, pip.monitor or n.mon, s.aspect)
        -- The PiP window steals focus; hand it back
        local back = n.back_to and hl.get_window("address:" .. n.back_to)
        if back and back.workspace and back.workspace.visible then
            hl.dispatch(hl.dsp.focus({ window = back }))
        end
    end, { timeout = 150, type = "oneshot" })
end

local function ws_selector(s)
    return s.ws_id > 0 and s.ws_id or ("name:" .. s.ws_name)
end

local function pip_window()
    if not saved then return nil end
    local addr = saved.kind == "native" and saved.pip_address or (saved.kind == "shrink" and saved.address)
    return addr and hl.get_window("address:" .. addr)
end

-- Only re-place when the workspace flips between empty and busy, so a dragged PiP stays put otherwise
local function relayout()
    local win = pip_window()
    if not win or not win.pinned or not win.monitor or is_idle(win.monitor) == saved.idle then return end
    place_pip(win, win.monitor, saved.aspect or (win.size.x / math.max(1, win.size.y)), saved.min_w)
end

-- Window events fire before the window is fully placed, so check a moment later
local function relayout_soon()
    if saved then relayout_timer = hl.timer(relayout, { timeout = 150, type = "oneshot" }) end
end

local function restore()
    local s = saved
    saved = nil
    if not s then return end

    if s.kind == "native" then
        -- Closing the browser's PiP puts the video back in its tab, still playing
        local pip = s.pip_address and hl.get_window("address:" .. s.pip_address)
        if pip then hl.dispatch(hl.dsp.window.close({ window = pip })) end
        return
    end

    local w = hl.get_window("address:" .. s.address)
    if not w then return end

    hl.dispatch(hl.dsp.window.pin({ action = "off", window = w }))
    local home = w.workspace and w.workspace.id == s.ws_id
    if not home then
        hl.dispatch(hl.dsp.window.move({ workspace = ws_selector(s), follow = false, window = w }))
    end
    if s.floating then
        hl.dispatch(hl.dsp.window.resize({ x = s.size.x, y = s.size.y, window = w }))
        hl.dispatch(hl.dsp.window.move({ x = s.at.x, y = s.at.y, relative = false, window = w }))
    else
        hl.dispatch(hl.dsp.window.float({ action = "off", window = w }))
    end
    if s.fs ~= 0 or s.fsc ~= 0 then
        hl.dispatch(hl.dsp.window.fullscreen_state({ internal = s.fs, client = s.fsc, window = w }))
    end
    if home then hl.dispatch(hl.dsp.focus({ window = w })) end
end

-- Closing the PiP only ends PiP; the window goes back to its workspace instead of closing the app
local function close_active()
    local w = hl.get_active_window()
    if saved and w and (w.address == saved.address or w.address == saved.pip_address) then
        restore()
    else
        hl.dispatch(hl.dsp.window.close())
    end
end

for _, m in ipairs(hl.get_monitors()) do
    if m.active_workspace then prev_ws[m.id] = m.active_workspace.id end
end

-- Config reloads reset Lua state, so carry the active PiP over through a file
local NUM_KEYS = { ws_id = true, fs = true, fsc = true, aspect = true, min_w = true, x = true, y = true }

hl.on("config.unload", function()
    if not saved then return end
    local f = io.open(STATE_FILE, "w")
    if not f then return end
    for k, v in pairs(saved) do
        if type(v) == "table" then
            f:write(k, ".x=", v.x, "\n", k, ".y=", v.y, "\n")
        else
            f:write(k, "=", tostring(v), "\n")
        end
    end
    f:close()
end)

local function load_state()
    local f = io.open(STATE_FILE, "r")
    if not f then return nil end
    local s = {}
    for line in f:lines() do
        local key, v = line:match("^([^=]+)=(.*)$")
        local parent, sub = (key or ""):match("^(%w+)%.([xy])$")
        local name = sub or key
        local val = v
        if NUM_KEYS[name] then
            val = tonumber(v)
        elseif name == "floating" or name == "idle" then
            val = v == "true"
        end
        if parent then
            s[parent] = s[parent] or {}
            s[parent][sub] = val
        elseif key then
            s[key] = val
        end
    end
    f:close()
    os.remove(STATE_FILE)
    return s
end

local resumed = load_state()
if resumed then
    local target = hl.get_window("address:" .. (resumed.pip_address or resumed.address or ""))
    if target and target.pinned then
        saved = resumed
        -- Window rules re-apply after the reload and re-center floating windows
        fixup_timer = hl.timer(function()
            local win = saved == resumed and hl.get_window("address:" .. (resumed.pip_address or resumed.address))
            if not win then return end
            place_pip(win, win.monitor, resumed.aspect or (win.size.x / math.max(1, win.size.y)), resumed.min_w)
            if resumed.kind == "shrink" and resumed.fsc ~= 0 then
                hl.dispatch(hl.dsp.window.fullscreen_state({ internal = 0, client = resumed.fsc, window = win }))
            end
        end, { timeout = 300, type = "oneshot" })
    end
end

-- Snapshot inhibitors of on-screen playing windows; keeps polling only while there are any
local schedule_sample
local function sample()
    M.timer, sample_delay = nil, nil
    local watching = false
    for _, w in ipairs(hl.get_windows()) do
        if w.workspace and w.workspace.visible and (playing[w.pid] or w.content_type == "video") then
            inhibit_cache[w.address] = w.inhibiting_idle
            watching = true
        end
    end
    if watching then schedule_sample(SAMPLE_POLL) end
end

-- An earlier pending snapshot wins; the timer lives in M so require() keeps it referenced
schedule_sample = function(delay)
    if M.timer and sample_delay <= delay then return end
    if M.timer then M.timer:set_enabled(false) end
    sample_delay = delay
    M.timer = hl.timer(sample, { timeout = delay, type = "oneshot" })
end

local function on_change()
    schedule_sample(SAMPLE_DELAY)
end

hl.on("workspace.active", function(ws)
    if not ws or ws.special or not ws.monitor then return end
    local mon     = ws.monitor
    local prev_id = prev_ws[mon.id]
    prev_ws[mon.id] = ws.id
    if prev_id == nil or prev_id == ws.id then return end
    on_change()

    if saved then
        if saved.ws_id == ws.id then restore() else relayout() end
        return
    end

    local prev = hl.get_workspace(prev_id)
    if prev and SKIP_WS[prev.name:gsub("^name:", "")] then return end

    local w, kind = find_video(prev_id, mon)
    if kind == "native" then
        make_native(w, mon, video_hint(w))
    elseif kind == "shrink" then
        make_shrink(w, mon)
    end
end)

hl.on("window.pin", function(w)
    if saved and saved.kind == "shrink" and w and w.address == saved.address and not w.pinned then saved = nil end
end)

hl.on("window.close", function(w)
    if not w then return end
    inhibit_cache[w.address] = nil
    if saved and (w.address == saved.address or w.address == saved.pip_address) then saved = nil end
    relayout_soon()
end)

hl.on("window.move_to_workspace", relayout_soon)

hl.on("window.open", function(w)
    adopt_native(w)
    relayout_soon()
    on_change()
end)
hl.on("window.title", adopt_native)
hl.on("window.fullscreen", on_change)

M.close_active = close_active
function M.playing_changed()
    playing = playing_pids()
    on_change()
end
on_change()

hl.bind("SUPER + SHIFT + P", function()
    if not saved then return end
    hl.dispatch(hl.dsp.focus({ workspace = ws_selector(saved) }))
end)

return M
