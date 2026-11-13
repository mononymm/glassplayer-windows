-- Glass — a custom interface for mpv
-- Glass-style floating controls, glow, click-to-pause, playlist, audio & subtitle menus.
-- Settings: script-opts/glass.conf

local mp = require 'mp'
local options = require 'mp.options'
local utils = require 'mp.utils'

local opts = {
    scale = 1.0,                 -- overall size (multiplied by Windows display scaling)
    font = "Inter",
    accent = "F0302C",           -- colors are RRGGBB
    tint = "14161C",             -- glass tint color
    glass_opacity = 0.75,        -- how dark/solid the glass is (0-1)
    text = "F5F6F8",
    muted = "9AA0AE",
    glow = true,
    glow_strength = 1.0,
    fade_in = 90,                -- ms
    fade_out = 160,              -- ms
    hide_timeout = 900,          -- ms without mouse movement before controls hide
    show_when_paused = true,
    click_to_pause = true,
    double_click_fullscreen = true,
    playlist_push_video = false, -- shrink the video to make room for the playlist
    playlist_width = 340,
    wheel_volume_step = 5,
    library_folders = "",      -- folders for the library page, separated by ; (empty = your Videos folder)
    history_size = 100,
    -- Plex (read-only): path to Plex's library database, and Plex's bundled SQLite tool
    plex_db = "",
    plex_sqlite = "C:\\Program Files\\Plex\\Plex Media Server\\Plex SQLite.exe",
    plex_account = 1,             -- 1 = the server's admin account
    watched_at = 0.90,            -- past this fraction of the runtime counts as watched (matches the Plex sync)
    -- shared folder where mpv leaves watch progress for the Plex sync script (empty = don't sync)
    sync_folder = "C:\\Users\\Public\\GlassSync",
    -- on the profile that runs Plex: send progress to Plex as soon as a video stops (runs the sync script)
    sync_now = false,
    -- upscaling shaders (files in your mpv\shaders folder, separated by commas)
    anime_shaders = "ArtCNN_C4F16.glsl,KrigBilateral.glsl,SSimDownscaler.glsl",
    live_shaders = "FSRCNNX_x2_16-0-4-1.glsl,KrigBilateral.glsl,SSimDownscaler.glsl",
    anime_folders = "Anime,Unsorted", -- a path containing any of these words uses the anime shaders
}
options.read_options(opts, "glass")

-- ---------------------------------------------------------------- state
local ov = mp.create_osd_overlay("ass-events")
local W, H, S = 0, 0, 1
local P = {}
local mouse = { x = -1, y = -1, hover = false }
local last_move = -100
local anim = { ui = 0, playlist = 0, menu = 0, seek = 0, vol = 0 }
local hv = {}
local playlist_open = false
local pl_scroll = 0
local pl_group_open, pl_group_anim, pl_jump = {}, {}, false
local plv = { target = nil, prev = nil, shown = 0, wheel = false } -- playlist panel smooth scrolling
local menu, menu_last = nil, nil
local dragging = nil
local hits = {}
local last_down_video = false
local flash = { t = -10, icon = "play" }
local last_margin = -1
local timer
local last_tick = mp.get_time()

-- ---------------------------------------------------------------- helpers
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function ease(t) return t * t * (3 - 2 * t) end
local function step(cur, target, dt, ms)
    if ms <= 0 then return target end
    local d = dt / (ms / 1000)
    if cur < target then return math.min(target, cur + d) end
    return math.max(target, cur - d)
end
local animating = false
local function hover_anim(id, on, dt)
    hv[id] = step(hv[id] or 0, on and 1 or 0, dt, 110)
    if hv[id] ~= (on and 1 or 0) then animating = true end
    return ease(hv[id])
end

local function bgr(hex) return hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2) end
local function col(hex, op)
    local a = math.floor(255 * (1 - clamp(op, 0, 1)) + 0.5)
    return string.format("\\1c&H%s&\\1a&H%02X&", bgr(hex), a)
end
local function f(n) return string.format("%.1f", n) end
local function esc(s)
    s = tostring(s or ""):gsub("[\r\n]+", " ")
    return (s:gsub("\\", "\\\239\187\191"):gsub("{", "\\{"):gsub("^ ", "\\h"))
end
local function clipr(x1, y1, x2, y2)
    return string.format("\\clip(%d,%d,%d,%d)", math.floor(x1), math.floor(y1), math.ceil(x2), math.ceil(y2))
end
local function fmt_time(t)
    t = math.floor(math.max(0, t or 0))
    local h, m, s = math.floor(t / 3600), math.floor(t % 3600 / 60), t % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

