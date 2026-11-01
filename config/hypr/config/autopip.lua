-- Auto picture-in-picture: when leaving a workspace with a playing video, show it as a pinned PiP
-- so it follows you; it is restored when you return to its workspace (or press SUPER + SHIFT + P).
-- Firefox (not in fullscreen) uses its own PiP; everything else is shrunk and pinned.
-- Playing state comes from scripts/mpris-playing.sh (started in autostart.lua).

local PLAYING_FILE     = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/hypr-pip-playing"
local STATE_FILE       = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/hypr-pip-state"
local PIP_HEIGHT       = 0.25 -- fraction of monitor height
local SKIP_WS          = { gaming = true }
local NATIVE_PIP_CLASS = "^firefox" -- Ctrl+Shift+] opens the browser's own PiP
local NATIVE_PIP_WAIT  = 2000 -- ms to wait for that PiP window before falling back

local prev_ws       = {} -- monitor id -> last active workspace id
local inhibit_cache = {} -- window address -> inhibiting_idle while it was last on screen
local saved         = nil -- state of the current PiP (kind = "shrink" | "native")
local native_timer  = nil
local fixup_timer   = nil

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
        -- Firefox doesn't expose video playback in a normal window, so let its own PiP decide
        if w.fullscreen_client ~= 2 and w.class:match(NATIVE_PIP_CLASS) then return "native" end
        return video_hint(w) and "shrink" or nil
    end
    -- Players without MPRIS (e.g. mpv without mpv-mpris) only inhibit idle while playing
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

local function pip_box(mon, aspect, min_w)
    local mw, mh = mon.width / mon.scale, mon.height / mon.scale
    local res    = mon.reserved or {}
    local ph     = math.floor(math.max(150, mh * PIP_HEIGHT))
    local pw     = math.floor(math.min(mw * 0.4, ph * aspect))
    if min_w and min_w > pw then
        pw, ph = min_w, math.floor(min_w / aspect)
    end
    local left, top = res.left or 0, res.top or 0
    local uw, uh    = mw - left - (res.right or 0), mh - top - (res.bottom or 0)
    return pw, ph,
        math.floor(mon.x + left + (uw - pw) / 2),
        math.floor(mon.y + top + (uh - ph) / 2)
end

local function place_pip(win, mon, aspect, min_w)
    local pw, ph, x, y = pip_box(mon, aspect, min_w)
    hl.dispatch(hl.dsp.window.resize({ x = pw, y = ph, window = win }))
    hl.dispatch(hl.dsp.window.move({ x = x, y = y, relative = false, window = win }))
    return pw
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
    local pw = place_pip(w, mon, saved.aspect)
    hl.dispatch(hl.dsp.window.pin({ action = "on", window = w }))
    -- float/pin reset the client fullscreen state, so re-apply it
    if saved.fsc ~= 0 then hl.dispatch(fake_fs) end

    -- Apps with a minimum width (Firefox: 500) end up wider once they ack; refit keeping aspect
    local s = saved
    fixup_timer = hl.timer(function()
        local cur = saved == s and hl.get_window("address:" .. s.address)
        if not cur or cur.size.x <= pw then return end
        s.min_w = cur.size.x
        place_pip(cur, mon, s.aspect, s.min_w)
    end, { timeout = 300, type = "oneshot" })
end

local function make_native(w, mon, hinted)
    local s = { kind = "native", address = w.address, ws_id = w.workspace.id, ws_name = w.workspace.name }
    saved = s

    local existing = {}
    for _, p in ipairs(hl.get_windows()) do existing[p.address] = true end
    local back_to = hl.get_active_window()

    hl.dispatch(hl.dsp.send_shortcut({ mods = "CTRL SHIFT", key = "bracketright", window = w }))

    local waited, pid = 0, w.pid
    if native_timer then native_timer:set_enabled(false) end
    local timer
    timer = hl.timer(function()
        waited = waited + 200
        local pip
        for _, p in ipairs(hl.get_windows()) do
            if p.pid == pid and not existing[p.address] and is_pip_title(p.title) then pip = p end
        end
        if pip or waited >= NATIVE_PIP_WAIT then timer:set_enabled(false) end

        -- Returned to the video before the PiP showed up
        if saved ~= s then
            if pip then hl.dispatch(hl.dsp.window.close({ window = pip })) end
            return
        end

        if pip then
            s.pip_address = pip.address
            s.aspect = pip.size.x / math.max(1, pip.size.y)
            place_pip(pip, pip.monitor or mon, s.aspect)
            -- The PiP window steals focus; hand it back
            local back = back_to and hl.get_window("address:" .. back_to.address)
            if back and back.workspace and back.workspace.visible then
                hl.dispatch(hl.dsp.focus({ window = back }))
            end
        elseif waited >= NATIVE_PIP_WAIT then
            saved = nil
            local win = hl.get_window("address:" .. s.address)
            if hinted and win and win.workspace and not win.workspace.visible then make_shrink(win, mon) end
        end
    end, { timeout = 200, type = "repeat" })
    native_timer = timer
end

local function ws_selector(s)
    return s.ws_id > 0 and s.ws_id or ("name:" .. s.ws_name)
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
        elseif name == "floating" then
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

hl.on("workspace.active", function(ws)
    if not ws or ws.special or not ws.monitor then return end
    local mon     = ws.monitor
    local prev_id = prev_ws[mon.id]
    prev_ws[mon.id] = ws.id
    if prev_id == nil or prev_id == ws.id then return end

    if saved then
        if saved.ws_id == ws.id then restore() end
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
end)

local cache_timer = hl.timer(function()
    for _, w in ipairs(hl.get_windows()) do
        if w.workspace and w.workspace.visible then inhibit_cache[w.address] = w.inhibiting_idle end
    end
end, { timeout = 1000, type = "repeat" })

hl.bind("SUPER + SHIFT + P", function()
    if not saved then return end
    hl.dispatch(hl.dsp.focus({ workspace = ws_selector(saved) }))
end)

-- timer is returned so require() keeps it referenced
return { timer = cache_timer, close_active = close_active }