-- drawing primitives -------------------------------------------------
local out
local function shape(c, path, clip)
    if path == "" then return end
    out[#out + 1] = "{\\an7\\pos(0,0)\\bord0\\shad0\\blur0" .. (clip or "") .. c .. "\\p1}" .. path .. "{\\p0}"
end
local function shapes(c, paths, clip)
    for _, p in ipairs(paths) do shape(c, p, clip) end
end
local function text(x, y, an, size, c, str, weight, clip)
    out[#out + 1] = string.format("{\\an%d\\pos(%s,%s)\\fn%s\\fs%s\\b%d\\bord0\\shad0\\blur0%s%s}%s",
        an, f(x), f(y), opts.font, f(size), weight or 400, clip or "", c, esc(str))
end

-- text measuring (asks libass for real widths; falls back to an estimate)
local measure_ov = mp.create_osd_overlay("ass-events")
measure_ov.hidden = true
measure_ov.compute_bounds = true
local measure_cache = {}
local function text_width(str, size, weight)
    local key = str .. "\0" .. f(size) .. "\0" .. (weight or 400)
    local c = measure_cache[key]
    if c then return c end
    local w
    if W > 0 and H > 0 then
        measure_ov.res_x, measure_ov.res_y = W, H
        measure_ov.data = string.format("{\\an7\\pos(0,0)\\fn%s\\fs%s\\b%d\\bord0\\shad0\\q2}%s", opts.font, f(size), weight or 400, esc(str))
        local ok, r = pcall(function() return measure_ov:update() end)
        if ok and type(r) == "table" and r.x1 and r.x0 then w = r.x1 - r.x0 end
    end
    if not w then
        w = 0
        for ch in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            if ch == " " then w = w + 0.28
            elseif ch:match("[A-Z0-9]") then w = w + 0.66
            elseif ch:match("[iljt%.,:;'|!%(%)%[%]]") then w = w + 0.32
            else w = w + 0.55 end
        end
        w = w * size * ((weight or 400) >= 600 and 1.04 or 1)
    end
    measure_cache[key] = w
    return w
end

local function utf8_chars(str)
    local t = {}
    for ch in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do t[#t + 1] = ch end
    return t
end
local function rtrim(s_) return (s_:gsub("%s+$", "")) end

-- split a title into two lines; breaks at spaces and after . _ -
local wrap_cache = {}
local function wrap2(str, maxw, size, weight)
    local key = str .. "\0" .. math.floor(maxw) .. "\0" .. f(size)
    local c = wrap_cache[key]
    if c then return c[1], c[2], c[3], c[4] end
    local toks = {}
    local lead = str:match("^[ ._%-]+") or ""
    for tok in str:sub(#lead + 1):gmatch("[^ ._%-]+[ ._%-]*") do toks[#toks + 1] = tok end
    if #toks == 0 then toks[1] = str end
    toks[1] = lead .. toks[1]
    local line1, i = "", 1
    while i <= #toks do
        local cand = line1 .. toks[i]
        if line1 == "" or text_width(rtrim(cand), size, weight) <= maxw then line1 = cand; i = i + 1 else break end
    end
    local rest = table.concat(toks, "", i)
    line1 = rtrim(line1)
    local short2, overflow = nil, false
    if rest ~= "" then
        if text_width(rest, size, weight) <= maxw then
            short2 = rest
        else
            overflow = true
            local chars = utf8_chars(rest)
            local lo, hi = 0, #chars
            while lo < hi do
                local mid = math.floor((lo + hi + 1) / 2)
                if text_width(rtrim(table.concat(chars, "", 1, mid)) .. "…", size, weight) <= maxw then lo = mid else hi = mid - 1 end
            end
            short2 = rtrim(table.concat(chars, "", 1, lo)) .. "…"
        end
    end
    wrap_cache[key] = { line1, rest ~= "" and rest or nil, short2, overflow }
    return line1, rest ~= "" and rest or nil, short2, overflow
end

-- one line of text that scrolls sideways while hovered if it doesn't fit
local marquee_start = {}
local function marquee(id, x, y, size, c, str, weight, maxw, clip_y1, clip_y2, hovered)
    local tw = text_width(str, size, weight)
    local clip = clipr(x, clip_y1, x + maxw, clip_y2)
    if tw <= maxw or not hovered then
        marquee_start[id] = nil
        local shown = str
        if tw > maxw then
            local chars = utf8_chars(str)
            local lo, hi = 0, #chars
            while lo < hi do
                local mid = math.floor((lo + hi + 1) / 2)
                if text_width(rtrim(table.concat(chars, "", 1, mid)) .. "…", size, weight) <= maxw then lo = mid else hi = mid - 1 end
            end
            shown = rtrim(table.concat(chars, "", 1, lo)) .. "…"
        end
        text(x, y, 4, size, c, shown, weight, clip)
        return
    end
    local now = mp.get_time()
    marquee_start[id] = marquee_start[id] or now
    local dist = tw - maxw + 12 * S
    local speed = 45 * S
    local cycle = 0.7 + dist / speed + 1.2
    local tt = (now - marquee_start[id]) % cycle
    local off = clamp((tt - 0.7) * speed, 0, dist)
    text(x - off, y, 4, size, c, str, weight, clip)
    animating = true
end

local function poly(pts)
    local s = "m " .. f(pts[1]) .. " " .. f(pts[2])
    for i = 3, #pts, 2 do s = s .. " l " .. f(pts[i]) .. " " .. f(pts[i + 1]) end
    return s .. " "
end
local function rrect(x, y, w, h, r)
    if w <= 0 or h <= 0 then return "" end
    r = math.min(r or 0, w / 2, h / 2)
    if r <= 0.05 then return poly({ x, y, x + w, y, x + w, y + h, x, y + h }) end
    local k = r * 0.4477
    local x2, y2 = x + w, y + h
    return "m " .. f(x + r) .. " " .. f(y) ..
        " l " .. f(x2 - r) .. " " .. f(y) ..
        " b " .. f(x2 - k) .. " " .. f(y) .. " " .. f(x2) .. " " .. f(y + k) .. " " .. f(x2) .. " " .. f(y + r) ..
        " l " .. f(x2) .. " " .. f(y2 - r) ..
        " b " .. f(x2) .. " " .. f(y2 - k) .. " " .. f(x2 - k) .. " " .. f(y2) .. " " .. f(x2 - r) .. " " .. f(y2) ..
        " l " .. f(x + r) .. " " .. f(y2) ..
        " b " .. f(x + k) .. " " .. f(y2) .. " " .. f(x) .. " " .. f(y2 - k) .. " " .. f(x) .. " " .. f(y2 - r) ..
        " l " .. f(x) .. " " .. f(y + r) ..
        " b " .. f(x) .. " " .. f(y + k) .. " " .. f(x + k) .. " " .. f(y) .. " " .. f(x + r) .. " " .. f(y) .. " "
end
local function circle(cx, cy, r) return rrect(cx - r, cy - r, 2 * r, 2 * r, r) end
local function box(x1, y1, x2, y2)
    return poly({ math.min(x1, x2), math.min(y1, y2), math.max(x1, x2), math.min(y1, y2),
        math.max(x1, x2), math.max(y1, y2), math.min(x1, x2), math.max(y1, y2) })
end
local function line(x1, y1, x2, y2, t)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len == 0 then return "" end
    local nx, ny = -dy / len * t / 2, dx / len * t / 2
    return poly({ x1 + nx, y1 + ny, x2 + nx, y2 + ny, x2 - nx, y2 - ny, x1 - nx, y1 - ny })
end
local function arc(cx, cy, r, t, a0, a1)
    local pts, n = {}, 14
    for i = 0, n do
        local a = a0 + (a1 - a0) * i / n
        pts[#pts + 1] = cx + math.cos(a) * (r + t / 2); pts[#pts + 1] = cy + math.sin(a) * (r + t / 2)
    end
    for i = n, 0, -1 do
        local a = a0 + (a1 - a0) * i / n
        pts[#pts + 1] = cx + math.cos(a) * (r - t / 2); pts[#pts + 1] = cy + math.sin(a) * (r - t / 2)
    end
    return poly(pts)
end

-- icons: each returns a list of non-overlapping paths --------------------
local I = {}
function I.play(x, y, u) return { poly({ x - 5 * u, y - 8 * u, x + 8 * u, y, x - 5 * u, y + 8 * u }) } end
function I.pause(x, y, u)
    return { rrect(x - 6 * u, y - 7.5 * u, 4 * u, 15 * u, u), rrect(x + 2 * u, y - 7.5 * u, 4 * u, 15 * u, u) }
end
-- Icons are placed by their visual weight, not their bounding box: a shape with more ink on one
-- side is nudged the other way so it looks centered in its button.
function I.prev(x, y, u)
    x = x + 0.3 * u
    return { rrect(x - 7 * u, y - 7 * u, 2.5 * u, 14 * u, u), poly({ x + 7 * u, y - 7 * u, x - 3 * u, y, x + 7 * u, y + 7 * u }) }
end
function I.seg_prev(x, y, u)
    x = x - 0.75 * u
    return { poly({ x - 9 * u, y, x, y - 6.5 * u, x, y + 6.5 * u }), poly({ x, y, x + 9 * u, y - 6.5 * u, x + 9 * u, y + 6.5 * u }) }
end
function I.seg_next(x, y, u)
    x = x + 0.75 * u
    return { poly({ x + 9 * u, y, x, y - 6.5 * u, x, y + 6.5 * u }), poly({ x, y, x - 9 * u, y - 6.5 * u, x - 9 * u, y + 6.5 * u }) }
end
function I.skip_back(x, y, u)
    local r = 9 * u
    return { arc(x, y, r, 1.8 * u, math.rad(-90), math.rad(205)),
        poly({ x - 3.2 * u, y - r, x + 1.8 * u, y - r - 3.6 * u, x + 1.8 * u, y - r + 3.6 * u }) }
end
function I.skip_fwd(x, y, u)
    local r = 9 * u
    return { arc(x, y, r, 1.8 * u, math.rad(-25), math.rad(270)),
        poly({ x + 3.2 * u, y - r, x - 1.8 * u, y - r - 3.6 * u, x - 1.8 * u, y - r + 3.6 * u }) }
end
function I.stop(x, y, u) return { rrect(x - 6.5 * u, y - 6.5 * u, 13 * u, 13 * u, 2.5 * u) } end
function I.chap_prev(x, y, u)
    return { rrect(x - 8 * u, y - 7 * u, 2.2 * u, 14 * u, u),
        line(x + 1 * u, y - 6 * u, x - 4 * u, y, 2 * u), line(x - 4 * u, y, x + 1 * u, y + 6 * u, 2 * u),
        line(x + 7 * u, y - 6 * u, x + 2 * u, y, 2 * u), line(x + 2 * u, y, x + 7 * u, y + 6 * u, 2 * u) }
end
function I.chap_next(x, y, u)
    return { rrect(x + 5.8 * u, y - 7 * u, 2.2 * u, 14 * u, u),
        line(x - 1 * u, y - 6 * u, x + 4 * u, y, 2 * u), line(x + 4 * u, y, x - 1 * u, y + 6 * u, 2 * u),
        line(x - 7 * u, y - 6 * u, x - 2 * u, y, 2 * u), line(x - 2 * u, y, x - 7 * u, y + 6 * u, 2 * u) }
end
function I.next(x, y, u)
    x = x - 0.3 * u
    return { rrect(x + 4.5 * u, y - 7 * u, 2.5 * u, 14 * u, u), poly({ x - 7 * u, y - 7 * u, x + 3 * u, y, x - 7 * u, y + 7 * u }) }
end
function I.volume(x, y, u, level, muted)
    local p = { poly({ x - 9 * u, y - 3.5 * u, x - 5 * u, y - 3.5 * u, x, y - 8 * u, x, y + 8 * u, x - 5 * u, y + 3.5 * u, x - 9 * u, y + 3.5 * u }) }
    if muted then
        p[#p + 1] = line(x + 3 * u, y - 4 * u, x + 9 * u, y + 4 * u, 1.8 * u)
        p[#p + 1] = line(x + 9 * u, y - 4 * u, x + 3 * u, y + 4 * u, 1.8 * u)
    else
        if level > 0 then p[#p + 1] = arc(x + 1 * u, y, 4 * u, 1.8 * u, -0.9, 0.9) end
        if level > 50 then p[#p + 1] = arc(x + 1 * u, y, 8 * u, 1.8 * u, -0.9, 0.9) end
    end
    return p
end
function I.fullscreen(x, y, u, exit)
    local p, a, l, t = {}, 8 * u, 5.5 * u, 2 * u
    for _, sx in ipairs({ -1, 1 }) do
        for _, sy in ipairs({ -1, 1 }) do
            local px, py, dx, dy
            if exit then px, py, dx, dy = x + sx * 2.5 * u, y + sy * 2.5 * u, sx, sy
            else px, py, dx, dy = x + sx * a, y + sy * a, -sx, -sy end
            p[#p + 1] = box(px, py, px + dx * l, py + dy * t)
            p[#p + 1] = box(px, py + dy * t, px + dx * t, py + dy * l)
        end
    end
    return p
end
function I.playlist(x, y, u)
    -- two full lines, a short one and a play triangle; balanced so the triangle doesn't drag it down-right
    x, y = x - 0.3 * u, y + 0.1 * u
    return { rrect(x - 9 * u, y - 7 * u, 18 * u, 2 * u, u), rrect(x - 9 * u, y - 2 * u, 18 * u, 2 * u, u),
        rrect(x - 9 * u, y + 3 * u, 10 * u, 2 * u, u), poly({ x + 3.5 * u, y + 1 * u, x + 9.5 * u, y + 4.5 * u, x + 3.5 * u, y + 8 * u }) }
end
function I.subs(x, y, u)
    local t = 1.8 * u
    return { box(x - 10 * u, y - 7 * u, x + 10 * u, y - 7 * u + t), box(x - 10 * u, y + 7 * u - t, x + 10 * u, y + 7 * u),
        box(x - 10 * u, y - 7 * u + t, x - 10 * u + t, y + 7 * u - t), box(x + 10 * u - t, y - 7 * u + t, x + 10 * u, y + 7 * u - t),
        rrect(x - 6 * u, y - 1.5 * u, 4.5 * u, 2 * u, u), rrect(x - 0.5 * u, y - 1.5 * u, 6.5 * u, 2 * u, u),
        rrect(x - 6 * u, y + 2 * u, 8 * u, 2 * u, u), rrect(x + 3.5 * u, y + 2 * u, 2.5 * u, 2 * u, u) }
end
function I.audio(x, y, u)
    -- beamed eighth notes: equal heads, parallel stems, a gently slanted beam.
    -- The heads carry most of the weight (bottom-left), so the whole note sits a little up and left.
    x, y = x - 0.6 * u, y - 0.35 * u
    return { circle(x - 5 * u, y + 5 * u, 3.1 * u), circle(x + 5 * u, y + 4 * u, 3.1 * u),
        box(x - 3.5 * u, y - 5 * u, x - 1.9 * u, y + 5 * u), box(x + 6.5 * u, y - 6 * u, x + 8.1 * u, y + 4 * u),
        poly({ x - 3.5 * u, y - 5.2 * u, x + 8.1 * u, y - 8.2 * u, x + 8.1 * u, y - 5.6 * u, x - 3.5 * u, y - 2.6 * u }) }
end
function I.close(x, y, u)
    return { line(x - 5 * u, y - 5 * u, x + 5 * u, y + 5 * u, 1.8 * u) }, { line(x + 5 * u, y - 5 * u, x - 5 * u, y + 5 * u, 1.8 * u) }
end

-- ---------------------------------------------------------------- data
local function tracks(kind)
    local r = {}
    for _, t in ipairs(P["track-list"] or {}) do if t.type == kind then r[#r + 1] = t end end
    return r
end
local function track_label(t)
    local parts = {}
    if t.title and t.title ~= "" then parts[#parts + 1] = t.title end
    if t.lang and t.lang ~= "" then parts[#parts + 1] = t.lang:upper() end
    local s = table.concat(parts, " · ")
    if s == "" then s = (t.type == "sub" and "Subtitle " or "Track ") .. t.id end
    if t.external then s = s .. "  (file)" end
    return s
end
local meta_title -- assigned in the library section
local episode_title -- assigned in the library section
local plex_entry_title -- assigned in the Plex section
local function entry_name(e)
    local pt = plex_entry_title and plex_entry_title(e.filename)
    if pt then return pt end
    if e.title and e.title ~= "" then return e.title end
    local mt = meta_title and meta_title(e.filename)
    if mt then return mt end
    local name = (e.filename or ""):match("([^/\\]+)$") or e.filename or "?"
    if not name:find("://") then name = name:gsub("%.[%w]+$", "") end
    return name
end

-- ---------------------------------------------------------------- hit areas
local function inside(x1, y1, x2, y2)
    return mouse.hover and mouse.x >= x1 and mouse.x <= x2 and mouse.y >= y1 and mouse.y <= y2
end
local function add_hit(x1, y1, x2, y2, down, extra)
    local h = extra or {}
    h.x1, h.y1, h.x2, h.y2, h.down = x1, y1, x2, y2, down
    hits[#hits + 1] = h
end

-- ---------------------------------------------------------------- actions
local dirty = true
local function request()
    dirty = true
    if timer and not timer:is_enabled() then
        last_tick = mp.get_time()
        timer:resume()
    end
end
local function toggle_pause()
    mp.commandv("cycle", "pause")
    flash.t = mp.get_time()
    flash.icon = P.pause and "play" or "pause" -- state before the toggle lands
    request()
end
local function toggle_playlist()
    playlist_open = not playlist_open
    if playlist_open then pl_jump = true end
    request()
end
local function open_menu(kind, ax)
    if menu and menu.kind == kind then menu = nil
    else menu = { kind = kind, ax = ax } end
    request()
end

local seek_geom = { x1 = 0, x2 = 1 }
local vol_geom = { x1 = 0, x2 = 1 }
local function seek_from_mouse(final)
    local frac = clamp((mouse.x - seek_geom.x1) / (seek_geom.x2 - seek_geom.x1), 0, 1)
    mp.commandv("seek", tostring(frac * 100), final and "absolute-percent+exact" or "absolute-percent+keyframes")
end
local function volume_from_mouse()
    local frac = clamp((mouse.x - vol_geom.x1) / (vol_geom.x2 - vol_geom.x1), 0, 1)
    mp.set_property_number("volume", math.floor(frac * 100 + 0.5))
    if P.mute then mp.set_property_bool("mute", false) end
end

-- ---------------------------------------------------------------- glass drawing
local function emit(tags, path, clip)
    if path == "" then return end
    out[#out + 1] = "{\\an7\\pos(0,0)\\shad0" .. (clip or "") .. tags .. "\\p1}" .. path .. "{\\p0}"
end
local function fill(hex, op, path, blur, clip)
    if op <= 0.003 then return end
    emit("\\bord0\\blur" .. f(blur or 0) .. col(hex, op), path, clip)
end
local function stroke(hex, op, width, path, blur, clip)
    if op <= 0.003 then return end
    local al = math.floor(255 * (1 - clamp(op, 0, 1)) + 0.5)
    emit(string.format("\\1a&HFF&\\3c&H%s&\\3a&H%02X&\\bord%s\\blur%s", bgr(hex), al, f(width), f(blur or 0)), path, clip)
end
local function glow(hex, op, path, blur)
    if not opts.glow then return end
    fill(hex, clamp(op * opts.glow_strength, 0, 1), path, blur)
end
local function solid_bubble(x, y, w, h, r, a)
    local p = rrect(x, y, w, h, r)
    fill("000000", 0.35 * a, rrect(x + 1 * S, y + 5 * S, w - 2 * S, h, r), 10 * S)
    fill("1B1D23", a, p)
    stroke("FFFFFF", 0.12 * a, 0.8 * S, p)
    stroke("FFFFFF", 0.30 * a, 0.8 * S, p, 0.4 * S, clipr(x, y - 2 * S, x + w, y + h * 0.4))
end
local function glass(x, y, w, h, r, a, strong)
    if a <= 0.003 then return end
    local p = rrect(x, y, w, h, r)
    fill("000000", 0.30 * a, rrect(x + 2 * S, y + 8 * S, w - 4 * S, h, r), 16 * S)          -- shadow
    fill(opts.tint, clamp(opts.glass_opacity * (strong and 1.3 or 1), 0, 1) * a, p)           -- tinted body
    fill("FFFFFF", 0.02 * a, p)                                                               -- milky lift
    fill("FFFFFF", 0.035 * a, rrect(x + 4 * S, y + 3 * S, w - 8 * S, math.min(h * 0.42, 40 * S), r), 9 * S,
        clipr(x, y, x + w, y + h))                                                           -- top sheen
    stroke("FFFFFF", 0.12 * a, 0.8 * S, p)                                                   -- rim
    stroke("FFFFFF", 0.50 * a, 0.9 * S, p, 0.5 * S, clipr(x, y - 3 * S, x + w, y + math.min(h * 0.3, r + 4 * S)))
    stroke("FFFFFF", 0.20 * a, 0.9 * S, p, 0.5 * S, clipr(x, y + h - math.min(h * 0.22, r), x + w, y + h + 3 * S))
end

-- slimmer, more see-through panel for the control bar
function I.glass_light(x, y, w, h, r, a)
    if a <= 0.003 then return end
    local p = rrect(x, y, w, h, r)
    fill("000000", 0.22 * a, rrect(x + 2 * S, y + 8 * S, w - 4 * S, h, r), 18 * S)           -- soft shadow
    fill(opts.tint, clamp(opts.glass_opacity * 0.58, 0, 1) * a, p)                            -- lighter body
    stroke("FFFFFF", 0.14 * a, 0.8 * S, p)                                                    -- hairline rim
    stroke("FFFFFF", 0.30 * a, 0.8 * S, p, 0.5 * S, clipr(x, y - 3 * S, x + w, y + math.min(h * 0.3, r + 2 * S)))
end
-- text with a soft dark halo so it reads on any video
function I.shadow_text(x, y, an, size, hex, op, str, weight, clip)
    if op <= 0.003 or not str or str == "" then return end
    out[#out + 1] = string.format("{\\an%d\\pos(%s,%s)\\fn%s\\fs%s\\b%d\\bord%s\\3c&H000000&\\3a&H%02X&\\1a&HFF&\\shad0\\blur%s%s}%s",
        an, f(x), f(y), opts.font, f(size), weight or 400, f(size * 0.22), math.floor(255 * (1 - 0.45 * op) + 0.5), f(size * 0.45), clip or "", esc(str))
    text(x, y, an, size, col(hex, op), str, weight, clip)
end

-- ---------------------------------------------------------------- rendering
local function panel_width() return (opts.playlist_width + 16) * S end

local function want_visible(now)
    if dragging or menu then return true end
    if P.pause and opts.show_when_paused then return true end
    if not mouse.hover then return false end
    if mouse.y > H - 150 * S and mouse.x < W - panel_width() * ease(anim.playlist) then return true end
    return now - last_move < opts.hide_timeout / 1000
end

local tooltip = nil
local function draw_button(id, cx, cy, icon_paths, a, dt, onclick, active, extra)
    local r = 18 * S
    local disabled = extra and extra.disabled
    local over = inside(cx - r, cy - r, cx + r, cy + r) and not disabled
    if over and extra and extra.label then tooltip = { x = cx, y = cy - 70 * S, label = extra.label, id = id } end
    local h = hover_anim(id, over, dt)
    if h > 0 then
        local rr = r * (0.8 + 0.2 * h)
        fill("FFFFFF", 0.10 * h * a, circle(cx, cy, rr))
    end
    local gcol = active and opts.accent or "FFFFFF"
    local gop = (active and (0.55 + 0.35 * h) or 0.5 * h) * a
    if gop > 0 then for _, p in ipairs(icon_paths) do glow(gcol, gop, p, 6 * S) end end
    shapes(col(active and opts.accent or opts.text, (disabled and 0.3 or (0.82 + 0.18 * h)) * a), icon_paths)
    if a > 0.2 and not disabled then add_hit(cx - r, cy - r, cx + r, cy + r, onclick, extra) end
end
local function draw_tooltip(a, dt, cw)
    local t = tooltip
    local th = hover_anim("tooltip:" .. (t and t.id or ""), t ~= nil, dt)
    if not t or th <= 0 then return end
    local tw = text_width(t.label, 13 * S, 600) + 24 * S
    local tx = clamp(t.x - tw / 2, 8 * S, cw - tw - 8 * S)
    local ty = t.y - 16 * S + (1 - th) * 6 * S
    solid_bubble(tx, ty, tw, 30 * S, 15 * S, a * th)
    text(tx + tw / 2, ty + 15 * S, 5, 13 * S, col(opts.text, a * th), t.label, 600)
end

local function render_idle()
    local cx, cy = W / 2, H / 2 - 16 * S
    glass(cx - 40 * S, cy - 40 * S, 80 * S, 80 * S, 40 * S, 1)
    glow(opts.accent, 0.6, circle(cx, cy, 14 * S), 14 * S)
    shapes(col(opts.text, 0.95), I.play(cx + 2.5 * S, cy, 1.7 * S))
    text(W / 2, cy + 68 * S, 5, 17 * S, col(opts.text, 0.85), "Drop a video here", 500)
end

local media_info
do
-- "2160p · HEVC · Dolby Vision · TrueHD 7.1"
local VCODEC = { hevc = "HEVC", h264 = "H.264", av1 = "AV1", vp9 = "VP9", vp8 = "VP8", mpeg2video = "MPEG-2",
    mpeg4 = "MPEG-4", vc1 = "VC-1", h265 = "HEVC", prores = "ProRes" }
local ACODEC = { eac3 = "E-AC-3", ac3 = "AC-3", truehd = "TrueHD", dts = "DTS", opus = "Opus", aac = "AAC", flac = "FLAC",
    mp3 = "MP3", vorbis = "Vorbis", alac = "ALAC", mlp = "MLP" }
local function selected_track(kind)
    for _, t in ipairs(P["track-list"] or {}) do if t.type == kind and t.selected then return t end end
end
media_info = function()
    local parts = {}
    local function add(txt, prio) parts[#parts + 1] = { txt, prio } end
    local vp = P["video-params"]
    local vt = selected_track("video")
    if vt and not vt.image and not vt.albumart then
        local w, h = (vp and vp.w) or vt["demux-w"], (vp and vp.h) or vt["demux-h"]
        if w and h then
            local label
            if w >= 7000 then label = "4320p" elseif w >= 3800 or h >= 2100 then label = "2160p"
            elseif w >= 2500 or h >= 1400 then label = "1440p" elseif w >= 1900 or h >= 1000 then label = "1080p"
            elseif w >= 1260 or h >= 700 then label = "720p" else label = h .. "p" end
            add(label, 5)
        end
        local vc = vt.codec and (VCODEC[vt.codec] or vt.codec:upper())
        if vc then add(vc, 3) end
        local hdr
        if vt["dolby-vision-profile"] then hdr = "Dolby Vision"
        elseif vp and vp.gamma == "pq" then hdr = (vp["max-cll"] or vp["max-luma"]) and "HDR10" or "HDR"
        elseif vp and vp.gamma == "hlg" then hdr = "HLG" end
        if hdr then add(hdr, 4) end
    end
    -- average bitrate of the whole file (steady, unlike the live per-second rate)
    local size, dur = P["file-size"], P.duration
    if size and dur and dur > 0 then
        local bps = size * 8 / dur
        add(bps >= 1e6 and string.format("%.1f Mbps", bps / 1e6) or string.format("%d kbps", math.floor(bps / 1e3 + 0.5)), 1)
    end
    local at = selected_track("audio")
    if at and at.codec then
        local ac = ACODEC[at.codec] or (at.codec:match("^pcm") and "PCM") or at.codec:upper()
        local prof = at["codec-profile"] or ""
        if at.codec == "dts" and prof:find("MA") then ac = "DTS-HD MA"
        elseif at.codec == "dts" and prof:find("HRA") then ac = "DTS-HD HRA"
        elseif at.codec == "dts" and prof:find("X") then ac = "DTS:X" end
        local ch = at["demux-channel-count"] or at["audio-channels"]
        if ch then
            local chs = ({ [1] = "1.0", [2] = "2.0", [3] = "2.1", [6] = "5.1", [7] = "6.1", [8] = "7.1" })[ch] or (ch .. "ch")
            ac = ac .. " " .. chs
        end
        add(ac, 2)
    end
    return parts
end
end

local shader_state = { mode = nil, auto = true }
local plex_get -- assigned in the Plex section
local set_shader_mode -- assigned in the upscaling section
local auto_shader_mode -- assigned in the upscaling section
local function render_controls(now, dt, a, cw)
    local lift = (1 - a) * 14 * S
    -- title: on the video above the bar (Plex's name first, then the file's own title)
    local title, subtitle = P["media-title"] or "", nil
    do
        local cur = mp.get_property("path")
        local px = cur and plex_get(cur)
        if px and px.title ~= "" then
            if px.kind == "episode" then
                title = px.show or px.title
                subtitle = ((px.season and px.ep) and string.format("S%02d · E%02d  ·  ", px.season, px.ep) or "") .. px.title
                if not px.show then title, subtitle = px.title, nil end
            else
                title = px.title
                subtitle = px.year and tostring(px.year) or nil
            end
        end
    end

    -- top right: clock and when this will end
    do
        local now_s = os.time()
        local left = (P.duration or 0) - (mp.get_property_number("time-pos", 0) or 0)
        local speed = mp.get_property_number("speed", 1) or 1
        local clock = os.date("%I:%M %p", now_s):gsub("^0", "")
        if left > 0 then clock = clock .. "  ·  ends " .. os.date("%I:%M", now_s + math.floor(left / speed)):gsub("^0", "") end
        I.shadow_text(cw - 24 * S, 22 * S - lift * 0.6, 6, 12.5 * S, opts.text, 0.78 * a, clock, 600)
    end

    -- floating control panel
    local px1, px2 = 16 * S, cw - 16 * S
    local py1, py2 = H - 104 * S + lift, H - 16 * S + lift
    I.glass_light(px1, py1, px2 - px1, py2 - py1, 24 * S, a)
    if a > 0.2 then add_hit(px1, py1, px2, py2, nil) end

    -- seek bar
    local dur = P.duration
    local pos = mp.get_property_number("time-pos", 0) or 0
    local tpos_s = fmt_time(pos)
    local trem_s = dur and ("−" .. fmt_time(math.max(0, dur - pos))) or "--:--"
    local tw_pos = text_width(tpos_s, 12.5 * S, 600)
    local tw_rem = text_width(trem_s, 12.5 * S, 500)
    local sy = py1 + 25 * S
    local sx1, sx2 = px1 + 22 * S + tw_pos + 14 * S, px2 - 22 * S - tw_rem - 14 * S
    text(px1 + 22 * S, sy, 4, 12.5 * S, col(opts.text, 0.95 * a), tpos_s, 600)
    text(px2 - 22 * S, sy, 6, 12.5 * S, col(opts.muted, a), trem_s, 500)
    seek_geom.x1, seek_geom.x2 = sx1, sx2
    local seek_over = inside(sx1 - 8 * S, sy - 14 * S, sx2 + 8 * S, sy + 14 * S)
    anim.seek = step(anim.seek, (seek_over or dragging == "seek") and 1 or 0, dt, 120)
    local e = ease(anim.seek)
    -- slim, flat bar that matches the line weight of the icons
    local bh = (3 + 2 * e) * S
    local frac = (dur and dur > 0) and clamp(pos / dur, 0, 1) or 0
    local fx = sx1 + (sx2 - sx1) * frac
    fill("FFFFFF", 0.14 * a, rrect(sx1, sy - bh / 2, sx2 - sx1, bh, bh / 2))
    -- what's already buffered ahead, as a faint band
    do
        local cached = mp.get_property_number("demuxer-cache-time")
        if cached and dur and dur > 0 and cached > pos then
            local bx2 = sx1 + (sx2 - sx1) * clamp(cached / dur, 0, 1)
            fill("FFFFFF", 0.10 * a, rrect(sx1, sy - bh / 2, bx2 - sx1, bh, bh / 2))
        end
    end
    if seek_over and dur and dur > 0 then
        local mx = clamp(mouse.x, sx1, sx2)
        if mx > fx then fill("FFFFFF", 0.14 * a * e, rrect(sx1, sy - bh / 2, mx - sx1, bh, bh / 2)) end
    end
    if frac > 0 then
        glow(opts.accent, (0.55 + 0.3 * e) * a, rrect(sx1, sy - bh / 2, fx - sx1, bh, bh / 2), 6 * S)
        fill(opts.accent, a, rrect(sx1, sy - bh / 2, fx - sx1, bh, bh / 2))
    end
    if dur and dur > 0 then
        for _, ch in ipairs(P["chapter-list"] or {}) do
            local t = ch.time or 0
            if t > 0 and t < dur then
                local cx = sx1 + (sx2 - sx1) * t / dur
                fill(opts.tint, a, box(cx - 1 * S, sy - bh / 2 - 0.5 * S, cx + 1 * S, sy + bh / 2 + 0.5 * S))
            end
        end
    end
    -- "watched" marker: a small triangle above the bar at the point that counts as watched
    if dur and dur > 0 and opts.watched_at > 0 and opts.watched_at < 1 then
        local wx = sx1 + (sx2 - sx1) * opts.watched_at
        local reached = frac >= opts.watched_at
        local tip_y = sy - bh / 2 - 3 * S
        local tri = poly({ wx - 4.5 * S, tip_y - 6 * S, wx + 4.5 * S, tip_y - 6 * S, wx, tip_y })
        if reached then glow(opts.accent, 0.8 * a, tri, 4 * S) end
        fill(reached and opts.accent or "FFFFFF", (reached and 1 or 0.55) * a, tri)
        if inside(wx - 9 * S, tip_y - 12 * S, wx + 9 * S, tip_y + 2 * S) then
            tooltip = { x = wx, y = sy - 34 * S, id = "watchmark",
                label = (reached and "Counts as watched" or "Counts as watched from here") .. "  ·  " .. fmt_time(dur * opts.watched_at) }
        end
    end
    if e > 0 then
        glow(opts.accent, 0.8 * e * a, circle(fx, sy, 6 * S * e), 6 * S)
        fill(opts.accent, a, circle(fx, sy, 6 * S * e))
    end
    if a > 0.2 and dur and dur > 0 then
        add_hit(sx1 - 8 * S, sy - 14 * S, sx2 + 8 * S, sy + 14 * S, function()
            dragging = "seek"; seek_from_mouse(false)
        end)
    end
    if seek_over and dur and dur > 0 and e > 0 and not (tooltip and tooltip.id == "watchmark") then
        local mx = clamp(mouse.x, sx1, sx2)
        local label = fmt_time((mx - sx1) / (sx2 - sx1) * dur)
        local tw = (#label * 8.4 + 24) * S
        local tx = clamp(mx - tw / 2, 8 * S, cw - tw - 8 * S)
        local ty = py1 - 22 * S + (1 - e) * 6 * S
        solid_bubble(tx, ty, tw, 30 * S, 15 * S, a * e)
        text(tx + tw / 2, ty + 15 * S, 5, 14 * S, col(opts.text, a * e), label, 600)
    end

    -- buttons row
    local cy = py1 + 63 * S
    local has_ch = #(P["chapter-list"] or {}) > 0
    local mid = (px1 + px2) / 2
    -- narrow windows: drop the least important controls until the three groups no longer collide
    local show = { knob = shader_state.mode ~= nil, vol = true, skip = true, ep = true, chap = true }
    do
        local nbtn = 2 + (#tracks("sub") > 0 and 1 or 0) + (#tracks("audio") > 0 and 1 or 0)
        local xr = px2 - 36 * S - 44 * S * nbtn + 4 * S       -- where the volume control starts
        local gap = 16 * S
        local function fits()
            local vix = show.vol and (xr - 142 * S) or xr
            local right_edge = show.knob and (vix - 168 * S) or (vix - 18 * S)
            local half = show.skip and 118 * S or (show.chap and 70 * S or 23 * S)
            local left_edge = show.ep and (px1 + 138 * S) or (px1 + 54 * S)
            return (mid - half - gap) >= left_edge and right_edge >= (mid + half + gap)
        end
        for _, k in ipairs({ "knob", "vol", "skip", "ep", "chap" }) do
            if fits() then break end
            show[k] = false
        end
    end
    if show.chap then draw_button("chprev", mid - 50 * S, cy, I.seg_prev(mid - 50 * S, cy, S), a, dt, function() mp.commandv("add", "chapter", "-1") end,
        false, { label = "Previous chapter", disabled = not has_ch }) end
    do -- play / pause: a larger flat icon, in the accent color so it stands out
        local bx, r0 = mid, 21 * S
        local over = inside(bx - r0, cy - r0, bx + r0, cy + r0)
        local h = hover_anim("play", over, dt)
        local rr = r0 * (0.94 + 0.06 * h)
        glow(opts.accent, (0.35 + 0.35 * h) * a, circle(bx, cy, rr), 10 * S)
        fill(opts.accent, a, circle(bx, cy, rr))
        if h > 0 then fill("FFFFFF", 0.12 * h * a, circle(bx, cy, rr)) end
        local u = 1.1 * S
        -- when play/pause changes (mouse, keyboard or media key), cross-fade the icons for 0.28 s
        if anim.pp_state ~= P.pause then
            if anim.pp_state ~= nil then anim.pp_t = now end
            anim.pp_state = P.pause
        end
        local t = clamp((now - (anim.pp_t or -10)) / 0.28, 0, 1)
        local function icon(paused, scale, op)
            if op <= 0.01 then return end
            local uu = u * scale
            -- the triangle is centered on its balance point so it sits optically in the middle
            shapes(col("FFFFFF", op * a), paused and I.play(bx + 0.67 * uu, cy, uu) or I.pause(bx, cy, uu))
        end
        if t < 1 then
            local e2 = ease(t)
            icon(not P.pause, 1 - 0.35 * e2, 1 - e2)          -- old icon shrinks away
            icon(P.pause, 0.65 + 0.35 * e2, e2)                -- new icon grows in
            -- a soft ring that drifts outward and fades
            stroke(opts.accent, 0.45 * (1 - e2) * a, 1.2 * S, circle(bx, cy, rr + (2 + 9 * e2) * S))
            animating = true
        else
            icon(P.pause, 1, 1)
        end
        if a > 0.2 then add_hit(bx - r0, cy - r0, bx + r0, cy + r0, toggle_pause) end
    end
    for _, sk in ipairs(show.skip and { { "skipb", mid - 96 * S, I.skip_back, "-10", "10", "Back 10 seconds" },
                         { "skipf", mid + 96 * S, I.skip_fwd, "30", "30", "Forward 30 seconds" } } or {}) do
        local bx = sk[2]
        draw_button(sk[1], bx, cy, sk[3](bx, cy, S), a, dt, function() mp.commandv("seek", sk[4]) end, false, { label = sk[6] })
        text(bx, cy + 0.5 * S, 5, 8.5 * S, col(opts.text, (0.82 + 0.18 * (hv[sk[1]] or 0)) * a), sk[5], 700)
    end
    if show.chap then draw_button("chnext", mid + 50 * S, cy, I.seg_next(mid + 50 * S, cy, S), a, dt, function() mp.commandv("add", "chapter", "1") end,
        false, { label = "Next chapter", disabled = not has_ch }) end
    do
        local plist = P.playlist or {}
        local cur_i = (P["playlist-pos"] or 0) + 1
        local stop_x = show.ep and (px1 + 78 * S) or (px1 + 36 * S)
        if show.ep then
            draw_button("epprev", px1 + 36 * S, cy, I.prev(px1 + 36 * S, cy, S), a, dt, function() mp.commandv("playlist-prev") end,
                false, { label = "Previous in playlist", disabled = #plist < 2 or cur_i <= 1 })
            draw_button("epnext", px1 + 120 * S, cy, I.next(px1 + 120 * S, cy, S), a, dt, function() mp.commandv("playlist-next") end,
                false, { label = "Next in playlist", disabled = #plist < 2 or cur_i >= #plist })
        end
        draw_button("stop", stop_x, cy, I.stop(stop_x, cy, S), a, dt, function() mp.commandv("stop") end,
            false, { label = "Stop and go to Library" })
    end
    do
        local ty2 = py1 - 18 * S                      -- subtitle line baseline area
        local ty1 = subtitle and (ty2 - 20 * S) or (ty2 - 4 * S)
        local tx = px1 + 10 * S
        -- format info on the right; least important parts drop out first when space is short
        local parts = media_info()
        local function compose()
            local list = {}
            for _, pt in ipairs(parts) do list[#list + 1] = pt[1] end
            return table.concat(list, "  ·  ")
        end
        local twidth = math.max(text_width(title, 22 * S, 700), subtitle and text_width(subtitle, 13.5 * S, 500) or 0)
        local avail = (px2 - 10 * S) - (tx + math.min(twidth, (px2 - px1) * 0.55)) - 30 * S
        local info = compose()
        while #parts > 0 and text_width(info, 12 * S, 600) > avail do
            local lowest, li = 99, 1
            for i, pt in ipairs(parts) do if pt[2] < lowest then lowest, li = pt[2], i end end
            table.remove(parts, li)
            info = compose()
        end
        local tclip = clipr(0, 0, px2 - 10 * S - (info ~= "" and (text_width(info, 12 * S, 600) + 30 * S) or 0), H)
        if title ~= "" then I.shadow_text(tx, ty1, 1, 22 * S, opts.text, a, title, 700, tclip) end
        if subtitle then I.shadow_text(tx, ty2, 1, 13.5 * S, opts.text, 0.85 * a, subtitle, 500, tclip) end
        if info ~= "" then I.shadow_text(px2 - 10 * S, ty2, 3, 12 * S, opts.text, 0.72 * a, info, 600) end
    end

    local x = px2 - 36 * S
    draw_button("fs", x, cy, I.fullscreen(x, cy, S, P.fullscreen), a, dt, function() mp.commandv("cycle", "fullscreen") end,
        false, { label = P.fullscreen and "Exit fullscreen" or "Fullscreen" })
    x = x - 44 * S
    draw_button("pl", x, cy, I.playlist(x, cy, S), a, dt, toggle_playlist, playlist_open, { label = "Playlist" })
    x = x - 44 * S
    local subs, auds = tracks("sub"), tracks("audio")
    if #subs > 0 then
        local bx = x
        local on = P.sid and P.sid ~= false and P.sid ~= "no"
        draw_button("sub", bx, cy, I.subs(bx, cy, S), a, dt, function() open_menu("sub", bx) end, on, { keeps_menu = true, label = "Subtitles" })
        x = x - 44 * S
    end
    if #auds > 0 then
        local bx = x
        draw_button("aud", bx, cy, I.audio(bx, cy, S), a, dt, function() open_menu("audio", bx) end, menu and menu.kind == "audio", { keeps_menu = true, label = "Audio" })
        x = x - 44 * S
    end
    x = x + 4 * S
    -- volume (slider and percentage only when there is room)
    local vol = P.volume or 100
    local vix = x
    if show.vol then
        local vx2 = x + 14 * S - 44 * S
        local vx1 = vx2 - 86 * S
        vol_geom.x1, vol_geom.x2 = vx1, vx2
        local vover = inside(vx1 - 6 * S, cy - 14 * S, vx2 + 6 * S, cy + 14 * S)
        anim.vol = step(anim.vol, (vover or dragging == "volume") and 1 or 0, dt, 120)
        local ve = ease(anim.vol)
        local vh = (3 + 2 * ve) * S
        local vfx = vx1 + (vx2 - vx1) * clamp(vol / 100, 0, 1)
        fill("FFFFFF", 0.16 * a, rrect(vx1, cy - vh / 2, vx2 - vx1, vh, vh / 2))
        if not P.mute then glow("FFFFFF", 0.45 * ve * a, rrect(vx1, cy - vh / 2, vfx - vx1, vh, vh / 2), 5 * S) end
        fill(P.mute and opts.muted or "FFFFFF", 0.95 * a, rrect(vx1, cy - vh / 2, vfx - vx1, vh, vh / 2))
        if ve > 0 then
            glow("FFFFFF", 0.6 * ve * a, circle(vfx, cy, 8 * S * ve), 6 * S)
            fill("FFFFFF", a, circle(vfx, cy, 6 * S * ve))
        end
        if a > 0.2 then
            add_hit(vx1 - 6 * S, cy - 14 * S, vx2 + 6 * S, cy + 14 * S, function() dragging = "volume"; volume_from_mouse() end)
        end
        local vlabel = math.floor((P.volume or 100) + 0.5) .. "%"
        text(vx2 + 12 * S, cy, 4, 13 * S, col(P.mute and opts.muted or opts.text, (P.mute and 0.8 or 0.9) * a), vlabel, 600)
    vix = vx1 - 26 * S
    end
    draw_button("mute", vix, cy, I.volume(vix + 1 * S, cy, S, vol, P.mute), a, dt, function() mp.commandv("cycle", "mute") end,
        false, { label = P.mute and "Unmute" or "Mute" })

    -- upscaling chip: shows the mode; click cycles Anime -> Live -> Off
    if shader_state.mode and show.knob then
        local names = { anime = "2D Animation", live = "Live Action", off = "Disabled" }
        local mode = shader_state.mode
        local on = mode ~= "off"
        local label = names[mode] or "Disabled"
        local lw = text_width(label, 12 * S, 600)
        local cw2 = 36 * S + lw
        local cx2 = vix - 36 * S
        local x1, y1 = cx2 - cw2, cy - 14 * S
        -- divider between the chip and the volume group
        fill("FFFFFF", 0.16 * a, box(vix - 22 * S, cy - 10 * S, vix - 21.5 * S, cy + 10 * S))
        local over = inside(x1, y1, cx2, cy + 14 * S)
        local h = hover_anim("chip", over, dt)
        local p = rrect(x1, y1, cw2, 28 * S, 14 * S)
        fill(on and opts.accent or "FFFFFF", ((on and 0.16 or 0.08) + 0.08 * h) * a, p)
        -- small four-point sparkle
        local sx, sy2, u = x1 + 15 * S, cy, S
        local spark = poly({ sx, sy2 - 6.5 * u, sx + 1.6 * u, sy2 - 1.6 * u, sx + 6.5 * u, sy2, sx + 1.6 * u, sy2 + 1.6 * u,
            sx, sy2 + 6.5 * u, sx - 1.6 * u, sy2 + 1.6 * u, sx - 6.5 * u, sy2, sx - 1.6 * u, sy2 - 1.6 * u })
        if on then glow(opts.accent, 0.6 * a, spark, 5 * S) end
        fill(on and opts.accent or opts.muted, a, spark)
        text(x1 + 28 * S, cy, 4, 12 * S, col(on and "FF8A86" or opts.muted, (0.9 + 0.1 * h) * a), label, 600)
        if a > 0.2 then
            add_hit(x1, y1, cx2, cy + 14 * S, function()
                local nxt = { anime = "live", live = "off", off = "anime" }
                set_shader_mode(nxt[mode] or "anime")
            end)
        end
        if over then
            local how = shader_state.auto and "auto" or "set for this show"
            tooltip = { x = x1 + cw2 / 2, y = cy - 70 * S, id = "chip",
                label = "Upscaling: " .. label .. " (" .. how .. ")  ·  click to change" }
        end
    end
    -- divider between the volume group and the track buttons
    fill("FFFFFF", 0.16 * a, box(x + 22 * S, cy - 10 * S, x + 22.5 * S, cy + 10 * S))
    if not menu then draw_tooltip(a, dt, cw) end
    return py1
end

local function render_menu(dt, cw, panel_top)
    local e = ease(anim.menu)
    local m = menu or menu_last
    if not m or e <= 0 then return end
    local rows = {}
    if m.kind == "sub" then
        local off = not P.sid or P.sid == false or P.sid == "no"
        rows[1] = { label = "Off", selected = off, action = function() mp.set_property("sid", "no") end }
    end
    for _, t in ipairs(tracks(m.kind)) do
        rows[#rows + 1] = { label = track_label(t), detail = t.codec, selected = t.selected,
            action = function() mp.set_property_number(m.kind == "sub" and "sid" or "aid", t.id) end }
    end
    local rh, head, w = 38 * S, 40 * S, 300 * S
    local bottom = (panel_top or (H - 130 * S)) - 12 * S
    local n = math.min(#rows, math.max(1, math.floor((bottom - 70 * S - head) / rh)))
    local h = head + n * rh + 10 * S
    local x = clamp(m.ax - w + 44 * S, 16 * S, cw - w - 16 * S)
    local y = bottom - h + (1 - e) * 12 * S
    glass(x, y, w, h, 20 * S, e, true)
    text(x + 20 * S, y + head / 2 + 3 * S, 4, 12 * S, col(opts.muted, e), m.kind == "sub" and "SUBTITLES" or "AUDIO", 700)
    add_hit(x, y, x + w, y + h, nil, { group = "menu" })
    for i = 1, n do
        local r = rows[i]
        local ry = y + head + (i - 1) * rh
        local over = inside(x + 8 * S, ry, x + w - 8 * S, ry + rh)
        local hh = hover_anim("menu" .. i, over, dt)
        fill("FFFFFF", 0.10 * hh * e, rrect(x + 8 * S, ry + 1 * S, w - 16 * S, rh - 2 * S, 12 * S))
        if r.selected then
            glow(opts.accent, 0.9 * e, circle(x + 25 * S, ry + rh / 2, 5 * S), 6 * S)
            fill(opts.accent, e, circle(x + 25 * S, ry + rh / 2, 4 * S))
        end
        local clip = clipr(x, ry, x + w - (r.detail and 72 or 16) * S, ry + rh)
        text(x + 42 * S, ry + rh / 2, 4, 15 * S, col(r.selected and "FFFFFF" or opts.text, (r.selected and 1 or 0.8) * e), r.label, r.selected and 600 or 400, clip)
        if r.detail then text(x + w - 20 * S, ry + rh / 2, 6, 11 * S, col(opts.muted, e), r.detail:upper(), 600) end
        if e > 0.5 then
            add_hit(x + 8 * S, ry, x + w - 8 * S, ry + rh, function() r.action(); menu = nil; request() end, { group = "menu" })
        end
    end
end

local function render_playlist(dt)
    local e = ease(anim.playlist)
    if e <= 0 then return end
    local pw = opts.playlist_width * S
    local x0 = W - pw - 16 * S + (1 - e) * (pw + 40 * S)
    local y0, ph = 16 * S, H - 32 * S
    local list = P.playlist or {}
    glass(x0, y0, pw, ph, 24 * S, e, true)
    fill("08090C", 0.55 * e, rrect(x0, y0, pw, ph, 24 * S))   -- darker, so the list reads clearly over bright video
    add_hit(x0, y0, x0 + pw, y0 + ph, nil, { group = "playlist" })

    text(x0 + 22 * S, y0 + 32 * S, 4, 19 * S, col(opts.text, e), "Playlist", 700)
    text(x0 + 22 * S, y0 + 54 * S, 4, 13 * S, col(opts.muted, e), #list .. (#list == 1 and " item" or " items"), 500)
    local cx, ccy = x0 + pw - 30 * S, y0 + 32 * S
    local h = hover_anim("plclose", inside(cx - 15 * S, ccy - 15 * S, cx + 15 * S, ccy + 15 * S), dt)
    fill("FFFFFF", (0.08 + 0.08 * h) * e, circle(cx, ccy, 15 * S))
    local c1, c2 = I.close(cx, ccy, 0.9 * S)
    shapes(col(opts.text, (0.75 + 0.25 * h) * e), c1); shapes(col(opts.text, (0.75 + 0.25 * h) * e), c2)
    add_hit(cx - 15 * S, ccy - 15 * S, cx + 15 * S, ccy + 15 * S, toggle_playlist)

    local function pill(id, label, px, active, fn)
        local w, hgt, py = (#label * 7.6 + 28) * S, 28 * S, y0 + 72 * S
        local hh = hover_anim(id, inside(px, py, px + w, py + hgt), dt)
        local p = rrect(px, py, w, hgt, hgt / 2)
        if active then
            glow(opts.accent, (0.5 + 0.3 * hh) * e, p, 7 * S)
            fill(opts.accent, e, p)
            fill("FFFFFF", 0.2 * e, rrect(px + 3 * S, py + 1.5 * S, w - 6 * S, hgt * 0.4, hgt * 0.2), 2 * S)
        else
            fill("FFFFFF", (0.10 + 0.08 * hh) * e, p)
            stroke("FFFFFF", 0.25 * e, 0.8 * S, p, 0.4 * S, clipr(px, py - 2 * S, px + w, py + hgt * 0.4))
        end
        text(px + w / 2, py + hgt / 2, 5, 13 * S, col("FFFFFF", (active and 1 or 0.85) * e), label, 600)
        add_hit(px, py, px + w, py + hgt, fn)
        return px + w + 8 * S
    end
    local loop_on = P["loop-playlist"] and P["loop-playlist"] ~= "no" and P["loop-playlist"] ~= false
    local nx = pill("shuf", "Shuffle", x0 + 22 * S, false, function() mp.commandv("playlist-shuffle") end)
    pill("loop", "Loop", nx, loop_on, function() mp.commandv("cycle-values", "loop-playlist", "inf", "no") end)

    local top, rh, gh, bottom = y0 + 116 * S, 46 * S, 40 * S, y0 + ph - 10 * S
    local view = bottom - top
    local clip = clipr(x0, top, x0 + pw, bottom)
    if #list == 0 then
        text(x0 + pw / 2, top + 50 * S, 5, 15 * S, col(opts.muted, e), "Nothing queued", 500)
        text(x0 + pw / 2, top + 74 * S, 5, 13 * S, col(opts.muted, 0.7 * e), "Drag files onto the window", 400)
    end

    -- group entries by the folder they're in (e.g. Season 01, Season 02 ...)
    local groups, gindex = {}, {}
    for i, item in ipairs(list) do
        local fn = item.filename or ""
        local dir = fn:match("^(.*)[/\\][^/\\]+$") or ""
        local key = dir:gsub("\\", "/"):lower()
        local g = gindex[key]
        if not g then
            g = { key = key, label = dir:match("([^/\\]+)$") or "Files", items = {} }
            gindex[key] = g
            groups[#groups + 1] = g
        end
        g.items[#g.items + 1] = { i = i, item = item }
        if item.current or item.playing then g.has_cur = true end
    end
    local grouped = #groups > 1
    local rows, total = {}, 0
    local cur_y
    for _, g in ipairs(groups) do
        local open_ = true
        if grouped then
            if pl_group_open[g.key] == nil then open_ = g.has_cur or false else open_ = pl_group_open[g.key] end
            rows[#rows + 1] = { head = true, g = g, open = open_, y = total }
            total = total + gh
        end
        if open_ then
            for n, it in ipairs(g.items) do
                rows[#rows + 1] = { it = it, n = n, y = total }
                if it.item.current or it.item.playing then cur_y = total end
                total = total + rh
            end
        end
    end
    if pl_jump then
        pl_jump = false
        if cur_y then pl_scroll = cur_y - view / 2 + rh / 2 end
    end
    if plv.prev ~= nil and pl_scroll ~= plv.prev and not plv.wheel then plv.target = pl_scroll end
    plv.wheel = false
    plv.target = clamp(plv.target or pl_scroll, 0, math.max(0, total - view))
    do
        local d = plv.target - plv.shown
        if math.abs(d) < 0.5 then plv.shown = plv.target else plv.shown = plv.shown + d * (1 - math.exp(-dt * 14)); animating = true end
    end
    pl_scroll = plv.target
    plv.prev = pl_scroll

    for _, row in ipairs(rows) do
        local ry = top + row.y - plv.shown
        local hgt = row.head and gh or rh
        if ry + hgt >= top and ry <= bottom then
            local rx1, rx2 = x0 + 10 * S, x0 + pw - 10 * S
            local o = inside(rx1, math.max(ry, top), rx2, math.min(ry + hgt, bottom))
            if row.head then
                local g = row.g
                local hh = hover_anim("plg" .. g.key, o, dt)
                local ga = step(pl_group_anim[g.key] or (row.open and 1 or 0), row.open and 1 or 0, dt, 160)
                pl_group_anim[g.key] = ga
                if ga ~= (row.open and 1 or 0) then animating = true end
                fill("FFFFFF", (0.05 + 0.06 * hh) * e, rrect(rx1, ry + 3 * S, rx2 - rx1, hgt - 6 * S, 12 * S), 0, clip)
                local iy = ry + hgt / 2
                local ang = (1 - ease(ga)) * -math.pi / 2
                local cx = x0 + 30 * S
                local function rot(px, py) return cx + px * math.cos(ang) - py * math.sin(ang), iy + px * math.sin(ang) + py * math.cos(ang) end
                local ax, ay = rot(-4.5 * S, -2.2 * S)
                local bx, by = rot(0, 2.2 * S)
                local qx, qy = rot(4.5 * S, -2.2 * S)
                local cc = col(opts.text, (0.7 + 0.3 * hh) * e)
                shape(cc, line(ax, ay, bx, by, 1.8 * S), clip)
                shape(cc, line(bx, by, qx, qy, 1.8 * S), clip)
                local lmax = rx2 - 64 * S - (x0 + 48 * S)
                marquee("plgl" .. g.key, x0 + 48 * S, iy, 14 * S, col(g.has_cur and "FFFFFF" or opts.text, e), g.label, 700,
                    lmax, math.max(ry, top), math.min(ry + hgt, bottom), o)
                if g.has_cur then
                    glow(opts.accent, 0.8 * e, circle(rx2 - 44 * S, iy, 3.5 * S), 5 * S)
                    fill(opts.accent, e, circle(rx2 - 44 * S, iy, 3 * S), 0, clip)
                end
                text(rx2 - 14 * S, iy, 6, 12 * S, col(opts.muted, e), tostring(#g.items), 600, clip)
                add_hit(rx1, math.max(ry, top), rx2, math.min(ry + hgt, bottom), function()
                    pl_group_open[g.key] = not row.open
                    request()
                end, { group = "playlist" })
            else
                local i, item = row.it.i, row.it.item
                local hh = hover_anim("pl" .. i, o, dt)
                local cur = item.current or item.playing
                local indent = grouped and 10 * S or 0
                local rp = rrect(rx1 + indent, ry + 2 * S, rx2 - rx1 - indent, rh - 4 * S, 14 * S)
                if cur then fill(opts.accent, 0.20 * e, rp, 0, clip) end
                fill("FFFFFF", 0.08 * hh * e, rp, 0, clip)
                local iy = ry + rh / 2
                local nx = x0 + 34 * S + indent
                if cur then
                    local ic = P.pause and I.pause(nx, iy, 0.6 * S) or I.play(nx, iy, 0.65 * S)
                    for _, pth in ipairs(ic) do glow(opts.accent, 0.9 * e, pth, 5 * S) end
                    shapes(col(opts.accent, e), ic, clip)
                else
                    text(nx, iy, 5, 13 * S, col(opts.muted, e), tostring(grouped and row.n or i), 500, clip)
                end
                local tx = x0 + 54 * S + indent
                local nmax = rx2 - (o and 38 or 14) * S - tx
                marquee("pl" .. i, tx, iy, 15 * S, col(cur and "FFFFFF" or opts.text, (cur and 1 or 0.82) * e), entry_name(item),
                    cur and 600 or 400, nmax, math.max(ry, top), math.min(ry + rh, bottom), o)
                if o then
                    local bx = rx2 - 20 * S
                    local xo = inside(bx - 12 * S, iy - 12 * S, bx + 12 * S, iy + 12 * S)
                    local a1, a2 = I.close(bx, iy, 0.8 * S)
                    local cc = col(xo and opts.accent or opts.muted, e)
                    shapes(cc, a1, clip); shapes(cc, a2, clip)
                    add_hit(rx1, math.max(ry, top), rx2, math.min(ry + rh, bottom), function() mp.set_property_number("playlist-pos", i - 1) end, { group = "playlist" })
                    add_hit(bx - 12 * S, iy - 12 * S, bx + 12 * S, iy + 12 * S, function() mp.commandv("playlist-remove", tostring(i - 1)) end, { group = "playlist" })
                end
            end
        end
    end
    if total > view then
        local sh = math.max(30 * S, view * view / total)
        local sy = top + (view - sh) * (clamp(plv.shown, 0, total - view) / (total - view))
        fill("FFFFFF", 0.22 * e, rrect(x0 + pw - 7 * S, sy, 3 * S, sh, 1.5 * S))
    end
end

local function render_flash(now, cw)
    local t = (now - flash.t) / 0.5
    if t < 0 or t >= 1 then return end
    local cx, cy = cw / 2, H / 2
    local o = 1 - ease(t)
    local r = (38 + 12 * t) * S
    glass(cx - r, cy - r, 2 * r, 2 * r, r, o)
    local u = 2.1 * S * (1 + 0.15 * t)
    -- same balance-point offset as the play button, so the triangle looks centered in the circle
    shapes(col("FFFFFF", o), flash.icon == "play" and I.play(cx + 0.67 * u, cy, u) or I.pause(cx, cy, u))
end

-- ---------------------------------------------------------------- library (idle home screen)
local IS_WIN = package.config:sub(1, 1) == "\\"
local MEDIA_EXT = {}
for e in ("mkv mp4 avi mov webm m4v wmv flv ts m2ts mts mpg mpeg vob 3gp ogv divx rmvb"):gmatch("%S+") do MEDIA_EXT[e] = true end

local lib = { cache = {}, cur = nil, stack = {}, scroll = 0, max_scroll = 0, open_anim = {} }
lib.search = { text = "", focus = false, cache_key = nil, cache = nil }
local SEARCH_KEYS = { "glass-search-type", "glass-search-bs", "glass-search-esc", "glass-search-enter", "glass-search-clear" }
function lib.search_focus(on)
    local sr = lib.search
    if on == sr.focus then return end
    sr.focus = on
    if on then
        mp.add_forced_key_binding("any_unicode", SEARCH_KEYS[1], function(e)
            if e.event == "down" or e.event == "repeat" or e.event == "press" then
                if e.key_text and e.key_text ~= "" then sr.text = sr.text .. e.key_text; lib.scroll = 0; request() end
            end
        end, { complex = true, repeatable = true })
        mp.add_forced_key_binding("BS", SEARCH_KEYS[2], function()
            sr.text = sr.text:gsub("[%z\1-\127\194-\244][\128-\191]*$", ""); request()
        end, { repeatable = true })
        mp.add_forced_key_binding("ESC", SEARCH_KEYS[3], function()
            if sr.text ~= "" then sr.text = "" else lib.search_focus(false) end
            request()
        end)
        mp.add_forced_key_binding("ENTER", SEARCH_KEYS[4], function() lib.search_focus(false); request() end)
        mp.add_forced_key_binding("ctrl+BS", SEARCH_KEYS[5], function() sr.text = ""; request() end)
    else
        for _, k in ipairs(SEARCH_KEYS) do mp.remove_key_binding(k) end
    end
end
function lib.scroll_drag()
    local sb = lib.sb
    if not sb or lib.max_scroll <= 0 then return end
    local frac = clamp((mouse.y - (lib.sb_grab or sb.sh / 2) - sb.top) / math.max(1, sb.view - sb.sh), 0, 1)
    lib.scroll = frac * lib.max_scroll
    lib.target = lib.scroll
    lib.last_scroll_t = mp.get_time()
    lib.prev = lib.scroll
end
local collapsed = {}
local sec_order = {}
local saved_volume = nil
local shader_override = {}
local sec_drag = nil      -- { key, title, sy, active, saved_scroll }
local sec_pos = {}        -- header positions this frame
local lib_state_path = mp.command_native({ "expand-path", "~~/glass-library.json" })
local history = {}
local history_path = mp.command_native({ "expand-path", "~~/glass-history.json" })
local cur_path, cur_pos, cur_dur = nil, nil, nil
local pending_resume = nil

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function basename(p) return p:match("([^/\\]+)[/\\]*$") or p end
local function strip_ext(n) return (n:gsub("%.[%w]+$", "")) end
local function is_url(p) return p:find("^%a[%w+.-]*://") ~= nil end

-- resume positions for every file played (separate from the Recent list, which keeps one entry per show)
local positions = {}
local positions_path = mp.command_native({ "expand-path", "~~/glass-positions.json" })
local function read_json(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local data = utils.parse_json(fh:read("*a") or "")
    fh:close()
    return data
end
local function write_json(path, data)
    local fh = io.open(path, "w")
    if not fh then return end
    fh:write(utils.format_json(data) or "{}")
    fh:close()
end
local function load_history()
    local data = read_json(history_path)
    if type(data) == "table" then history = data end
    local pd = read_json(positions_path)
    if type(pd) == "table" then positions = pd end
end
local function save_history()
    write_json(history_path, history)
    local n, oldest, oldest_k = 0, math.huge, nil
    for k, v in pairs(positions) do
        n = n + 1
        if (v.t or 0) < oldest then oldest, oldest_k = v.t or 0, k end
    end
    if n > 3000 and oldest_k then positions[oldest_k] = nil end
    write_json(positions_path, positions)
end

-- ---------------------------------------------------------------- Plex (read-only)
-- Reads Plex's library database with Plex's own SQLite tool, opened immutable/read-only so
-- nothing is ever written to it. Gives titles, episode numbers and watch progress per file.
local plex = { items = {}, recent = {}, sig = nil, loading = false, ok = false }
local function plex_norm(p) return (p:gsub("\\", "/"):lower()) end
local function plex_uri(path)
    local u = path:gsub("\\", "/")
    u = u:gsub("[%%#%?% ]", function(c) return string.format("%%%02X", c:byte()) end)
    if not u:find("^/") then u = "/" .. u end
    return "file:" .. u .. "?immutable=1"
end
local PLEX_SQL = [[
SELECT mp.file, mi.title, mi.metadata_type, mi.[index], se.[index], sh.title, mi.year,
  IFNULL(s.view_offset, 0), IFNULL(s.view_count, 0),
  CASE typeof(s.last_viewed_at) WHEN 'integer' THEN s.last_viewed_at WHEN 'text' THEN strftime('%%s', s.last_viewed_at) ELSE 0 END,
  CASE typeof(s.updated_at) WHEN 'integer' THEN s.updated_at WHEN 'text' THEN strftime('%%s', s.updated_at) ELSE 0 END,
  IFNULL(m.duration, 0),
  IFNULL(mi.user_thumb_url, ''), IFNULL(mi.hash, ''), IFNULL(se.user_thumb_url, ''), IFNULL(se.hash, ''),
  IFNULL(sh.user_thumb_url, ''), IFNULL(sh.hash, ''), IFNULL(sh.year, ''), mi.id
FROM media_parts mp
JOIN media_items m ON m.id = mp.media_item_id
JOIN metadata_items mi ON mi.id = m.metadata_item_id
LEFT JOIN metadata_items se ON se.id = mi.parent_id AND mi.metadata_type = 4
LEFT JOIN metadata_items sh ON sh.id = se.parent_id
LEFT JOIN metadata_item_settings s ON s.guid = mi.guid AND s.account_id = %d
WHERE mi.metadata_type IN (1, 4) AND mp.file IS NOT NULL;
]]
local plex_reload -- forward
local function plex_signature()
    if opts.plex_db == "" then return nil end
    local info = utils.file_info(opts.plex_db)
    if not info then return nil end
    local wal = utils.file_info(opts.plex_db .. "-wal")
    return tostring(info.size) .. ":" .. tostring(info.mtime) .. ":" .. (wal and (tostring(wal.size) .. ":" .. tostring(wal.mtime)) or "")
end
plex_reload = function(force)
    if opts.plex_db == "" or plex.loading then return end
    local sig = plex_signature()
    if not sig then
        plex.ok = false
        plex.err = "can't open the database file (check the plex_db path and the folder permission)"
        require("mp.msg").warn("glass: Plex " .. plex.err .. ": " .. opts.plex_db)
        request()
        return
    end
    if sig == plex.sig and not force then return end
    plex.loading = true
    local function query(dbspec, after, live)
    local args = { opts.plex_sqlite, "-separator", "\31", "-newline", "\30" }
    if live then args[#args + 1] = "-readonly" end
    args[#args + 1] = dbspec
    args[#args + 1] = string.format(PLEX_SQL, tonumber(opts.plex_account) or 1)
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = args }, function(ok, res)
        if after then after() end
        plex.loading = false
        if not ok or not res or res.status ~= 0 then
            plex.ok = false
            local why = tostring(res and ((res.stderr ~= "" and res.stderr) or res.error_string) or "unknown")
            if res and (res.error_string == "init" or why:find("init")) then
                plex.err = "couldn't start Plex SQLite (check the plex_sqlite path)"
            else
                plex.err = "Plex SQLite couldn't read the database: " .. why:gsub("[\r\n]+", " "):sub(1, 90)
            end
            require("mp.msg").warn("glass: could not read the Plex database: " .. tostring(res and (res.stderr or res.error_string) or "unknown"))
            return
        end
        local items, recent = {}, {}
        for row in (res.stdout or ""):gmatch("[^\30]+") do
            local c = {}
            for field in (row .. "\31"):gmatch("([^\31]*)\31") do c[#c + 1] = field end
            if #c >= 12 and c[1] ~= "" then
                local t = math.max(tonumber(c[10]) or 0, tonumber(c[11]) or 0)
                local e = {
                    path = c[1], title = c[2], kind = tonumber(c[3]) == 4 and "episode" or "movie",
                    ep = tonumber(c[4]), season = tonumber(c[5]), show = c[6] ~= "" and c[6] or nil, year = tonumber(c[7]),
                    pos = (tonumber(c[8]) or 0) / 1000, views = tonumber(c[9]) or 0, t = t,
                    dur = (tonumber(c[12]) or 0) / 1000,
                    thumb = c[13], hash = c[14], s_thumb = c[15], s_hash = c[16], sh_thumb = c[17], sh_hash = c[18],
                    sh_year = tonumber(c[19]), id = tonumber(c[20]),
                }
                e.done = e.views > 0 and e.pos < 1
                items[plex_norm(c[1])] = e
                if t > 0 then recent[#recent + 1] = e end
            end
        end
        table.sort(recent, function(p1, p2) return p1.t > p2.t end)
        while #recent > 300 do table.remove(recent) end
        plex.items, plex.recent, plex.sig, plex.ok, plex.err = items, recent, sig, true, nil
        -- Plex's data often arrives just after a file starts; if Plex has a newer resume point than
        -- mpv had when the file opened, jump there now (only early in the file, and only once)
        local lr = plex.load_resume
        if lr and lr.path == cur_path and not lr.checked then
            lr.checked = true
            local px = items[plex_norm(cur_path)]
            local here = cur_pos or 0
            if px and px.t > (lr.t or 0) + 5 and px.pos > 10 and not px.done and here < 30 and math.abs(here - px.pos) > 5
                and not (cur_dur and px.pos >= cur_dur - 5) then
                mp.commandv("seek", tostring(px.pos), "absolute")
            end
        end
        request()
    end)
    end

    -- Plex keeps its newest changes in a "-wal" side file until it merges them (usually on a clean
    -- shutdown). Opening Plex's file read-only skips that side file, so when one exists we copy both
    -- into our own cache and read the copy; Plex's files are never opened for writing either way.
    -- Plex keeps its newest changes in a "-wal" side file until it merges them (usually on a clean
    -- shutdown). Without write access to Plex's folder, opening the original read-only skips that side
    -- file, so when one exists we copy both into our own cache and read the copy.
    local function copy_read()
        local cache = mp.command_native({ "expand-path", "~~/cache/plex-db" }):gsub("/", "\\")
        local src = opts.plex_db:gsub("/", "\\")
        local dst = cache .. "\\library.db"
        mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
            args = { "cmd", "/c", "if", "not", "exist", cache, "mkdir", cache, "&",
                "del", "/Q", dst, dst .. "-wal", dst .. "-shm", "2>nul", "&",
                "copy", "/Y", src, dst, ">nul", "&", "copy", "/Y", src .. "-wal", dst .. "-wal", ">nul" } }, function()
            if utils.file_info(dst) and utils.file_info(dst .. "-wal") then
                query(dst)
            else
                query(plex_uri(opts.plex_db)) -- couldn't copy; fall back to the read-only original
            end
        end)
    end
    local function offline_read()
        local wal = utils.file_info(opts.plex_db .. "-wal")
        if wal and wal.size and wal.size > 0 then copy_read() else query(plex_uri(opts.plex_db)) end
    end
    -- On the profile that runs Plex, a normal read-only open works: it's safe while Plex is running and
    -- sees its newest changes. Elsewhere it fails (no write access to Plex's folder) and we fall back.
    if plex.live_failed then offline_read(); return end
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = { opts.plex_sqlite, "-readonly", opts.plex_db, "SELECT 1 FROM metadata_items LIMIT 1;" } }, function(ok, res)
        if ok and res and res.status == 0 and (res.stdout or ""):find("1") then
            query(opts.plex_db, nil, true)
        else
            plex.live_failed = true
            offline_read()
        end
    end)
end
plex_entry_title = function(path)
    local px = path and plex.items[plex_norm(path)]
    if not px or px.title == "" then return nil end
    if px.kind == "episode" and px.ep then return string.format("%d. %s", px.ep, px.title) end
    return px.title
end
plex_get = function(path)
    if not path then return nil end
    return plex.items[plex_norm(path)]
end

-- progress for a file: mpv's own record or Plex's, whichever was saved more recently
local function pos_get(path)
    local mine = positions[path]
    if not mine then for _, h in ipairs(history) do if h.path == path then mine = h; break end end end
    local px = plex_get(path)
    if px and px.t > 0 and (not mine or px.t > (mine.t or 0)) then
        return { pos = px.pos, dur = (px.dur > 0 and px.dur) or (mine and mine.dur), done = px.done, t = px.t, from_plex = true }
    end
    return mine
end
local function _old_pos_get(path)
    local p = positions[path]
    if p then return p end
    for _, h in ipairs(history) do if h.path == path then return h end end
end
local function load_lib_state()
    local fh = io.open(lib_state_path, "r")
    if not fh then return end
    local data = utils.parse_json(fh:read("*a") or "")
    fh:close()
    if type(data) == "table" and type(data.collapsed) == "table" then collapsed = data.collapsed end
    if type(data) == "table" and type(data.order) == "table" then sec_order = data.order end
    if type(data) == "table" and type(data.volume) == "number" then saved_volume = data.volume end
    if type(data) == "table" and type(data.shaders) == "table" then shader_override = data.shaders end
end
local function save_lib_state()
    local fh = io.open(lib_state_path, "w")
    if not fh then return end
    fh:write(utils.format_json({ collapsed = collapsed, order = sec_order, volume = saved_volume, shaders = shader_override }) or "{}")
    fh:close()
end
local function set_section_order(new)
    local seen = {}
    for _, k in ipairs(new) do seen[k] = true end
    for i, k in ipairs(sec_order) do -- keep sections that are hidden right now (e.g. an empty Recent)
        if not seen[k] then table.insert(new, math.min(i, #new + 1), k) end
    end
    sec_order = new
    save_lib_state()
end
local function history_find(path)
    for i, h in ipairs(history) do if h.path == path then return i, h end end
end
local function history_update(finished)
    if not cur_path then return end
    local p = positions[cur_path] or {}
    positions[cur_path] = p
    local _, h = history_find(cur_path)
    for _, e in ipairs({ p, h }) do
        if cur_dur then e.dur = cur_dur end
        local past = cur_pos and cur_dur and cur_dur > 0 and cur_pos >= opts.watched_at * cur_dur
        if finished or past then e.pos = 0; e.done = true
        elseif cur_pos then e.pos = cur_pos; e.done = false end
        e.t = os.time()
    end
    save_history()
    -- leave the newest progress for this file where the Plex sync script (on the Plex profile) picks it up
    if opts.sync_folder ~= "" and not is_url(cur_path) then
        local qpath = opts.sync_folder .. "\\plex-queue.json"
        if not utils.file_info(opts.sync_folder) then
            mp.command_native({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
                args = { "cmd", "/c", "mkdir", (opts.sync_folder:gsub("/", "\\")) } })
        end
        local queue = {}
        local fh = io.open(qpath, "r")
        if fh then
            local data = utils.parse_json(fh:read("*a") or "")
            fh:close()
            if type(data) == "table" then queue = data end
        end
        local function nrm(x) return (x:gsub("\\", "/"):lower()) end
        for k = #queue, 1, -1 do
            if type(queue[k]) ~= "table" or nrm(queue[k].path or "") == nrm(cur_path) then table.remove(queue, k) end
        end
        queue[#queue + 1] = { path = cur_path, pos = p.pos or 0, dur = p.dur or 0, done = p.done or false, t = p.t }
        fh = io.open(qpath, "w")
        if fh then fh:write(utils.format_json(queue) or "[]"); fh:close() end
        -- on the profile that runs Plex, push it now instead of waiting for the scheduled sync
        if opts.sync_now then
            local script = opts.sync_folder .. "\\glass-plex-sync.ps1"
            if utils.file_info(script) then
                mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
                    args = { "conhost.exe", "--headless", "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script } },
                    function() plex.sig = nil; plex_reload() end)
            end
        end
    end
end

local function lib_roots()
    local roots = {}
    for section in opts.library_folders:gmatch("[^;]+") do
        section = trim(section)
        if section ~= "" then
            local name, rest = section:match("^([^=]+)=(.+)$")
            local paths = {}
            for p in (rest or section):gmatch("[^|]+") do
                p = trim(p)
                if p ~= "" then paths[#paths + 1] = p end
            end
            if #paths > 0 then
                roots[#roots + 1] = { name = name and trim(name) or basename(paths[1]), paths = paths }
            end
        end
    end
    if #roots == 0 then
        local up = os.getenv("USERPROFILE")
        local p = up and (up .. "\\Videos") or (os.getenv("HOME") and os.getenv("HOME") .. "/Videos")
        if p then roots[1] = { name = "Videos", paths = { p } } end
    end
    return roots
end
local function natural_less(a, b)
    a, b = a:lower(), b:lower()
    local ia, ib = 1, 1
    while ia <= #a and ib <= #b do
        local na, nb = a:match("^%d+", ia), b:match("^%d+", ib)
        if na and nb then
            local va, vb = tonumber(na), tonumber(nb)
            if va ~= vb then return va < vb end
            ia, ib = ia + #na, ib + #nb
        else
            local ca, cb = a:sub(ia, ia), b:sub(ib, ib)
            if ca ~= cb then return ca < cb end
            ia, ib = ia + 1, ib + 1
        end
    end
    return #a - ia < #b - ib
end
local function scan(dir)
    if lib.cache[dir] then return lib.cache[dir] end
    local r = { dirs = {}, files = {} }
    local ds = utils.readdir(dir, "dirs") or {}
    local fs = utils.readdir(dir, "files") or {}
    table.sort(ds, natural_less)
    table.sort(fs, natural_less)
    for _, d in ipairs(ds) do
        local c = d:sub(1, 1)
        if c ~= "." and c ~= "$" then r.dirs[#r.dirs + 1] = { name = d, path = utils.join_path(dir, d), dir = true } end
    end
    for _, fname in ipairs(fs) do
        local ext = fname:match("%.([^%.]+)$")
        if ext and MEDIA_EXT[ext:lower()] then
            r.files[#r.files + 1] = { name = strip_ext(fname), path = utils.join_path(dir, fname), ext = ext:upper() }
        end
    end
    lib.cache[dir] = r
    return r
end

-- merge several folders into one view; same-named subfolders are combined
local function scan_multi(paths)
    local key = table.concat(paths, "|")
    if lib.cache["*" .. key] then return lib.cache["*" .. key] end
    local r = { dirs = {}, files = {} }
    local byname = {}
    for _, p in ipairs(paths) do
        local d = scan(p)
        for _, e in ipairs(d.dirs) do
            local k = e.name:lower()
            if byname[k] then
                table.insert(byname[k].paths, e.path)
                byname[k].path = table.concat(byname[k].paths, "|")
            else
                byname[k] = { name = e.name, paths = { e.path }, path = e.path, dir = true }
                r.dirs[#r.dirs + 1] = byname[k]
            end
        end
        for _, e in ipairs(d.files) do r.files[#r.files + 1] = e end
    end
    table.sort(r.dirs, function(a, b) return natural_less(a.name, b.name) end)
    table.sort(r.files, function(a, b) return natural_less(a.name, b.name) end)
    lib.cache["*" .. key] = r
    return r
end

local read_embedded_title
do
-- embedded title readers (Matroska/WebM and MP4/MOV), no bit operators (LuaJIT/5.1 safe)
local function ebml_vint(buf, pos, keep_marker)
    local b = buf:byte(pos)
    if not b or b == 0 then return nil end
    local len, mask = 1, 128
    while b < mask and len < 8 do len = len + 1; mask = mask / 2 end
    local v = keep_marker and b or (b - mask)
    local all_ones = (b - mask) == mask - 1
    for i = 1, len - 1 do
        local c = buf:byte(pos + i)
        if not c then return nil end
        if c ~= 255 then all_ones = false end
        v = v * 256 + c
    end
    if not keep_marker and all_ones then v = math.huge end
    return v, pos + len
end

local function mkv_title(fh)
    local buf = fh:read(262144)
    if not buf or buf:sub(1, 4) ~= "\26\69\223\163" then return nil end
    local id, p = ebml_vint(buf, 1, true)
    local size
    size, p = ebml_vint(buf, p)
    if not size or size == math.huge then return nil end
    local pos = p + size
    id, p = ebml_vint(buf, pos, true)
    if id ~= 0x18538067 then return nil end
    size, p = ebml_vint(buf, p)
    pos = p
    while pos < #buf do
        id, p = ebml_vint(buf, pos, true)
        if not id then break end
        size, p = ebml_vint(buf, p)
        if not size then break end
        if id == 0x1549A966 then
            local stop, q = math.min(p + size, #buf + 1), p
            while q < stop do
                local cid, qq = ebml_vint(buf, q, true)
                if not cid then break end
                local cs
                cs, qq = ebml_vint(buf, qq)
                if not cs then break end
                if cid == 0x7BA9 then return buf:sub(qq, qq + cs - 1) end
                q = qq + cs
            end
            return nil
        elseif id == 0x1F43B675 or size == math.huge then
            return nil
        end
        pos = p + size
    end
end

local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function mp4_title(fh, fsize)
    local function box_at(off)
        if not fh:seek("set", off) then return end
        local h = fh:read(16)
        if not h or #h < 8 then return end
        local size, typ, hdr = u32(h, 1), h:sub(5, 8), 8
        if size == 1 and #h >= 16 then size, hdr = u32(h, 9) * 4294967296 + u32(h, 13), 16
        elseif size == 0 then size = fsize - off end
        return size, typ, hdr
    end
    local function child(start, stop, want)
        local off, n = start, 0
        while off + 8 <= stop and n < 4000 do
            local size, typ, hdr = box_at(off)
            if not size or size < 8 then return end
            if typ == want then return off, size, hdr end
            off, n = off + size, n + 1
        end
    end
    local mo, ms, mh = child(0, fsize, "moov")
    if not mo then return end
    local uo, us, uh = child(mo + mh, mo + ms, "udta")
    if not uo then return end
    local meo, mes, meh = child(uo + uh, uo + us, "meta")
    if meo then
        local io_, is_, ih = child(meo + meh + 4, meo + mes, "ilst")
        if not io_ then io_, is_, ih = child(meo + meh, meo + mes, "ilst") end
        if io_ then
            local no, ns, nh = child(io_ + ih, io_ + is_, "\169nam")
            if no then
                local dof, ds, dh = child(no + nh, no + ns, "data")
                if dof and ds - dh - 8 > 0 and ds - dh - 8 < 4096 then
                    fh:seek("set", dof + dh + 8)
                    return fh:read(ds - dh - 8)
                end
            end
        end
    end
    -- QuickTime style: udta/©nam holding [len16][lang16][text]
    local qo, qs, qh = child(uo + uh, uo + us, "\169nam")
    if qo and qs - qh > 4 and qs - qh < 4096 then
        fh:seek("set", qo + qh)
        local d = fh:read(qs - qh)
        local len = d:byte(1) * 256 + d:byte(2)
        return d:sub(5, 4 + len)
    end
end

local MKV_EXT = { mkv = true, webm = true, mka = true, mk3d = true }
local MP4_EXT = { mp4 = true, m4v = true, mov = true, ["3gp"] = true }

read_embedded_title = function(path)
    local ext = (path:match("%.([^%.\\/]+)$") or ""):lower()
    if not MKV_EXT[ext] and not MP4_EXT[ext] then return nil end
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local ok, t = pcall(function()
        if MKV_EXT[ext] then return mkv_title(fh) end
        local size = fh:seek("end")
        return mp4_title(fh, size)
    end)
    fh:close()
    if not ok or type(t) ~= "string" then return nil end
    t = t:gsub("%z+$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if t == "" then return nil end
    return t
end
end

-- title cache: read embedded titles in the background, a few files per frame
local title_cache = {}
local title_db = {}
local title_queue, title_queued = {}, {}
local title_db_path = mp.command_native({ "expand-path", "~~/glass-titles.json" })
local title_dirty = false
do
    local fh = io.open(title_db_path, "r")
    if fh then
        local data = utils.parse_json(fh:read("*a") or "")
        fh:close()
        if type(data) == "table" then title_db = data end
    end
end
local function save_titles()
    if not title_dirty then return end
    local fh = io.open(title_db_path, "w")
    if fh then fh:write(utils.format_json(title_db) or "{}"); fh:close() end
    title_dirty = false
end
local title_timer
title_timer = mp.add_periodic_timer(0.02, function()
    local t0 = mp.get_time()
    while #title_queue > 0 and mp.get_time() - t0 < 0.012 do
        local path = table.remove(title_queue, 1)
        local info = utils.file_info(path)
        local t = info and read_embedded_title(path) or nil
        title_cache[path] = t or false
        if info then
            title_db[path] = { t = t or "", s = info.size, m = info.mtime }
            title_dirty = true
        end
        request()
    end
    if #title_queue == 0 then
        title_timer:kill()
        save_titles()
    end
end)
title_timer:kill()

-- embedded titles that are really release names, e.g. "[Group] Show - 01 (BD 1080p FLAC)"
local JUNK = { "%f[%w]%d%d%d%d?[pi]%f[%W]", "%f[%w]4k%f[%W]", "%f[%w]uhd%f[%W]", "%f[%w]x26[45]%f[%W]", "%f[%w]h%.?26[45]%f[%W]",
    "%f[%w]hevc%f[%W]", "%f[%w]avc%f[%W]", "%f[%w]hi10p?%f[%W]", "%f[%w]10bit%f[%W]", "%f[%w]bd%f[%W]", "%f[%w]bdrip%f[%W]",
    "blu%-?ray", "%f[%w]web%-?dl%f[%W]", "%f[%w]webrip%f[%W]", "%f[%w]remux%f[%W]", "%f[%w]flac%f[%W]", "%f[%w]aac%f[%W]",
    "%f[%w]ac3%f[%W]", "%f[%w]e%-?ac%-?3%f[%W]", "%f[%w]dts%f[%W]", "%f[%w]truehd%f[%W]", "%f[%w]atmos%f[%W]", "%f[%w]ddp?5%.1",
    "%f[%w]hdr%f[%W]", "%f[%w]dv%f[%W]", "%f[%w]dvdrip%f[%W]", "%f[%w]hdtv%f[%W]" }
local function looks_like_release_name(t)
    if t:find("^%s*%[") then return true end
    local l = t:lower()
    if not l:find(" ") and l:find("%.") then return true end
    for _, pat in ipairs(JUNK) do if l:find(pat) then return true end end
    return false
end

local raw_meta_title
meta_title = function(path)
    local t = raw_meta_title(path)
    if t and looks_like_release_name(t) then return nil end
    return t
end
raw_meta_title = function(path)
    if not path or is_url(path) then return nil end
    local c = title_cache[path]
    if c ~= nil then return c or nil end
    local rec = title_db[path]
    if rec then
        local info = utils.file_info(path)
        if info and info.size == rec.s and info.mtime == rec.m then
            title_cache[path] = (rec.t ~= "" and rec.t) or false
            return title_cache[path] or nil
        end
    end
    if not title_queued[path] then
        title_queued[path] = true
        title_queue[#title_queue + 1] = path
        if not title_timer:is_enabled() then title_timer:resume() end
    end
    return nil
end

local function parent_dir(p) return p:match("^(.*)[/\\][^/\\]+[/\\]*$") end
local function norm_path(p) return (p:gsub("\\", "/"):lower()) end
local function season_number(name)
    local l = name:lower()
    return tonumber(l:match("^season%s*0*(%d+)") or l:match("^s0*(%d+)$") or "")
end

-- every video that belongs with this file: the whole show if it sits in a "Season N" folder,
-- otherwise the folder it's in
local function context_list(path)
    if is_url(path) then return { path } end
    local dir = parent_dir(path)
    if not dir then return { path } end
    local list = {}
    if season_number(basename(dir)) then
        local show = parent_dir(dir)
        if show then
            local d = scan(show)
            for _, f in ipairs(d.files) do list[#list + 1] = f.path end
            local seasons = {}
            for _, sd in ipairs(d.dirs) do
                local n = season_number(sd.name)
                if n then seasons[#seasons + 1] = { n = n, path = sd.path } end
            end
            table.sort(seasons, function(p1, p2) return p1.n < p2.n end)
            for _, sd in ipairs(seasons) do
                for _, f in ipairs(scan(sd.path).files) do list[#list + 1] = f.path end
            end
        end
    else
        for _, f in ipairs(scan(dir).files) do list[#list + 1] = f.path end
    end
    local want, found = norm_path(path), false
    for i, p in ipairs(list) do
        if norm_path(p) == want then list[i] = path; found = true end -- keep the exact path we were given
    end
    if not found then return { path } end
    return list
end

local function play_file(path)
    local h = pos_get(path)
    if h and h.pos and h.pos > 10 and not h.done then pending_resume = { path = path, pos = h.pos } end
    local list = context_list(path)
    local idx = 1
    for i, p in ipairs(list) do if p == path then idx = i end end
    mp.commandv("loadfile", path, "replace")
    for i = idx + 1, #list do mp.commandv("loadfile", list[i], "append") end
    local later = #list - idx
    for k = 1, idx - 1 do
        mp.commandv("loadfile", list[k], "append")
        mp.commandv("playlist-move", tostring(later + k), tostring(k - 1))
    end
end

local function open_dialog()
    if not IS_WIN then mp.osd_message("Drag files onto the window to play them"); return end
    local ps = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; Add-Type -AssemblyName System.Windows.Forms; " ..
        "$d = New-Object System.Windows.Forms.OpenFileDialog; $d.Multiselect = $true; $d.Title = 'Open media'; " ..
        "$d.Filter = 'Videos|*.mkv;*.mp4;*.avi;*.mov;*.webm;*.m4v;*.wmv;*.flv;*.ts;*.m2ts;*.mpg;*.mpeg|All files|*.*'; " ..
        "if ($d.ShowDialog() -eq 'OK') { $d.FileNames -join \"`n\" }"
    mp.command_native_async({ name = "subprocess", args = { "powershell", "-NoProfile", "-STA", "-Command", ps },
        capture_stdout = true, playback_only = false }, function(ok, res)
        if not ok or not res or res.status ~= 0 then return end
        local files = {}
        for line in (res.stdout or ""):gmatch("[^\r\n]+") do files[#files + 1] = line end
        if #files == 1 then play_file(files[1])
        else
            for i, fpath in ipairs(files) do mp.commandv("loadfile", fpath, i == 1 and "replace" or "append") end
        end
    end)
end

-- colorful generated artwork from the file name
local function hsv(h, s, v)
    h = h % 1
    local i = math.floor(h * 6)
    local fr = h * 6 - i
    local p, q, t = v * (1 - s), v * (1 - fr * s), v * (1 - (1 - fr) * s)
    local r, g, b
    i = i % 6
    if i == 0 then r, g, b = v, t, p elseif i == 1 then r, g, b = q, v, p elseif i == 2 then r, g, b = p, v, t
    elseif i == 3 then r, g, b = p, q, v elseif i == 4 then r, g, b = t, p, v else r, g, b = v, p, q end
    return string.format("%02X%02X%02X", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
end
local function name_hue(s)
    local h = 7
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 1000003 end
    return (h % 360) / 360
end
local function vclip(path) return "\\clip(" .. path .. ")" end

local function art(x, y, w, h, r, name, a, hov)
    local hue = name_hue(name)
    local shape_p = rrect(x, y, w, h, r)
    local cl = vclip(shape_p)
    fill("0E1015", 0.92 * a, shape_p)
    fill(hsv(hue, 0.55, 0.9), 0.60 * a, circle(x + w * 0.28, y + h * 0.35, h * 0.62), 26 * S, cl)
    fill(hsv(hue + 0.13, 0.6, 0.85), 0.50 * a, circle(x + w * 0.80, y + h * 0.85, h * 0.55), 26 * S, cl)
    fill("FFFFFF", (0.06 + 0.06 * hov) * a, rrect(x, y, w, h * 0.45, r), 10 * S, cl)
    stroke("FFFFFF", 0.18 * a, 0.8 * S, shape_p, 0.4 * S, clipr(x, y - 2 * S, x + w, y + h * 0.3))
end

local function folder_icon(cx, cy, u)
    return { rrect(cx - 16 * u, cy - 10 * u, 13 * u, 6 * u, 2 * u), rrect(cx - 16 * u, cy - 6 * u, 32 * u, 22 * u, 3 * u) }
end

local function episode_number(fname)
    local l = fname:lower()
    local ep = l:match("s%d+%s*%.?%s*e(%d+)")
        or l:match("%f[%d]%d%d?x(%d%d%d?)%f[^%d]")
        or l:match("episode%s*[%.%-_]?%s*(%d+)")
        or l:match("%f[%w]ep%.?%s*(%d+)")
        or l:match("%f[%w]e(%d+)%f[^%d]")
    if not ep then
        -- anime style " - 012 " (skip things like "- 1080p")
        for num, after in l:gmatch("%s%-%s*(%d+)(%a?)") do
            if after ~= "p" and after ~= "i" and #num <= 4 then ep = num; break end
        end
    end
    if not ep then
        local num, after = l:match("^%s*(%d+)(%a?)")
        if num and after ~= "p" and after ~= "x" and #num <= 3 then ep = num end
    end
    return ep and tonumber(ep)
end

-- "Naruto Shippuden (2007) - Episode 05 S01" for episodes inside a Season folder
local ep_cache = {}
episode_title = function(path)
    if not path or is_url(path) then return nil end
    if ep_cache[path] ~= nil then return ep_cache[path] or nil end
    local res = false
    local dir = parent_dir(path)
    local sn = dir and season_number(basename(dir))
    local showdir = sn and parent_dir(dir)
    if showdir then
        local show = basename(showdir)
        show = show:match("^(.-%(%d%d%d%d%))") or show:gsub("%s+%-%s+.*$", "")
        local ep = episode_number(strip_ext(basename(path)))
        if ep then res = string.format("%s - Episode %02d S%02d", show, ep, sn) end
    end
    ep_cache[path] = res
    return res or nil
end

-- where a file sits in the library: its section and the folders between the section and the file
local ctx_cache = {}
local function file_context(path)
    if ctx_cache[path] ~= nil then return ctx_cache[path] or nil end
    local result = false
    if not is_url(path) then
        local np = norm_path(path)
        for _, root in ipairs(lib_roots()) do
            for _, rp in ipairs(root.paths) do
                local nr = norm_path(rp):gsub("/+$", "")
                if np:sub(1, #nr + 1) == nr .. "/" then
                    local segs = {}
                    for seg in path:sub(#nr + 2):gmatch("[^/\\]+") do segs[#segs + 1] = seg end
                    table.remove(segs) -- the file itself
                    if #segs > 0 then
                        local label
                        local last = segs[#segs]
                        if season_number(last) and #segs >= 2 then
                            local show = segs[#segs - 1]
                            show = show:match("^(.-%(%d%d%d%d%))") or show:gsub("%s+%-%s+.*$", "")
                            label = show .. "  ·  " .. last
                        else
                            label = last
                        end
                        result = { root = root, segs = segs, label = label }
                    end
                    break
                end
            end
            if result then break end
        end
    end
    ctx_cache[path] = result
    return result or nil
end

-- open the library at that folder; back steps up one folder at a time
local function open_context(ctx)
    lib.stack = { { view = false, scroll = lib.scroll } }
    local view
    for i = 1, #ctx.segs do
        local paths = {}
        for _, rp in ipairs(ctx.root.paths) do
            local p = rp
            for j = 1, i do p = utils.join_path(p, ctx.segs[j]) end
            if utils.file_info(p) then paths[#paths + 1] = p end
        end
        if #paths == 0 then break end
        if view then lib.stack[#lib.stack + 1] = { view = view, scroll = 0 } end
        view = { name = ctx.segs[i], paths = paths }
    end
    if view then
        lib.cur = view
        lib.scroll = 0
    else
        lib.stack = {}
    end
end

-- ---------------------------------------------------------------- posters from Plex's own files
-- Plex keeps artwork in "<Plex data>\Metadata\<Movies|TV Shows>\<h>\<ash>.bundle\...". Each image is
-- converted once by mpv into a raw, rounded-corner bitmap (cached), then shown with overlay-add.
local poster
local file_art, dir_art, poster_bitmap, poster_show, posters_apply, poster_status, dir_plex_name
do
poster = { resolved = {}, ready = {}, queue = {}, queued = {}, busy = 0, dir_art = {}, dir_sig = nil,
    stats = { ready = 0, failed = 0, missing = 0, err = nil } }
local POSTER_W, POSTER_H, STILL_W, STILL_H = 240, 360, 400, 225
local poster_cache_dir = mp.command_native({ "expand-path", "~~/cache/glass-posters" })

local function plex_root() return opts.plex_db:match("^(.*)[/\\]Plug%-in Support[/\\]") end
local function bundle(folder, h)
    local root = plex_root()
    if not root or not h or #h < 2 then return nil end
    return root .. "/Metadata/" .. folder .. "/" .. h:sub(1, 1) .. "/" .. h:sub(2) .. ".bundle"
end
-- every place Plex may have stored a given artwork URL
local function art_candidates(url, folder, own_hash, show_hash, sidx, eidx)
    local list = {}
    local scheme, rest = (url or ""):match("^(%a+)://(.+)$")
    if not scheme then return list end
    local function add(p) if p then list[#list + 1] = p end end
    if scheme == "upload" then
        local b = bundle(folder, own_hash); if b then add(b .. "/Uploads/" .. rest) end
        local sb = bundle(folder, show_hash); if sb then add(sb .. "/Uploads/" .. rest) end
    elseif scheme == "metadata" then
        local b = bundle(folder, own_hash); if b then add(b .. "/Contents/_combined/" .. rest) end
        local sb = bundle(folder, show_hash)
        if sb and sidx then
            add(sb .. "/Contents/_combined/seasons/" .. sidx .. "/" .. (eidx and ("episodes/" .. eidx .. "/") or "") .. rest)
        end
    elseif scheme == "media" then
        local root = plex_root(); if root then add(root .. "/Media/localhost/" .. rest) end
    end
    return list
end
local function resolve_art(key, url, folder, own_hash, show_hash, sidx, eidx)
    if poster.resolved[key] ~= nil then return poster.resolved[key] or nil end
    local found = false
    for _, c in ipairs(art_candidates(url, folder, own_hash, show_hash, sidx, eidx)) do
        if utils.file_info(c) then found = c; break end
    end
    if not found and url and url ~= "" then
        poster.stats.missing = poster.stats.missing + 1
        poster.stats.miss_example = poster.stats.miss_example or (art_candidates(url, folder, own_hash, show_hash, sidx, eidx)[1] or url)
        require("mp.msg").warn("glass: no poster file found for " .. url .. " (looked in " .. tostring(art_candidates(url, folder, own_hash, show_hash, sidx, eidx)[1]) .. ")")
    end
    poster.resolved[key] = found
    return found or nil
end

-- artwork for a file: a movie's poster, an episode's show poster, or (still = true) the episode's own still
file_art = function(path, still)
    local px = plex_get(path)
    if not px then return nil end
    if px.kind == "movie" then
        return resolve_art("m" .. px.hash, px.thumb, "Movies", px.hash)
    end
    if still then
        return resolve_art("e" .. px.hash, px.thumb, "TV Shows", px.hash, px.sh_hash, px.season, px.ep)
    end
    return resolve_art("sh" .. px.sh_hash, px.sh_thumb, "TV Shows", px.sh_hash)
end

-- artwork for a folder: a show's poster, a season's poster, or the poster of the one movie inside it
local function build_dir_art()
    if poster.dir_sig == plex.sig then return end
    poster.dir_sig = plex.sig
    poster.dir_art = {}
    for _, e in pairs(plex.items) do
        local dir = parent_dir(e.path)
        if dir then
            if e.kind == "episode" then
                local sdir, show = dir, nil
                if season_number(basename(dir)) then show = parent_dir(dir) end
                if show then poster.dir_art[norm_path(show)] = poster.dir_art[norm_path(show)] or { show = e } end
                poster.dir_art[norm_path(sdir)] = poster.dir_art[norm_path(sdir)] or { season = e }
            elseif e.kind == "movie" then
                local k = norm_path(dir)
                if not poster.dir_art[k] then poster.dir_art[k] = { movie = e } end
            end
        end
    end
end
dir_art = function(paths)
    build_dir_art()
    for _, p in ipairs(paths) do
        local d = poster.dir_art[norm_path(p)]
        if d then
            if d.movie then return resolve_art("m" .. d.movie.hash, d.movie.thumb, "Movies", d.movie.hash) end
            local e = d.show or d.season
            if d.season then
                local sp = resolve_art("se" .. e.s_hash, e.s_thumb, "TV Shows", e.s_hash, e.sh_hash, e.season)
                if sp then return sp end
            end
            return resolve_art("sh" .. e.sh_hash, e.sh_thumb, "TV Shows", e.sh_hash)
        end
    end
end

local function str_hash(s_)
    local h1, h2 = 5381, 52711
    for i = 1, #s_ do
        local c = s_:byte(i)
        h1 = (h1 * 33 + c) % 4294967296
        h2 = (h2 * 31 + c) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end
local function rounded_graph(w, h, r)
    local cov = string.format("clip(%d-hypot(max(0,abs(X+0.5-W/2)-(W/2-%d)),max(0,abs(Y+0.5-H/2)-(H/2-%d)))+0.5,0,1)", r, r, r)
    return string.format("scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,format=rgba,", w, h, w, h) ..
        string.format("geq=r='r(X,Y)*%s':g='g(X,Y)*%s':b='b(X,Y)*%s':a='255*%s',format=bgra", cov, cov, cov, cov)
end
local function poster_pump()
    while poster.busy < 4 and #poster.queue > 0 do
        local job = table.remove(poster.queue, 1)
        poster.busy = poster.busy + 1
        mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
            args = { "mpv", "--no-config", "--really-quiet", "--no-audio", "--frames=1",
                "--vf=lavfi=[" .. rounded_graph(job.w, job.h, job.r) .. "]",
                "--of=rawvideo", "--ovc=rawvideo", "--o=" .. job.out, job.src } }, function(ok, res)
            poster.busy = poster.busy - 1
            local info = utils.file_info(job.out)
            -- judge by the output itself: mpv may exit non-zero even when the picture was written correctly
            if info and info.size == job.w * job.h * 4 then
                poster.ready[job.key] = { file = job.out, w = job.w, h = job.h }
                poster.stats.ready = poster.stats.ready + 1
            else
                poster.ready[job.key] = false
                poster.stats.failed = poster.stats.failed + 1
                local why = res and ((res.stderr ~= "" and res.stderr) or res.error_string) or "unknown"
                poster.stats.err = tostring(why):gsub("[\r\n]+", " "):sub(1, 100)
                require("mp.msg").warn("glass: poster conversion failed for " .. job.src .. ": " .. tostring(why))
            end
            request()
            poster_pump()
        end)
    end
end
-- returns a ready bitmap {file, w, h} or nil (and starts converting it in the background)
poster_bitmap = function(src, still)
    if not src then return nil end
    local w, h, r = POSTER_W, POSTER_H, 18
    if still then w, h, r = STILL_W, STILL_H, 20 end
    local key = src .. "|" .. w .. "x" .. h
    local rd = poster.ready[key]
    if rd ~= nil then return rd or nil end
    local out = utils.join_path(poster_cache_dir, str_hash(key) .. ".bgra")
    local info = utils.file_info(out)
    if info and info.size == w * h * 4 then
        poster.ready[key] = { file = out, w = w, h = h }
        poster.stats.ready = poster.stats.ready + 1
        return poster.ready[key]
    end
    if not poster.queued[key] then
        poster.queued[key] = true
        if not utils.file_info(poster_cache_dir) then
            mp.command_native({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
                args = { "cmd", "/c", "mkdir", (poster_cache_dir:gsub("/", "\\")) } })
        end
        poster.queue[#poster.queue + 1] = { key = key, src = src, out = out, w = w, h = h, r = r }
        poster_pump()
    end
    return nil
end

dir_plex_name = function(paths)
    build_dir_art()
    for _, p in ipairs(paths) do
        local d = poster.dir_art[norm_path(p)]
        if d then
            if d.show and d.show.show then
                return d.show.show .. (d.show.sh_year and (" (" .. d.show.sh_year .. ")") or "")
            elseif d.movie and d.movie.title ~= "" then
                return d.movie.title .. (d.movie.year and (" (" .. d.movie.year .. ")") or "")
            end
            return nil -- season folders keep their own names
        end
    end
end
poster_status = function()
    local st = poster.stats
    local parts = { st.ready .. " posters" }
    if #poster.queue + poster.busy > 0 then parts[#parts + 1] = (#poster.queue + poster.busy) .. " converting" end
    if st.missing > 0 then parts[#parts + 1] = st.missing .. " not found" end
    if st.failed > 0 then parts[#parts + 1] = st.failed .. " failed" .. (st.err and (" (" .. st.err .. ")") or "") end
    return table.concat(parts, ", ")
end
-- overlay slots: cards register what they want shown each frame; changes are sent after drawing
local poster_frame, poster_shown = {}, {}
poster_show = function(bmp, x, y, w, h)
    if #poster_frame >= 64 then return end
    -- show only the part that is on screen: crop the bitmap with an offset instead of hiding it
    local vx1, vy1 = math.max(x, 0), math.max(y, 0)
    local vx2, vy2 = math.min(x + w, W), math.min(y + h, H)
    if vx2 - vx1 < 1 or vy2 - vy1 < 1 then return end
    local sx, sy = bmp.w / w, bmp.h / h
    local cx = clamp(math.floor((vx1 - x) * sx), 0, bmp.w - 1)
    local cy = clamp(math.floor((vy1 - y) * sy), 0, bmp.h - 1)
    local cw = clamp(math.floor((vx2 - vx1) * sx + 0.5), 1, bmp.w - cx)
    local ch = clamp(math.floor((vy2 - vy1) * sy + 0.5), 1, bmp.h - cy)
    poster_frame[#poster_frame + 1] = {
        file = bmp.file, off = (cy * bmp.w + cx) * 4, sw = cw, sh = ch, stride = bmp.w * 4,
        x = math.floor(vx1 + 0.5), y = math.floor(vy1 + 0.5),
        w = math.max(1, math.floor(vx2 - vx1 + 0.5)), h = math.max(1, math.floor(vy2 - vy1 + 0.5)),
    }
end
posters_apply = function(block_x)
    for i = 1, 64 do
        local want = poster_frame[i]
        if want and block_x and want.x + want.w > block_x then want = nil end
        local have = poster_shown[i]
        if want then
            if not have or have.file ~= want.file or have.off ~= want.off or have.sw ~= want.sw or have.sh ~= want.sh
                or have.x ~= want.x or have.y ~= want.y or have.w ~= want.w or have.h ~= want.h then
                mp.commandv("overlay-add", tostring(i - 1), tostring(want.x), tostring(want.y), want.file, tostring(want.off), "bgra",
                    tostring(want.sw), tostring(want.sh), tostring(want.stride), tostring(want.w), tostring(want.h))
                poster_shown[i] = want
            end
        elseif have then
            mp.commandv("overlay-remove", tostring(i - 1))
            poster_shown[i] = nil
        end
    end
    poster_frame = {}
end

end

-- card layout: artwork on top (nothing drawn over it, since posters sit above the interface),
-- then a thin progress bar, the title (two lines), a detail line, and for Recent a link to the season
local function card_height(cw_, portrait, recent)
    local artw = cw_ - 16 * S
    local arth = portrait and artw * 1.5 or artw * 9 / 16
    return 8 * S + arth + 88 * S + (recent and 20 * S or 0)
end

local function render_card(item, x, y, cw_, ch_, a, dt, siblings, kind, portrait)
    local id = (kind or "f") .. item.path
    local over = inside(x, y, x + cw_, y + ch_)
    local h = hover_anim(id, over, dt)
    local lift = 4 * S * h
    y = y - lift
    local artw = cw_ - 16 * S
    local arth = portrait and artw * 1.5 or artw * 9 / 16
    if h > 0 then glow(opts.accent, 0.35 * h * a, rrect(x, y, cw_, ch_, 18 * S), 14 * S) end
    glass(x, y, cw_, ch_, 18 * S, a, true)
    local ax, ay = x + 8 * S, y + 8 * S
    local title = item.name or item.title or basename(item.path)
    local alt -- second name shown in small text under the title
    if item.dir then title = dir_plex_name(item.paths or { item.path }) or title end
    local px = (not item.dir) and plex_get(item.path) or nil
    if px and px.title ~= "" then
        if px.kind == "episode" then
            title = px.title
            alt = (px.show or "") .. ((px.season and px.ep) and string.format("  ·  S%02dE%02d", px.season, px.ep) or "")
        else
            title = px.title .. (px.year and (" (" .. px.year .. ")") or "")
            alt = item.name or strip_ext(basename(item.path))
        end
    elseif not item.dir then
        local fname = item.name or strip_ext(basename(item.path))
        local mt = meta_title(item.path)
        if mt then
            title, alt = mt, fname
        else
            title = fname
            alt = episode_title(item.path)
        end
    end

    -- artwork: a Plex poster/still if there is one, otherwise the generated art or folder icon
    local src
    if item.dir then src = dir_art(item.paths or { item.path })
    else src = file_art(item.path, not portrait) end
    local bmp = poster_bitmap(src, not portrait)
    if lib.moving then bmp = nil end -- pictures are reloaded on every move, so skip them mid-scroll
    if item.dir and not bmp and not (lib.moving and src) then
        fill("FFFFFF", (0.05 + 0.04 * h) * a, rrect(ax, ay, artw, arth, 12 * S))
        shapes(col(opts.text, (0.7 + 0.3 * h) * a), folder_icon(ax + artw / 2, ay + arth / 2, 1.4 * S))
    elseif not bmp then
        art(ax, ay, artw, arth, 12 * S, title, a, h)
        if h > 0 and not lib.moving then
            local cx, cy = ax + artw / 2, ay + arth / 2
            glass(cx - 26 * S, cy - 26 * S, 52 * S, 52 * S, 26 * S, h * a)
            shapes(col("FFFFFF", h * a), I.play(cx + 2.5 * S, cy, 1.4 * S))
        end
    else
        fill("000000", 0.6 * a, rrect(ax, ay, artw, arth, 12 * S)) -- backing while the picture loads
        if a > 0.95 then poster_show(bmp, ax, ay, artw, arth) end
    end

    -- progress just under the artwork
    if not item.dir then
        local hist = pos_get(item.path)
        local pos, dur = (hist and hist.pos) or item.pos, (hist and hist.dur) or item.dur
        if pos and dur and dur > 0 and pos > 0 and not (hist and hist.done) then
            local bx1, bx2, by = ax + 2 * S, ax + artw - 2 * S, ay + arth + 6 * S
            fill("FFFFFF", 0.14 * a, rrect(bx1, by - 1.5 * S, bx2 - bx1, 3 * S, 1.5 * S))
            glow(opts.accent, 0.55 * a, rrect(bx1, by - 1.5 * S, (bx2 - bx1) * clamp(pos / dur, 0, 1), 3 * S, 1.5 * S), 5 * S)
            fill(opts.accent, a, rrect(bx1, by - 1.5 * S, (bx2 - bx1) * clamp(pos / dur, 0, 1), 3 * S, 1.5 * S))
        end
    end

    local ty = ay + arth + 24 * S
    local tmax = cw_ - 28 * S
    local tc = col("FFFFFF", (0.9 + 0.1 * h) * a)
    local l1, rest, short2, overflow = wrap2(title, tmax, 15 * S, 600)
    text(x + 14 * S, ty, 4, 15 * S, tc, l1, 600, clipr(x, y, x + 14 * S + tmax, y + ch_))
    if rest then
        if overflow and over then
            marquee(id, x + 14 * S, ty + 19 * S, 15 * S, tc, rest, 600, tmax, ty + 8 * S, ty + 30 * S, true)
        else
            text(x + 14 * S, ty + 19 * S, 4, 15 * S, tc, short2, 600, clipr(x, y, x + 14 * S + tmax, y + ch_))
        end
    end
    local sub
    local is_recent = kind == "recent"
    if item.dir then sub = (title ~= item.name) and ("Folder  ·  " .. item.name) or "Folder"
    elseif is_recent then
        local pr = pos_get(item.path) or item
        if item.upnext and not (pr.pos and pr.pos > 0) then sub = "Up next"
        elseif pr.done then sub = "Watched"
        elseif pr.pos and (pr.dur or item.dur) and (pr.dur or item.dur) > 0 then
            sub = math.max(1, math.floor(((pr.dur or item.dur) - pr.pos) / 60 + 0.5)) .. " min left"
        else sub = is_url(item.path) and "Stream" or "Recently played" end
    else sub = alt and ((item.ext or "") .. "  ·  " .. alt) or item.ext end
    local sub_max = cw_ - 28 * S - ((is_recent and over) and 26 * S or 0)
    if sub then text(x + 14 * S, ty + 40 * S, 4, 12 * S, col(opts.muted, a), sub, 500, clipr(x, y, x + 14 * S + sub_max, y + ch_)) end

    -- Recent: link to the show/season folder, and a remove button
    local ctx = is_recent and file_context(item.path) or nil
    local link
    if ctx then
        -- Plex's show name for the link when Plex knows this episode
        local pe = plex_get(item.path)
        if pe and pe.kind == "episode" and pe.show then
            ctx = { root = ctx.root, segs = ctx.segs,
                label = pe.show .. (pe.sh_year and (" (" .. pe.sh_year .. ")") or "") .. "  ·  " .. ctx.segs[#ctx.segs] }
        end
    end
    if ctx then
        local ly = ty + 60 * S
        local lw = math.min(text_width(ctx.label, 12 * S, 600), cw_ - 28 * S)
        local lo = inside(x + 10 * S, ly - 10 * S, x + 18 * S + lw, ly + 10 * S)
        local lh = hover_anim("ctx" .. item.path, lo, dt)
        if lh > 0 and opts.glow then
            out[#out + 1] = string.format("{\\an4\\pos(%s,%s)\\fn%s\\fs%s\\b600\\bord0\\shad0\\blur%s%s}%s", f(x + 14 * S), f(ly),
                opts.font, f(12 * S), f(5 * S), col(opts.accent, 0.8 * lh * a), esc(ctx.label))
        end
        marquee("ctxl" .. item.path, x + 14 * S, ly, 12 * S, col(lh > 0.5 and opts.accent or opts.text, (0.75 + 0.25 * lh) * a),
            ctx.label, 600, cw_ - 28 * S, ly - 10 * S, ly + 10 * S, lo)
        link = { x + 10 * S, ly - 10 * S, x + 18 * S + lw, ly + 10 * S }
    end
    local rmx, rmy = x + cw_ - 22 * S, ty + 40 * S
    if is_recent and over then
        local xo = inside(rmx - 11 * S, rmy - 11 * S, rmx + 11 * S, rmy + 11 * S)
        fill("FFFFFF", (xo and 0.14 or 0.07) * a, circle(rmx, rmy, 11 * S))
        local c1, c2 = I.close(rmx, rmy, 0.65 * S)
        shapes(col(xo and opts.accent or opts.text, a), c1); shapes(col(xo and opts.accent or opts.text, a), c2)
    end
    add_hit(x, y, x + cw_, y + ch_, function()
        if item.dir then table.insert(lib.stack, { view = lib.cur or false, scroll = lib.scroll }); lib.cur = { name = title, paths = item.paths or { item.path } }; lib.scroll = 0
        else play_file(item.path) end
        request()
    end)
    if is_recent and over then
        add_hit(rmx - 11 * S, rmy - 11 * S, rmx + 11 * S, rmy + 11 * S, function()
            local i = history_find(item.src or item.path)
            if i then table.remove(history, i); save_history() end
            request()
        end)
    end
    if link then
        add_hit(link[1], link[2], link[3], link[4], function()
            open_context(ctx)
            request()
        end)
    end
end

function lib.search_results()
    local sr = lib.search
    local key = sr.text:lower() .. "|" .. tostring(plex.sig)
    if sr.cache_key == key then return sr.cache end
    local words = {}
    for w in sr.text:lower():gmatch("%S+") do words[#words + 1] = w end
    local function hit(hay)
        hay = hay:lower()
        for _, w in ipairs(words) do if not hay:find(w, 1, true) then return false end end
        return true
    end
    local shows, movies, eps, other = {}, {}, {}, {}
    local seen_show, seen_path = {}, {}
    for _, e in pairs(plex.items) do
        if e.kind == "episode" then
            local dir = parent_dir(e.path)
            local showdir = dir and season_number(basename(dir)) and parent_dir(dir) or dir
            if showdir and e.show and hit(e.show) and not seen_show[norm_path(showdir)] then
                seen_show[norm_path(showdir)] = true
                shows[#shows + 1] = { dir = true, name = e.show, path = showdir, paths = { showdir } }
            end
            if hit(e.title .. " " .. string.format("s%02de%02d", e.season or 0, e.ep or 0)) and #eps < 60 then
                eps[#eps + 1] = { path = e.path, name = strip_ext(basename(e.path)), ext = (e.path:match("%.([^%.]+)$") or ""):upper() }
            end
            seen_path[norm_path(e.path)] = true
        elseif e.kind == "movie" then
            seen_path[norm_path(e.path)] = true
            if hit(e.title .. " " .. tostring(e.year or "") .. " " .. basename(e.path)) then
                movies[#movies + 1] = { path = e.path, name = strip_ext(basename(e.path)), ext = (e.path:match("%.([^%.]+)$") or ""):upper() }
            end
        end
    end
    -- folders and files in the library sections that Plex doesn't cover
    for _, root in ipairs(lib_roots()) do
        local d = scan_multi(root.paths)
        for _, e in ipairs(d.dirs) do
            if hit(e.name) and not seen_show[norm_path(e.path)] then other[#other + 1] = e end
        end
        for _, e in ipairs(d.files) do
            if not seen_path[norm_path(e.path)] and hit(e.name) then other[#other + 1] = e end
        end
    end
    local function by_name(p1, p2) return natural_less(p1.name or "", p2.name or "") end
    table.sort(shows, by_name); table.sort(movies, by_name); table.sort(other, by_name)
    sr.cache = {
        { title = "Shows", items = shows, rows = 2 },
        { title = "Movies", items = movies, rows = 2, siblings = nil },
        { title = "Episodes", items = eps, rows = 3 },
        { title = "Folders & files", items = other, rows = 2 },
    }
    sr.cache_key = key
    return sr.cache
end

local function render_library(dt)
    -- backdrop with soft color so the glass has something to sit on
    fill("08090C", 1, box(0, 0, W, H))
    fill(opts.accent, 0.20, circle(W * 0.12, H * 0.05, H * 0.5), 140 * S)
    fill("3A6BFF", 0.16, circle(W * 0.9, H * 0.95, H * 0.55), 160 * S)
    fill("8A3AFF", 0.08, circle(W * 0.55, H * 0.45, H * 0.35), 160 * S)

    local m = 48 * S
    local gap = 22 * S
    local cols = math.max(1, math.floor((W - 2 * m + gap) / (250 * S + gap)))
    local cw_ = (W - 2 * m - (cols - 1) * gap) / cols
    local ch_ = (cw_ - 16 * S) * 9 / 16 + 84 * S
    if lib.prev ~= nil and lib.scroll ~= lib.prev then lib.target = lib.scroll end
    lib.target = lib.target or lib.scroll
    lib.moving = dragging == "libscroll" or math.abs(lib.target - lib.scroll) >= 0.5 or (mp.get_time() - (lib.last_scroll_t or 0)) < 0.12
    if lib.moving then animating = true end
    if dragging ~= "libscroll" then
        local d = lib.target - lib.scroll
        if math.abs(d) < 0.5 then lib.scroll = lib.target
        else lib.scroll = lib.scroll + d * (1 - math.exp(-dt * 14)); animating = true end
    end
    local y = 36 * S - lib.scroll
    local top_y = y

    -- header
    if lib.cur then
        local bx, by = m + 18 * S, y + 30 * S
        local o = inside(bx - 18 * S, by - 18 * S, bx + 18 * S, by + 18 * S)
        local h = hover_anim("back", o, dt)
        glass(bx - 18 * S, by - 18 * S, 36 * S, 36 * S, 18 * S, 1)
        fill("FFFFFF", 0.1 * h, circle(bx, by, 18 * S))
        shape(col(opts.text, 1), line(bx + 3 * S, by - 7 * S, bx - 4 * S, by, 2.2 * S))
        shape(col(opts.text, 1), line(bx - 4 * S, by, bx + 3 * S, by + 7 * S, 2.2 * S))
        add_hit(bx - 18 * S, by - 18 * S, bx + 18 * S, by + 18 * S, function()
            local prev = table.remove(lib.stack)
            lib.cur = prev and prev.view or nil
            lib.scroll = prev and prev.scroll or 0
            request()
        end)
        text(m + 48 * S, y + 30 * S, 4, 28 * S, col("FFFFFF", 1), lib.cur.name, 700, clipr(0, 0, W - 220 * S, H))
    else
        text(m, y + 26 * S, 4, 30 * S, col("FFFFFF", 1), "Library", 700)
        text(m, y + 56 * S, 4, 13 * S, col(opts.muted, 1),
            "Drop files anywhere to play" .. (plex.ok and ("   ·   Plex library connected   ·   " .. poster_status()) or (opts.plex_db ~= "" and ("   ·   Plex: " .. (plex.err or "not readable")) or "")), 500)
    end
    do -- open files button
        local bw, bh = 132 * S, 40 * S
        local bx, by = W - m - bw, y + 10 * S
        local o = inside(bx, by, bx + bw, by + bh)
        local h = hover_anim("openbtn", o, dt)
        local p = rrect(bx, by, bw, bh, bh / 2)
        glow(opts.accent, 0.45 + 0.4 * h, p, (8 + 6 * h) * S)
        fill(opts.accent, 1, p)
        fill("FFFFFF", 0.2 + 0.08 * h, rrect(bx + 4 * S, by + 2 * S, bw - 8 * S, bh * 0.42, bh * 0.2), 2 * S)
        text(bx + bw / 2, by + bh / 2, 5, 15 * S, col("FFFFFF", 1), "Open files", 600)
        add_hit(bx, by, bx + bw, by + bh, open_dialog)

        -- search box, left of "Open files"
        local sw = math.min(320 * S, math.max(160 * S, bx - 16 * S - (m + 260 * S)))
        local sx = bx - 16 * S - sw
        local sr = lib.search
        local so = inside(sx, by, sx + sw, by + bh)
        local shv = hover_anim("searchbox", so or sr.focus, dt)
        local sp = rrect(sx, by, sw, bh, bh / 2)
        if sr.focus then glow(opts.accent, 0.35, sp, 8 * S) end
        glass(sx, by, sw, bh, bh / 2, 1, true)
        if sr.focus then stroke(opts.accent, 0.8, 1 * S, sp) end
        fill("FFFFFF", 0.05 * shv, sp)
        local mx, my = sx + 22 * S, by + bh / 2 - 1 * S
        stroke(opts.text, 0.85, 1.8 * S, circle(mx, my, 5.5 * S))
        shape(col(opts.text, 0.85), line(mx + 4 * S, my + 4 * S, mx + 8.5 * S, my + 8.5 * S, 2 * S))
        local tx0 = sx + 38 * S
        local tmax_ = sw - 38 * S - (sr.text ~= "" and 34 * S or 16 * S)
        if sr.text == "" then
            text(tx0, by + bh / 2, 4, 14 * S, col(opts.muted, 0.9), sr.focus and "Type to search…" or "Search  (Ctrl+F)", 500)
        else
            local tw_ = text_width(sr.text, 14 * S, 500)
            local off = math.max(0, tw_ - tmax_)
            text(tx0 - off, by + bh / 2, 4, 14 * S, col("FFFFFF", 1), sr.text, 500, clipr(tx0, by, tx0 + tmax_ + 2 * S, by + bh))
            if sr.focus then fill(opts.accent, 1, box(tx0 + tw_ - off + 2 * S, by + 11 * S, tx0 + tw_ - off + 3.5 * S, by + bh - 11 * S)) end
            local cx2 = sx + sw - 20 * S
            local c1, c2 = I.close(cx2, by + bh / 2, 0.7 * S)
            local xo = inside(cx2 - 11 * S, by, cx2 + 11 * S, by + bh)
            shapes(col(xo and opts.accent or opts.text, 1), c1); shapes(col(xo and opts.accent or opts.text, 1), c2)
            add_hit(cx2 - 12 * S, by, cx2 + 12 * S, by + bh, function() sr.text = ""; lib.search_focus(true); request() end, { group = "search" })
        end
        if sr.focus and sr.text == "" then fill(opts.accent, 1, box(tx0, by + 11 * S, tx0 + 1.5 * S, by + bh - 11 * S)) end
        add_hit(sx, by, sx + sw - (sr.text ~= "" and 26 * S or 0), by + bh, function() lib.search_focus(true); request() end, { group = "search" })
    end
    y = y + 100 * S

    -- tall poster cards for shows/movies/Recent, wide cards for episodes and other files
    local function wants_portrait(items, kind)
        if kind == "recent" then return true end
        if #items == 0 then return false end
        for _, it in ipairs(items) do
            if not it.dir then
                local px = plex_get(it.path)
                if not px or px.kind ~= "movie" then return false end
            end
        end
        return true
    end
    local function grid_cols(items, kind)
        local mincw = wants_portrait(items, kind) and 210 * S or 300 * S
        return math.max(1, math.floor((W - 2 * m + gap) / (mincw + gap)))
    end
    local function grid(items, siblings, kind, max_rows, a)
        local portrait = wants_portrait(items, kind)
        local mincw = portrait and 210 * S or 300 * S
        local gcols = math.max(1, math.floor((W - 2 * m + gap) / (mincw + gap)))
        local gcw = (W - 2 * m - (gcols - 1) * gap) / gcols
        local gch = card_height(gcw, portrait, kind == "recent")
        local n = #items
        if max_rows then n = math.min(n, gcols * max_rows) end
        for i = 1, n do
            local c, r = (i - 1) % gcols, math.floor((i - 1) / gcols)
            local cx, cy = m + c * (gcw + gap), y + r * (gch + gap) + (1 - (a or 1)) * 10 * S
            if cy + gch > -20 * S and cy < H + 20 * S then render_card(items[i], cx, cy, gcw, gch, a or 1, dt, siblings, kind, portrait) end
        end
        local rows = math.ceil(n / gcols)
        y = y + rows * (gch + gap)
    end
    -- collapsible section header; returns (is_open, fade-in amount)
    local function section(key, title, sub, count, ctl)
        local is_open = not collapsed[key]
        local e = step(lib.open_anim[key] or (is_open and 1 or 0), is_open and 1 or 0, dt, 180)
        lib.open_anim[key] = e
        if e ~= (is_open and 1 or 0) then animating = true end
        local hy, hh = y - 4 * S, (sub and 52 or 40) * S
        local o = inside(m - 10 * S, hy, W - m + 10 * S, hy + hh) and not (sec_drag and sec_drag.active)
        local h = hover_anim("sec" .. key, o, dt)
        fill("FFFFFF", 0.06 * h, rrect(m - 10 * S, hy, W - 2 * m + 20 * S, hh, 14 * S))
        -- chevron: points down when open, right when collapsed
        local ang = (1 - ease(e)) * -math.pi / 2
        local cx, cy = m + 8 * S, y + 12 * S
        local function rot(px, py) return cx + px * math.cos(ang) - py * math.sin(ang), cy + px * math.sin(ang) + py * math.cos(ang) end
        local ax, ay = rot(-5 * S, -2.5 * S)
        local bx, by = rot(0, 2.5 * S)
        local qx, qy = rot(5 * S, -2.5 * S)
        local cc = col(opts.text, 0.7 + 0.3 * h)
        shape(cc, line(ax, ay, bx, by, 2 * S))
        shape(cc, line(bx, by, qx, qy, 2 * S))
        local ghosted = sec_drag and sec_drag.active and sec_drag.key == key
        text(m + 26 * S, y + 11 * S, 4, 18 * S, col("FFFFFF", ghosted and 0.25 or 0.95), title, 700)
        if sub then text(m + 26 * S, y + 33 * S, 4, 12 * S, col(opts.muted, 1), sub, 500, clipr(0, 0, W - m - 120 * S, H)) end
        local count_w = 0
        if count and ctl and ctl.more then
            local label = "See all " .. count .. "  ›"
            count_w = text_width(label, 13 * S, 600)
            local mo = inside(W - m - count_w - 8 * S, y, W - m + 6 * S, y + 22 * S)
            local mh = hover_anim("more" .. key, mo, dt)
            text(W - m, y + 11 * S, 6, 13 * S, col(mh > 0.5 and opts.accent or opts.text, 0.75 + 0.25 * mh), label, 600)
            ctl.more_hit = { W - m - count_w - 8 * S, y - 4 * S, W - m + 6 * S, y + 24 * S }
        elseif count then
            local label = count .. (count == 1 and " item" or " items")
            count_w = text_width(label, 13 * S, 500)
            text(W - m, y + 11 * S, 6, 13 * S, col(opts.muted, 0.6 + 0.4 * h), label, 500)
        end
        sec_pos[#sec_pos + 1] = { key = key, cy = hy + hh / 2, top = hy }
        if not (sec_drag and sec_drag.active) then
            add_hit(m - 10 * S, hy, W - m + 10 * S, hy + hh, function()
                sec_drag = { key = key, title = title, sy = mouse.y, active = false }
                dragging = "section"
            end)
            if ctl and ctl.more_hit then
                local mh_ = ctl.more_hit
                add_hit(mh_[1], mh_[2], mh_[3], mh_[4], ctl.more)
            end
        end
        -- grip dots: shows the header can be dragged
        if h > 0 and ctl then
            local gx = W - m - count_w - (count and 30 or 20) * S
            local gy = hy + hh / 2
            for gi = 0, 2 do
                for gj = 0, 1 do
                    fill("FFFFFF", 0.55 * h, circle(gx + gj * 6 * S, gy + (gi - 1) * 6 * S, 1.6 * S))
                end
            end
        end
        y = y + (sub and 54 or 40) * S
        return is_open, ease(e)
    end

    if not lib.cur and lib.search.text ~= "" then
        local res = lib.search_results()
        local function heading(t, n)
            text(m, y + 10 * S, 4, 18 * S, col("FFFFFF", 0.95), t, 700)
            text(m + text_width(t, 18 * S, 700) + 10 * S, y + 11 * S, 4, 13 * S, col(opts.muted, 1), tostring(n), 600)
            y = y + 40 * S
        end
        local any = false
        for _, grp in ipairs(res) do
            if #grp.items > 0 then
                any = true
                heading(grp.title, #grp.items)
                grid(grp.items, grp.siblings, "f", grp.rows)
                y = y + 14 * S
            end
        end
        if not any then
            text(m, y + 10 * S, 4, 16 * S, col(opts.muted, 1), "No matches for \"" .. lib.search.text .. "\"", 500)
            y = y + 40 * S
        end
    elseif lib.cur then
        local d = scan_multi(lib.cur.paths)
        local items = {}
        for _, e in ipairs(d.dirs) do items[#items + 1] = e end
        for _, e in ipairs(d.files) do items[#items + 1] = e end
        if #items == 0 then
            text(m, y + 10 * S, 4, 15 * S, col(opts.muted, 1), "No videos in this folder", 500)
            y = y + 40 * S
        end
        grid(items, d.files, "f")
    else
        local recent, seen_show = {}, {}
        local merged = {}
        for _, h in ipairs(history) do merged[#merged + 1] = h end
        for _, e in ipairs(plex.recent) do
            local mine = history_find(e.path)
            if not mine then merged[#merged + 1] = { path = e.path, title = e.title, pos = e.pos, dur = e.dur, done = e.done, t = e.t, plex = true } end
        end
        table.sort(merged, function(p1, p2)
            local t1 = math.max(p1.t or 0, (plex_get(p1.path) or {}).t or 0)
            local t2 = math.max(p2.t or 0, (plex_get(p2.path) or {}).t or 0)
            return t1 > t2
        end)
        for _, h in ipairs(merged) do
            -- one tile per show: history is newest-first, so the first episode seen wins
            local key = norm_path(h.path)
            local dir = not is_url(h.path) and parent_dir(h.path)
            if dir and season_number(basename(dir)) and parent_dir(dir) then key = norm_path(parent_dir(dir)) end
            if not seen_show[key] and (is_url(h.path) or utils.file_info(h.path)) then
                seen_show[key] = true
                -- continue watching: in-progress stays; a finished episode becomes the next unwatched one;
                -- finished movies and finished shows drop out
                local pr = pos_get(h.path) or h
                if not pr.done then
                    recent[#recent + 1] = h
                elseif dir and season_number(basename(dir)) then
                    local list = context_list(h.path)
                    local idx
                    for i, lp in ipairs(list) do if norm_path(lp) == norm_path(h.path) then idx = i end end
                    for i = (idx or #list) + 1, #list do
                        local q = pos_get(list[i])
                        if not (q and q.done) then
                            recent[#recent + 1] = { path = list[i], t = h.t, upnext = true, src = h.path }
                            break
                        end
                    end
                end
            end
            if #recent >= math.max(1, math.floor((W - 2 * m + gap) / (210 * S + gap))) then break end
        end
        local secs = {}
        if #recent > 0 then secs[#secs + 1] = { key = "Recent" } end
        for _, root in ipairs(lib_roots()) do secs[#secs + 1] = { key = "lib:" .. root.name, root = root } end
        for i, sc in ipairs(secs) do
            sc.rank = 1000 + i
            for j, k in ipairs(sec_order) do if k == sc.key then sc.rank = j end end
        end
        table.sort(secs, function(p1, p2) return p1.rank < p2.rank end)
        local function move(idx, dir)
            local j = idx + dir
            if j < 1 or j > #secs then return end
            secs[idx], secs[j] = secs[j], secs[idx]
            local new, seen = {}, {}
            for _, sc in ipairs(secs) do new[#new + 1] = sc.key; seen[sc.key] = true end
            for i, k in ipairs(sec_order) do -- keep sections that are hidden right now (e.g. an empty Recent)
                if not seen[k] then table.insert(new, math.min(i, #new + 1), k) end
            end
            sec_order = new
            save_lib_state()
            request()
        end
        sec_pos = {}
        lib.sec_keys = {}
        for _, sc in ipairs(secs) do lib.sec_keys[#lib.sec_keys + 1] = sc.key end
        local dragging_sec = sec_drag and sec_drag.active
        for idx, sc in ipairs(secs) do
            local ctl = { first = idx == 1, last = idx == #secs }
            if not sc.root then
                local open_, a = section("Recent", "Continue watching", nil, nil, ctl)
                if open_ and not dragging_sec then grid(recent, nil, "recent", 1, a) end
            else
                local root = sc.root
                local d = scan_multi(root.paths)
                local items = {}
                for _, e in ipairs(d.dirs) do items[#items + 1] = e end
                for _, e in ipairs(d.files) do items[#items + 1] = e end
                if #items > grid_cols(items, "f") * 2 then
                    ctl.more = function()
                        table.insert(lib.stack, { view = false, scroll = lib.scroll })
                        lib.cur = { name = root.name, paths = root.paths }
                        lib.scroll = 0
                        request()
                    end
                end
                local open_, a = section("lib:" .. root.name, root.name, table.concat(root.paths, "   +   "), #items, ctl)
                if open_ and not dragging_sec then
                    if #items == 0 then
                        local found = false
                        for _, p in ipairs(root.paths) do if utils.file_info(p) then found = true end end
                        text(m, y + 6 * S, 4, 14 * S, col(opts.muted, a),
                            found and "No videos here yet" or "Folder not found. Check library_folders in glass.conf", 500)
                        y = y + 40 * S
                    end
                    grid(items, d.files, "f", 2, a)
                end
            end
            y = y + 14 * S
        end
        if dragging_sec then
            -- where the section would land
            local others = {}
            for _, sp in ipairs(sec_pos) do if sp.key ~= sec_drag.key then others[#others + 1] = sp end end
            local idx = 1
            for _, sp in ipairs(others) do if mouse.y > sp.cy then idx = idx + 1 end end
            lib.drop_idx = idx
            local ly = others[idx] and (others[idx].top - 7 * S) or (y - 10 * S)
            glow(opts.accent, 0.9, rrect(m - 10 * S, ly - 1.5 * S, W - 2 * m + 20 * S, 3 * S, 1.5 * S), 6 * S)
            fill(opts.accent, 1, rrect(m - 10 * S, ly - 1.5 * S, W - 2 * m + 20 * S, 3 * S, 1.5 * S))
            -- floating copy of the dragged header
            local gy = mouse.y - 22 * S
            glow(opts.accent, 0.35, rrect(m - 10 * S, gy, W - 2 * m + 20 * S, 44 * S, 16 * S), 12 * S)
            glass(m - 10 * S, gy, W - 2 * m + 20 * S, 44 * S, 16 * S, 1, true)
            for gi = 0, 2 do
                for gj = 0, 1 do fill("FFFFFF", 0.7, circle(m + 6 * S + gj * 6 * S, gy + 22 * S + (gi - 1) * 6 * S, 1.6 * S)) end
            end
            text(m + 26 * S, gy + 22 * S, 4, 18 * S, col("FFFFFF", 1), sec_drag.title, 700)
            animating = true
        end
    end
    lib.max_scroll = math.max(0, (y - top_y) - H + 40 * S)
    lib.scroll = clamp(lib.scroll, 0, lib.max_scroll)
    lib.target = clamp(lib.target, 0, lib.max_scroll)
    lib.prev = lib.scroll
    if lib.max_scroll > 0 then
        -- scrollbar: drag the thumb, or click the track to jump there
        local view = H - 24 * S
        local sh = math.max(40 * S, view * H / (H + lib.max_scroll))
        local sy = 12 * S + (view - sh) * (lib.scroll / lib.max_scroll)
        lib.sb = { top = 12 * S, view = view, sh = sh }
        local zone = inside(W - 20 * S, 12 * S, W, 12 * S + view)
        local sbh = hover_anim("libsb", zone or dragging == "libscroll", dt)
        local tw = (3 + 3 * sbh) * S
        if sbh > 0 then fill("FFFFFF", 0.05 * sbh, rrect(W - 6 * S - tw, 12 * S, tw, view, tw / 2)) end
        fill("FFFFFF", 0.18 + 0.22 * sbh, rrect(W - 6 * S - tw, sy, tw, sh, tw / 2))
        add_hit(W - 20 * S, 12 * S, W, 12 * S + view, function()
            lib.sb_grab = (mouse.y >= sy and mouse.y <= sy + sh) and (mouse.y - sy) or sh / 2
            dragging = "libscroll"
            lib.scroll_drag()
        end)
    end
end

-- a show's folder for episodes in "Season N" folders, otherwise the file itself
local function show_key(path)
    if not path or is_url(path) then return path end
    local dir = parent_dir(path)
    if dir and season_number(basename(dir)) and parent_dir(dir) then return "show:" .. norm_path(parent_dir(dir)) end
    return norm_path(path)
end
local function migrate_history()
    local seen, kept = {}, {}
    for _, h in ipairs(history) do
        if h.path then
            if not positions[h.path] then positions[h.path] = { pos = h.pos, dur = h.dur, done = h.done, t = h.t } end
            local k = show_key(h.path)
            if not seen[k] then seen[k] = true; kept[#kept + 1] = h end
        end
    end
    history = kept
end

-- ---------------------------------------------------------------- upscaling shaders
local function shader_list(mode)
    local list = {}
    if mode == "off" then return list end
    for name in ((mode == "anime") and opts.anime_shaders or opts.live_shaders):gmatch("[^,;]+") do
        local full = mp.command_native({ "expand-path", "~~/shaders/" .. trim(name) })
        if full and utils.file_info(full) then list[#list + 1] = full end
    end
    return list
end
auto_shader_mode = function(path)
    local l = (path or ""):lower()
    for w in opts.anime_folders:gmatch("[^,;]+") do
        w = trim(w):lower()
        if w ~= "" and l:find(w, 1, true) then return "anime" end
    end
    return "live"
end
local function apply_shaders(mode)
    shader_state.mode = mode
    mp.set_property_native("glsl-shaders", shader_list(mode))
    request()
end
local function choose_shaders(path)
    local key = show_key(path)
    local ov = key and shader_override[key]
    shader_state.auto = ov == nil
    apply_shaders(ov or auto_shader_mode(path))
end
set_shader_mode = function(mode)
    local path = mp.get_property("path")
    if not path then return end
    local key = show_key(path)
    if mode == auto_shader_mode(path) then shader_override[key] = nil else shader_override[key] = mode end
    shader_state.auto = shader_override[key] == nil
    save_lib_state()
    apply_shaders(mode)
    mp.osd_message("")
end
mp.register_event("start-file", function()
    local path = mp.get_property("path")
    if path then choose_shaders(path) end
end)
mp.register_event("end-file", function() shader_state.mode = nil end)

-- events for history / resume
mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    if not path then return end
    cur_path, cur_pos, cur_dur = path, nil, mp.get_property_number("duration")
    if not is_url(path) then
        local abs = utils.join_path(utils.getcwd() or "", path)
        if path:match("^%a:[/\\]") or path:sub(1, 1) == "/" or path:sub(1, 2) == "\\\\" then abs = path end
        cur_path = abs
    end
    -- resume however the file was opened (Glass app, double-click, next in playlist), not only from the
    -- library screen. Read the saved position before this load refreshes the record below.
    -- remember what mpv knew at open time, so a late Plex answer can still win if it's newer
    local before = positions[cur_path]
    -- (skipped when started with --start, e.g. "Play from beginning" in the Glass app)
    plex.load_resume = (mp.get_property("start") or "none") == "none" and { path = cur_path, t = before and before.t or 0 } or nil
    if not pending_resume and (mp.get_property("start") or "none") == "none" then
        local r = pos_get(cur_path) or pos_get(path)
        if r and r.pos and r.pos > 10 and not r.done and not (cur_dur and r.pos >= cur_dur - 5) then
            pending_resume = { path = cur_path, pos = r.pos }
        end
    end
    local _, h = history_find(cur_path)
    h = h or { path = cur_path }
    local key = show_key(cur_path)
    for k = #history, 1, -1 do -- drop this file and any other episode of the same show
        if history[k].path == cur_path or show_key(history[k].path) == key then table.remove(history, k) end
    end
    local p = positions[cur_path]
    h.pos, h.done = p and p.pos or h.pos, p and p.done or h.done
    h.title = mp.get_property("media-title") or h.title
    h.dur = cur_dur or h.dur
    h.t = os.time()
    table.insert(history, 1, h)
    positions[cur_path] = positions[cur_path] or { pos = h.pos, dur = h.dur, done = h.done }
    positions[cur_path].t = os.time()
    while #history > opts.history_size do table.remove(history) end
    save_history()
    if pending_resume and (pending_resume.path == path or pending_resume.path == cur_path) then
        mp.commandv("seek", tostring(pending_resume.pos), "absolute")
    end
    pending_resume = nil
end)
mp.observe_property("time-pos", "number", function(_, v) if v then cur_pos = v end end)
-- Keep Plex's resume point fresh while watching (so another device picks up the right spot), even
-- while paused. Only on the PC that runs Plex (needs its token), only when the spot actually moved:
-- one tiny local web request every 20 s at most.
plex.push = function(force)
    if not cur_path or not cur_pos or not plex.token then return end
    local px = plex_get(cur_path)
    if not px or not px.id then return end
    local last = plex.pushed
    if not force and last and last.path == cur_path and math.abs((last.pos or 0) - cur_pos) < 2 then return end
    local done = cur_dur and cur_dur > 0 and cur_pos >= opts.watched_at * cur_dur
    if last and last.path == cur_path and last.done and done then return end
    local url
    if done then
        url = string.format("http://127.0.0.1:32400/:/scrobble?key=%d&identifier=com.plexapp.plugins.library", px.id)
    elseif cur_pos >= 10 then
        url = string.format("http://127.0.0.1:32400/:/progress?key=%d&identifier=com.plexapp.plugins.library&time=%d&state=%s",
            px.id, math.floor(cur_pos * 1000), mp.get_property_bool("pause") and "paused" or "playing")
    else
        return
    end
    plex.pushed = { path = cur_path, pos = cur_pos, done = done }
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = { "curl.exe", "-s", "-m", "5", "-o", "NUL", "-H", "@" .. plex.token, url } }, function() end)
end
-- Plex's token lives in the registry of the Windows user that runs Plex; read it once
mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
    args = { "reg", "query", "HKCU\\Software\\Plex, Inc.\\Plex Media Server", "/v", "PlexOnlineToken" } }, function(ok, res)
    local tok = ok and res and res.stdout and res.stdout:match("PlexOnlineToken%s+REG_SZ%s+(%S+)")
    if not tok or tok == "" then return end
    -- keep the token out of command lines (and mpv's log): curl reads it from this header file
    local hdr = mp.command_native({ "expand-path", "~~/cache/glass-plex-header.txt" })
    local fh = io.open(hdr, "w")
    if not fh then
        mp.command_native({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
            args = { "cmd", "/c", "mkdir", (mp.command_native({ "expand-path", "~~/cache" }):gsub("/", "\\")) } })
        fh = io.open(hdr, "w")
    end
    if not fh then return end
    fh:write("X-Plex-Token: " .. tok .. "\n")
    fh:close()
    plex.token = hdr   -- path of the header file
end)
mp.observe_property("pause", "bool", function(_, paused) if paused then plex.push(true) end end)

-- save the spot every 20 s while playing, so closing the window or a crash doesn't lose it
plex.autosave = mp.add_periodic_timer(20, function()
    plex.push(false)
    if not cur_path or not cur_pos or cur_pos < 10 or mp.get_property_bool("pause") then return end
    local p = positions[cur_path] or {}
    positions[cur_path] = p
    if cur_dur then p.dur = cur_dur end
    if cur_dur and cur_dur > 0 and cur_pos >= opts.watched_at * cur_dur then p.pos, p.done = 0, true
    else p.pos, p.done = cur_pos, false end
    p.t = os.time()
    save_history()
end)
mp.observe_property("duration", "number", function(_, v) if v then cur_dur = v end end)
mp.register_event("end-file", function(e)
    history_update(e and e.reason == "eof")
    cur_path = nil
end)
mp.register_event("shutdown", function() history_update(false) end)
load_history()
migrate_history()
load_lib_state()
plex_reload()
-- restore the last volume, then keep it saved (written a moment after it stops changing)
if saved_volume then mp.set_property_number("volume", saved_volume) end
local vol_save_timer = mp.add_timeout(1, function() save_lib_state() end)
vol_save_timer:kill()
mp.observe_property("volume", "number", function(_, v)
    if v and v ~= saved_volume then
        saved_volume = v
        vol_save_timer:kill()
        vol_save_timer:resume()
    end
end)
mp.register_event("shutdown", function() save_lib_state() end)
mp.set_property("window-dragging", "no") -- never move the window by dragging inside it

-- hide mpv's own idle logo (the built-in controller draws it even with osc=no)
local function hide_builtin_idle() mp.commandv("script-message", "osc-idlescreen", "no", "no_osd") end
hide_builtin_idle()
mp.add_timeout(0.3, hide_builtin_idle)
mp.add_timeout(1.5, hide_builtin_idle)

local function render(now, dt)
    out, hits = {}, {}
    animating = false
    tooltip = nil
    local pe = ease(anim.playlist)
    local cw = W - panel_width() * pe
    if opts.playlist_push_video then
        local m = clamp((panel_width() + 16 * S) * pe / math.max(W, 1), 0, 0.8)
        if math.abs(m - last_margin) > 0.0005 then
            last_margin = m
            mp.set_property_number("video-margin-ratio-right", m)
        end
    end
    local panel_top
    if P["idle-active"] then
        render_library(dt)
    else
        local a = ease(anim.ui)
        if a > 0 then panel_top = render_controls(now, dt, a, cw) end
        render_flash(now, cw)
    end
    render_playlist(dt)
    if not P["idle-active"] then render_menu(dt, cw, panel_top) end
    posters_apply((anim.playlist > 0) and (W - panel_width() * ease(anim.playlist) - 16 * S) or nil)
    ov.res_x, ov.res_y = W, H
    ov.data = table.concat(out, "\n")
    ov:update()
end

local last_render, last_animating = 0, true
local function tick()
    local now = mp.get_time()
    local dt = math.min(0.1, now - last_tick)
    last_tick = now
    local d = mp.get_property_native("osd-dimensions")
    if not d or d.w == 0 then return end
    W, H = d.w, d.h
    S = opts.scale * (P["display-hidpi-scale"] or 1)
    local vis = want_visible(now)
    anim.ui = step(anim.ui, vis and 1 or 0, dt, vis and opts.fade_in or opts.fade_out)
    anim.playlist = step(anim.playlist, playlist_open and 1 or 0, dt, 200)
    anim.menu = step(anim.menu, menu and 1 or 0, dt, 120)
    if menu then menu_last = menu end
    -- when nothing is moving, redraw a few times a second instead of every frame (keeps the video smooth)
    local function settled(v) return v == 0 or v == 1 end
    local still = settled(anim.ui) and settled(anim.playlist) and settled(anim.menu) and settled(anim.seek)
        and settled(anim.vol) and (now - flash.t) >= 0.6 and not dragging and not last_animating
    if still and not dirty and now - last_render < 0.25 then return end
    dirty = false
    last_render = now
    render(now, dt)
    last_animating = animating
    local busy = anim.ui > 0 or anim.playlist > 0 or anim.menu > 0 or (now - flash.t) < 0.6 or dragging or animating
    if not busy then
        hits = {}
        timer:kill()
    end
end
timer = mp.add_periodic_timer(1 / 60, tick)
timer:kill()

-- ---------------------------------------------------------------- input
local function find_hit()
    for i = #hits, 1, -1 do
        local h = hits[i]
        if mouse.x >= h.x1 and mouse.x <= h.x2 and mouse.y >= h.y1 and mouse.y <= h.y2 then return h end
    end
end

local function on_down()
    local m = mp.get_property_native("mouse-pos")
    if m then mouse = m end
    last_move = mp.get_time()
    local hit = find_hit()
    last_down_video = false
    if lib.search.focus and not (hit and hit.group == "search") then lib.search_focus(false) end
    if menu and not (hit and (hit.group == "menu" or hit.keeps_menu)) then
        menu = nil
        request()
        return
    end
    if hit then
        if hit.down then hit.down() end
        request()
        return
    end
    last_down_video = true
    if opts.click_to_pause and not P["idle-active"] then toggle_pause() end
    request()
end

local function on_up()
    if dragging == "section" and sec_drag then
        local d = sec_drag
        sec_drag = nil
        dragging = nil
        if d.active then
            local keys = {}
            for _, k in ipairs(lib.sec_keys or {}) do if k ~= d.key then keys[#keys + 1] = k end end
            table.insert(keys, clamp(lib.drop_idx or (#keys + 1), 1, #keys + 1), d.key)
            set_section_order(keys)
            lib.scroll = d.saved_scroll or 0
        else
            collapsed[d.key] = (not collapsed[d.key]) or nil
            save_lib_state()
        end
        request()
        return
    end
    if dragging == "seek" then seek_from_mouse(true) end
    dragging = nil
    request()
end

mp.add_forced_key_binding("MBTN_LEFT", "glass-click", function(e)
    if e.event == "down" then on_down()
    elseif e.event == "up" then on_up() end
end, { complex = true })

mp.add_forced_key_binding("MBTN_LEFT_DBL", "glass-dblclick", function()
    if last_down_video and opts.double_click_fullscreen then mp.commandv("cycle", "fullscreen") end
end)

local function wheel(dir)
    local pw = (opts.playlist_width + 16) * S * ease(anim.playlist)
    if P["idle-active"] and not (playlist_open and mouse.x >= W - pw) then
        lib.target = clamp((lib.target or lib.scroll) - dir * 120 * S, 0, lib.max_scroll)
        lib.last_scroll_t = mp.get_time()
    elseif playlist_open and mouse.x >= W - pw then
        pl_scroll = (plv.target or pl_scroll) - dir * 46 * S * 2
        plv.target = pl_scroll
        plv.wheel = true
    else
        mp.commandv("add", "volume", tostring(dir * opts.wheel_volume_step))
        last_move = mp.get_time()
    end
    request()
end
mp.add_forced_key_binding("WHEEL_UP", "glass-wheel-up", function() wheel(1) end)
mp.add_forced_key_binding("WHEEL_DOWN", "glass-wheel-down", function() wheel(-1) end)

mp.add_key_binding("TAB", "toggle-playlist", toggle_playlist)
mp.add_key_binding("ctrl+f", "search", function()
    if P["idle-active"] then lib.search_focus(true); request() end
end)

mp.observe_property("mouse-pos", "native", function(_, m)
    if not m then return end
    if m.x ~= mouse.x or m.y ~= mouse.y then last_move = mp.get_time() end
    mouse = m
    if dragging == "seek" then seek_from_mouse(false)
    elseif dragging == "volume" then volume_from_mouse()
    elseif dragging == "libscroll" then lib.scroll_drag()
    elseif dragging == "section" and sec_drag and not sec_drag.active and math.abs(mouse.y - sec_drag.sy) > 6 * S then
        sec_drag.active = true
        sec_drag.saved_scroll = lib.scroll
        lib.scroll = 0
    end
    request()
end)

for _, name in ipairs({ "pause", "duration", "volume", "mute", "fullscreen", "playlist", "track-list",
    "media-title", "filename/no-ext", "video-params", "file-size", "playlist-pos", "idle-active", "display-hidpi-scale", "osd-dimensions", "loop-playlist", "sid", "chapter-list" }) do
    mp.observe_property(name, "native", function(_, v)
        if name == "idle-active" and v and not P[name] then lib.cache = {}; plex_reload() end
        if name == "idle-active" and not v then lib.search_focus(false) end

        P[name] = v
        request()
    end)
end
