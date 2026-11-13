-- Mock test: the co-op text chat (sdc_chat, 0.7.3 / 0.9.0) with the real sdc_log,
-- sdc_config, sdc_i18n, sdc_widgets and sdc_net's encoding, a stub engine
-- and several "machines" (a host and clients, each with its own copy of
-- sdc_chat) whose messages travel through sdc_net.encode / decode.
--   1. settings, texts, wiring (config RU, i18n RU/EN/group/main, sdc_net
--      SECRET / NOW, main.lua: Esc bind only, no Enter bind)
--   2. text: escaping through the wire, cleaning, UTF-8 cut, hash, names
--   3. single player / host alone: nothing runs, nothing is built
--   4. handshake: CHATON only for players let in; old mods get nothing
--   5. open: UI-only input with flush, focus, typing stays in the line
--      (the game gets no key), auto-run and the car stop, Esc and its
--      delayed give-back
--   6. Enter from the line's text: the whole text, the opening key's
--      repeat, an empty line, a paste, the key let go before reopening
--   7. relay: names / ids from the host, spoofing, look-alike names,
--      players not let in, broken text
--   8. rates (own, per guest)
--   9. delivery: the host's copy, "not delivered", a late copy
--  10. feed: 5 lines / 10 history, fade, missed lines, height cap, HUD
--      hidden, per-character wrap, clipping, font, colours
--  11. forced closes: cursor, alone, console, death (live), death screen,
--      game window, Alt, the panel, lost focus, the widget off screen
--  12. client: an old host (hint), waiting, chat off, a car it does not
--      drive, the sound
--  13. logs: ASCII only, never a text or a name
--  14. world reset
--  15. look and layout (2026-11-13 screenshots: a long message wrapped
--      every 2-3 letters): the game's notification style, fixed wrap
--      widths from the nick, the feed below the game's infection plate
--  16. review findings 2026-11-13: a fix mid-line + Enter (no extra space),
--      long nicks keep " 2", no eaten Enter (WasInputKeyJustPressed and its
--      fallback), a held Esc's pause menu closed again, and checks that
--      the earlier mutation run let through
--  17. second review 2026-11-13: the input line's hint fits one line (RU /
--      EN), an Esc held past 1.5 s (the pause menu flickering), a draft sent
--      by a quick double Enter, and what the second mutation run let through
--      (overlapping diff, line height, a late copy's nick width)
-- usage: lua mock_chat.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path

local fails, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local real_print = print
print = function() end
local function say(s) io.write(s, "\n") end

FName = function(s) return s end
FText = function(s) return s end
RegisterHook = function() return 1, 2 end
RegisterConsoleCommandHandler = function() end

local CLK = 1000.0
os.clock = function() return CLK end
local function advance(s) CLK = CLK + s end

-- ------------------------------------------------------------ fake engine
local ME = nil            -- the machine whose game thread runs now
local machines = {}
local CALLS = {}          -- every recorded method call: { o, name, args }
local function rec(o, name, ...) CALLS[#CALLS + 1] = { o = o, name = name, args = table.pack(...), m = ME and ME.name } end
local function calls(name, o, mname)
    local out = {}
    for _, c in ipairs(CALLS) do
        if c.name == name and (o == nil or c.o == o) and (mname == nil or c.m == mname) then out[#out + 1] = c end
    end
    return out
end
local function mark() return #CALLS end
local function calls_since(n, name, mname)
    local out = {}
    for i = n + 1, #CALLS do
        local c = CALLS[i]
        if c.name == name and (mname == nil or c.m == mname) then out[#out + 1] = c end
    end
    return out
end

local Obj = { methods = {} }
local MT = {
    __index = function(_, k)
        local m = Obj.methods[k]
        if m then return m end
        return function(self, ...) rec(self, k, ...) end
    end,
}
local next_addr = 0
local function new_obj(class, name, props)
    next_addr = next_addr + 1
    local o = props or {}
    o._class, o._name, o._addr = class, name or (class .. "_" .. next_addr), next_addr
    return setmetatable(o, MT)
end
local M_ = Obj.methods
function M_.SetVisibility(self, v) rec(self, "SetVisibility", v); self._vis = v end
function M_.GetVisibility(self) return rawget(self, "_vis") end
function M_.SetText(self, t) rec(self, "SetText", t); self._text = t end
function M_.GetText(self) return rawget(self, "_text") or "" end
function M_.SetHintText(self, t) rec(self, "SetHintText", t); self._hint = t end
function M_.SetKeyboardFocus(self)
    rec(self, "SetKeyboardFocus")
    if not ME.block_focus then ME.focus = self end
end
function M_.HasKeyboardFocus(self)
    if ME.focus_error then error("HasKeyboardFocus: no Slate widget") end
    return ME.focus == self
end
function M_.AddToViewport(self, z) rec(self, "AddToViewport", z); self._in_vp, self._z = true, z end
function M_.IsInViewport(self) return rawget(self, "_in_vp") == true end
function M_.RemoveFromParent(self) rec(self, "RemoveFromParent"); self._in_vp = false end
function M_.SetRenderOpacity(self, a) self._opacity = a end
function M_.SetWrapTextAt(self, px) rec(self, "SetWrapTextAt", px); self._wrap = px end
function M_.SetBrushFromTexture(self, tex) rec(self, "SetBrushFromTexture", tex); self.Background.ResourceObject = tex end
function M_.SetRenderTransformAngle(self, a) self._angle = a end
function M_.SetWidthOverride(self, w) self._width = w end
function M_.SetMaxDesiredWidth(self, w) self._max_w = w end
function M_.SetMaxDesiredHeight(self, h) self._max_h = h end
function M_.SetPadding(self, m) self._pad = m end
function M_.SetVerticalAlignment(self, v) self._valign = v end
function M_.SetHorizontalAlignment(self, v) self._halign = v end
function M_.SetSize(self, v) self._size = v end
function M_.SetPosition(self, v) self._pos = v end
function M_.SetAnchors(self, v) self._anchors = v end
function M_.SetAlignment(self, v) self._align = v end
function M_.SetFont(self, f) rec(self, "SetFont", f); self._font = f end
function M_.SetColorAndOpacity(self, c) self._color = c end
function M_.SetBrushColor(self, c) self._brush = c end
function M_.SetNavigationRuleBase(self, d, r) local n = rawget(self, "_nav") or {}; rawset(self, "_nav", n); n[d] = r end
function M_.SetClipping(self, c) self._clip = c end
function M_.SetShadowOffset(self, v) self._shadow = v end
local function add_child(self, w)
    local ch = rawget(self, "_children") or {}
    rawset(self, "_children", ch)
    ch[#ch + 1] = w
    w._parent = self
    local slot = new_obj("Slot", "slot_of_" .. tostring(w._name))
    w._slot = slot
    return slot
end
M_.AddChildToCanvas, M_.AddChildToVerticalBox, M_.AddChildToHorizontalBox = add_child, add_child, add_child
function M_.SetContent(self, w) self._content = w; w._parent = self; return new_obj("Slot") end
function M_.GetPlayerId(self) return rawget(self, "_pid") end

-- the game's own key handling while a line has the keyboard or not: keys
-- typed go to the focused line in UI-only input, else to the game
local function type_keys(s)
    for _, cp in utf8.codes(s) do
        local ch = utf8.char(cp)
        if ME.mode == "ui" then
            if ME.focus and type(ME.focus) == "table" and ME.focus._class == "MultiLineEditableText" then
                ME.focus._text = (ME.focus._text or "") .. ch
            end
        else
            ME.game_actions[#ME.game_actions + 1] = ch
        end
    end
end

local WBL = new_obj("WidgetBlueprintLibrary", "Default__WidgetBlueprintLibrary")
function WBL.SetInputMode_UIOnlyEx(self, pc, w, lock, flush)
    rec(self, "SetInputMode_UIOnlyEx", pc, w, lock, flush)
    ME.mode = "ui"
    if flush then ME.flushed = (ME.flushed or 0) + 1 end
    if w and not ME.block_focus then ME.focus = w end
end
function WBL.SetInputMode_GameOnly(self, pc, flag)
    rec(self, "SetInputMode_GameOnly", pc, flag)
    ME.mode = "game"
    ME.focus = "viewport"
end
function WBL.SetInputMode_GameAndUIEx(self, pc, w)
    rec(self, "SetInputMode_GameAndUIEx", pc, w)
    ME.mode = "gameui"
end
function WBL.SetFocusToGameViewport(self) rec(self, "SetFocusToGameViewport"); ME.focus = "viewport" end
local GPS = new_obj("GameplayStatics", "Default__GameplayStatics")
local GI = new_obj("SD_GameInstance_C", "GameInstance_0")
local FONT = new_obj("Font", "Montserrat-Bold_Font")
local FADE = new_obj("Texture2D", "fade-right")
local CLICK = new_obj("SoundCue", "UI_click_sound_Cue")
local CLASSES = {}
local BUILT = {}

StaticConstructObject = function(cls, outer)
    local short = cls._short
    local o = new_obj(short, short .. "_" .. (next_addr + 1))
    o._outer = outer
    o._machine = ME and ME.name
    if short == "TextBlock" then o.Font = {} end
    if short == "MultiLineEditableText" then o.WidgetStyle = { Font = {} }; o._text = "" end
    if short == "Border" then o.Background = { OutlineSettings = { CornerRadii = {} } } end
    BUILT[#BUILT + 1] = o
    return o
end

local function valid(o) return type(o) == "table" and not rawget(o, "_invalid") end
local ue = {
    ROLE_AUTHORITY = 3,
    valid = valid,
    prop = function(o, k) if valid(o) then return rawget(o, k) end return nil end,
    set_prop = function(o, k, v) if valid(o) then rawset(o, k, v) return true end return false end,
    try = function(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end return nil end,
    str = function(v) if v == nil then return "" end return tostring(v) end,
    name = function(o) return valid(o) and o._name or "<none>" end,
    short = function(o) return valid(o) and o._name or "<none>" end,
    class_name = function(o) return valid(o) and o._class or "" end,
    local_pc = function() return ME and ME.pc end,
    pawn_of = function(pc)
        local p = valid(pc) and rawget(pc, "Pawn") or nil
        if valid(p) then return p end
        return nil
    end,
    widget_lib = function() return WBL end,
    gameplay_statics = function() return GPS end,
    game_instance = function() return GI end,
    find_object = function(path)
        local short = path:match("^/Script/UMG%.(.+)$")
        if short then
            CLASSES[short] = CLASSES[short] or new_obj("Class", short, { _short = short })
            return CLASSES[short]
        end
        if path:find("Montserrat-Bold_Font", 1, true) then
            if ME and ME.no_font then return nil end
            return FONT
        end
        if path == "/Game/UI/Textures/fade-right.fade-right" then
            if ME and ME.no_fade then return nil end
            return FADE
        end
        if path:find("UI_click_sound_Cue", 1, true) then return CLICK end
        return nil
    end,
    find_all = function(cls) return (ME and ME.all[cls]) or {} end,
    in_main_menu = function() return ME and ME.menu == true end,
    net_role = function() return ME and ME.S.role or "standalone" end,
    every = function() end, delay = function() end,
}
ue.local_pawn = function() return ue.pawn_of(ue.local_pc()) end
package.loaded["sdc_ue"] = ue

-- ------------------------------------------------------------ real modules
local log = require("sdc_log")
local LOG = {}
local function cap(level)
    return function(fmt, ...)
        local ok, s = pcall(string.format, fmt, ...)
        LOG[#LOG + 1] = level .. " " .. (ok and s or tostring(fmt))
    end
end
log.info, log.warn, log.err, log.debug = cap("I"), cap("W"), cap("E"), cap("D")
log.err_throttled = function(_, fmt, ...) cap("E")(fmt, ...) end
local function logged(pat)
    for _, l in ipairs(LOG) do if l:find(pat, 1, true) then return l end end
    return nil
end
local cfg = require("sdc_config")
cfg.save = function() return true end
local real_get = cfg.get
cfg.get = function(k)
    if ME and ME.cfg[k] ~= nil then return ME.cfg[k] end
    return real_get(k)
end
cfg.player_name = function() return ME and ME.nick or "Player" end
local i18n = require("sdc_i18n")
local W = require("sdc_widgets")
local real_net = require("sdc_net")

-- sdc_net's own lists, before sdc_chat adds to them
local SECRET0 = { CHAT = real_net.SECRET.CHAT, CHATM = real_net.SECRET.CHATM, JPW = real_net.SECRET.JPW }
local NOW0 = { CHAT = real_net.NOW.CHAT, CHATM = real_net.NOW.CHATM, CHATON = real_net.NOW.CHATON }

-- the wire: messages are encoded / decoded as sdc_net does
local wire = {}
local handlers = {}
local net_stub = {
    SECRET = real_net.SECRET, NOW = real_net.NOW, encode = real_net.encode, decode = real_net.decode,
    on = function(kind, fn)
        handlers[ME.name] = handlers[ME.name] or {}
        handlers[ME.name][kind] = fn
    end,
    send_to = function(pc, kind, ...)
        wire[#wire + 1] = { from = ME.name, to = pc._machine, kind = kind, raw = real_net.encode(kind, ...) }
        return true
    end,
    send_to_host = function(kind, ...)
        wire[#wire + 1] = { from = ME.name, to = ME.host, kind = kind, raw = real_net.encode(kind, ...), via = ME.remote_pc }
        return true
    end,
}
package.loaded["sdc_net"] = net_stub

-- player marker colours (sdc_playermarks.color_of)
local PAL = { [256] = { R = 0.1, G = 0.75, B = 1.0 }, [257] = { R = 1.0, G = 0.5, B = 0.05 } }
package.loaded["sdc_playermarks"] = {
    color_of = function(id)
        local c = PAL[id] or { R = 0.6, G = 0.45, B = 1.0 }
        return { R = c.R, G = c.G, B = c.B }
    end,
}

local function use(m)
    ME = m
    package.loaded["sdc_chat"] = m and m.chat or nil
    package.loaded["sdc_ui"] = m and m.ui or nil
    package.loaded["sdc_uiinput"] = m and m.uiinput or nil
end

local function machine(name, role, pid, nick)
    local m = { name = name, keys = {}, all = {}, cfg = {}, game_actions = {}, focus = "viewport", mode = "game",
                nick = nick, no_handler = {} }
    m.ps = new_obj("PlayerState", name .. "_PS", { _pid = pid })
    m.hud = new_obj("BP_Ingame_C", name .. "_HUD", { _vis = 4 })
    m.pawn = new_obj("BP_PlayerCharacter_C", name .. "_Pawn", { ["PlayerDead?"] = false, ["AutoRun?"] = false,
                                                               InGameUI = m.hud })
    m.pc = new_obj("BP_PlayerController_C", name .. "_PC", { Pawn = m.pawn, PlayerState = m.ps,
                                                            bShowMouseCursor = false })
    m.pc.IsInputKeyDown = function(_, key)
        m.key_reads = (m.key_reads or 0) + 1
        if m.mode == "ui" then return false end   -- the viewport ignores input
        -- a key pressed while the game had no input: its PlayerInput state is
        -- up (the press was ignored / flushed) until an auto-repeat comes, a
        -- few frames after the game has its input back
        if m.down_in_ui[key.KeyName] and (m.game_frames or 0) < 3 then return false end
        return m.keys[key.KeyName] == true
    end
    -- the game's PlayerInput: a press it received this frame (the key went
    -- down while the game had the input); a held key's auto-repeat is no press
    m.prev_keys = {}
    m.pc.WasInputKeyJustPressed = function(_, key)
        if m.no_jp then error("WasInputKeyJustPressed: not callable") end
        m.jp_reads = (m.jp_reads or 0) + 1
        local k = key.KeyName
        return m.mode ~= "ui" and m.keys[k] == true and not m.prev_keys[k] and not m.down_in_ui[k]
    end
    m.down_in_ui = {}
    m.S = { role = role, remote = {}, remote_pcs = {} }
    m.ui = { open = false, join_cover_model = function() return { visible = m.cover == true } end }
    m.uiinput = { game_ui_open = function() return m.window end }
    m.console = new_obj("Console", name .. "_Console", { ConsoleState = "None" })
    m.all.Console = { m.console }
    machines[name] = m
    return m
end

local function install_chat(m)
    use(m)
    local chunk = assert(loadfile(dir .. "/sdc_chat.lua"))
    m.chat = chunk()
    package.loaded["sdc_chat"] = m.chat
    m.chat.install(m.S)
end

local function deliver()
    local i = 1
    while i <= #wire do
        local w = wire[i]
        if not w.done then
            w.done = true
            local target = machines[w.to]
            if target and not target.offline then
                local prev = ME
                use(target)
                local kind, fields = real_net.decode(w.raw)
                local h = handlers[target.name] and handlers[target.name][kind]
                if h then
                    local pc = w.via or target.pc
                    local ok, err = pcall(h, fields, pc)
                    if not ok then check(false, "handler " .. kind .. " on " .. target.name .. ": " .. tostring(err)) end
                else
                    target.no_handler[#target.no_handler + 1] = kind
                end
                use(prev)
            elseif target and target.offline then
                w.done = false
                w.held = true
            end
        end
        i = i + 1
    end
end
local function sent(kind, to, from)
    local out = {}
    for _, w in ipairs(wire) do
        if w.kind == kind and (to == nil or w.to == to) and (from == nil or w.from == from) then out[#out + 1] = w end
    end
    return out
end
local function fields_of(w) local _, f = real_net.decode(w.raw); return f end

-- one frame / one tick of a machine (as main.lua runs them)
local function frame(m)
    use(m)
    -- a key that went down since the last frame went down in the mode the
    -- input had then: with UI-only input the game never got that press
    for k, v in pairs(m.keys) do
        if v and not m.prev_keys[k] and m.mode == "ui" then m.down_in_ui[k] = true end
        if not v then m.down_in_ui[k] = nil end
    end
    if m.esc then
        m.esc = false
        m.chat.on_esc()
    end
    if m.chat.frame_wanted() then m.chat.frame_tick() end
    m.game_frames = m.mode == "ui" and 0 or (m.game_frames or 0) + 1
    m.prev_keys = {}
    for k, v in pairs(m.keys) do m.prev_keys[k] = v end
end
local function tick(m) use(m); m.chat.tick() end
local function step(m, s, n)
    for _ = 1, n or 1 do
        advance(s or 0.02)
        frame(m)
    end
end

local function ascii_only(s) return not s:find("[\128-\255]") end

-- ===================================================================
say("== 1. settings, texts, wiring")
local function row(k) return i18n.schema_row(k) end
check(row("chat") and row("chat")[2] == "bool" and row("chat")[3] == true, "chat: bool, on by default")
check(row("chat_sound") and row("chat_sound")[2] == "bool" and row("chat_sound")[3] == true, "chat_sound: bool, on")
check(row("chat_key") and row("chat_key")[2] == "string" and row("chat_key")[3] == "Enter", "chat_key: Enter (an Unreal key name)")
check(row("chat")[4]:find("Enter открывает строку", 1, true) and row("chat_key")[4]:find("Unreal", 1, true),
    "Russian descriptions in config.ini")
local bad = {}
for _, k in ipairs({ "chat", "chat_sound", "chat_key" }) do
    if type(i18n.DESC_EN[k]) ~= "string" or i18n.DESC_EN[k]:find("[\208\209]") then bad[#bad + 1] = k end
end
check(#bad == 0, "English descriptions " .. table.concat(bad, ","))
check(i18n.LABEL.chat and i18n.LABEL.chat[1] == "Чат (Enter)" and i18n.LABEL.chat[2] == "Chat (Enter)"
    and i18n.LABEL.chat_sound and i18n.LABEL.chat_sound[2] == "Chat message sound", "labels RU / EN")
check(i18n.group_of("chat") == "players" and i18n.group_of("chat_sound") == "players", "group players")
local main_at, hud_at = nil, nil
for i, k in ipairs(i18n.MAIN) do
    if k == "chat" then main_at = i end
    if k == "players_hud" then hud_at = i end
end
check(main_at and hud_at and main_at == hud_at + 1, "«Основное»: chat right after the players table")
bad = {}
for _, k in ipairs({ "chat_hint", "chat_slow", "chat_undelivered", "chat_old_host" }) do
    local ru, en = i18n.STR.ru[k], i18n.STR.en[k]
    if not (ru and en and ru:find("[\208\209]") and not en:find("[\208\209]")) then bad[#bad + 1] = k end
end
check(#bad == 0, "line / feed texts in RU and EN " .. table.concat(bad, ","))
check(SECRET0.CHAT and SECRET0.CHATM and SECRET0.JPW, "sdc_net.SECRET has CHAT / CHATM (never in the net log)")
check(NOW0.CHAT and NOW0.CHATM and NOW0.CHATON, "sdc_net NOW has CHATON / CHAT / CHATM (no wait behind a snapshot)")
local function src(name)
    local h = assert(io.open(dir .. "/" .. name, "r"))
    local s = h:read("a"); h:close()
    return s
end
local main_src = src("main.lua")
check(main_src:find('require("sdc_chat")', 1, true) and main_src:find('ue.every("chat", 250, chat.tick)', 1, true)
    and main_src:find("chat.frame_wanted()", 1, true) and main_src:find("world_reset_hooks.chat", 1, true),
    "main.lua: require, 250 ms tick, frame loop, world reset")
check(main_src:find("RegisterKeyBind, Key.ESCAPE", 1, true) and not main_src:find("Key.RETURN", 1, true)
    and main_src:find("chat_esc = false }", 1, true),
    "main.lua: Esc is the chat's only UE4SS bind (Enter comes from the line's text)")
check(src("sdc_ui.lua"):find('pcall(chat.close, "panel")', 1, true) ~= nil, "sdc_ui.set_open closes the chat line first")
check(src("sdc_playermarks.lua"):find("M.color_of = color_of", 1, true) ~= nil, "sdc_playermarks exports color_of")

-- ===================================================================
say("== 2. text")
local H = machine("host", "host", 256, "Хост")
install_chat(H)
local t = H.chat._t
check(real_net.SECRET.CHAT and real_net.NOW.CHATON, "install keeps them set")
local function wire_round(s)
    local raw = real_net.encode("CHAT", t.esc(s))
    local _, f = real_net.decode(raw)
    return t.unesc(f[1]), raw
end
local cases = { "a|b", "100%", "%7C literal", "Привет, ёжик | 100%", "smile 😀 ok", "||%%", "" }
bad = {}
for _, s in ipairs(cases) do
    local back, raw = wire_round(s)
    if back ~= s or select(2, raw:gsub("|", "")) ~= 2 then bad[#bad + 1] = s end
end
check(#bad == 0, "escaping survives sdc_net's encoding: | % %7C Cyrillic ё emoji, empty")
check(t.clean_text("a\1b\127c") == "a b c", "control characters -> spaces")
check(t.clean_text("line\r\nnext\tend") == "line next end", "\\r\\n\\t -> spaces")
check(t.clean_text("\u{202E}abc\u{2066}d") == "abcd", "direction overrides / isolates removed")
check(t.clean_text("a\u{200B}b\u{FEFF}c\u{00AD}d") == "abcd", "zero-width, BOM, soft hyphen removed")
check(t.clean_text("  a    b  ") == "a b", "spaces squeezed and trimmed")
local none, why = t.clean_text("   \t ")
check(none == nil and why == "empty", "only spaces: no message")
local zal = t.clean_text("e\u{301}\u{302}\u{303}\u{304}x")
check(zal == "e\u{301}\u{302}x", "at most 2 combining marks in a row")
local long = string.rep("ж", 250)
local c200 = t.clean_text(long)
check(utf8.len(c200) == 200 and #c200 == 400, "200 Cyrillic characters = 400 bytes, valid UTF-8")
local emo = t.clean_text(string.rep("😀", 210))
check(utf8.len(emo) == 200 and #emo == 800, "4-byte characters cut on a character boundary")
local broken = "ab\xD0" .. "cd\xFF"
local b1, bwhy = t.clean_text(broken, 200, true)
check(b1 == nil and bwhy == "bad utf8", "broken UTF-8 from the network: dropped")
check(t.clean_text(broken, 200, false) == "abcd", "broken bytes from the own line: left out")
bad = {}
for _, s in ipairs({ "  Привет  мир ", "x\u{200B}y z", long, "a|b%" }) do
    local once = t.clean_text(s)
    if t.clean_text(once) ~= once then bad[#bad + 1] = s end
end
check(#bad == 0, "cleaning is idempotent (the host cleans again, hashes match)")
check(t.hash("abc") == t.hash("abc") and #t.hash("abc") == 8 and t.hash("abc") ~= t.hash("abd"), "FNV-1a hash, 8 hex")
check(t.skeleton("Host") == t.skeleton("HOST") and t.skeleton("Host") == t.skeleton("Нost")
    and t.skeleton("Host") == t.skeleton("h0st"), "name skeleton: case, Cyrillic look-alikes, 0 / o")
check(t.skeleton("Вася") == t.skeleton("вася") and t.skeleton("Вася") ~= t.skeleton("Петя"), "Cyrillic case")
check(t.life_of(10) == 10 and t.life_of(200) <= 16 and t.life_of(200) > 10, "line time 10 s, longer for long texts, at most 16")

-- ===================================================================
say("== 3. single player / host alone")
H.S.role = "standalone"
local built0 = #BUILT
tick(H)
H.keys.Enter = true
step(H, 0.02, 3)
check(#BUILT == built0 and not H.chat.is_open() and not H.chat.frame_wanted(), "single player: nothing built, nothing polled")
H.keys.Enter = false
H.S.role = "host"
tick(H)
check(#BUILT == built0 and not H.chat.frame_wanted(), "host without guests: no feed, no line, no key read")
H.keys.Enter = true
step(H, 0.02, 2)
check(not H.chat.is_open() and (H.key_reads or 0) == 0, "host alone: Enter is not even read")
H.keys.Enter = false

-- ===================================================================
say("== 4. handshake and who is let in")
local function client(name, pid, nick, index, rec_fields)
    local m = machine(name, "client", pid, nick)
    m.host = "host"
    m.remote_pc = new_obj("BP_PlayerController_C", "Remote_" .. name, { PlayerState = new_obj("PlayerState", "RPS_" .. name, { _pid = pid }) })
    m.remote_pc._machine = name
    local r = { key = m.remote_pc._name, pc = m.remote_pc, index = index, name = nick, hello = true, access = "ok" }
    for k, v in pairs(rec_fields or {}) do r[k] = v end
    H.S.remote[r.key] = r
    m.rec = r
    m.S.client = { acked = true, access = nil, pc_key = name .. "_PC" }
    return m
end
local A = client("a", 257, "Аня", 1)
local B = client("b", 258, "Боря", 2, { access = "wait" })
local Cc = client("c", 259, "Вика", 3, { access = "pw" })
local D = client("d", 260, "Дима", 4, { kicked = true })
local E = client("e", 261, "Ева", 5)
local O = client("old", 262, "Олег", 6)   -- an older mod: no sdc_chat
install_chat(A); install_chat(B); install_chat(Cc); install_chat(D); install_chat(E)
O.chat = { frame_wanted = function() return false end, tick = function() end, on_esc = function() end, is_open = function() return false end }
B.S.client.access = "wait"
tick(A); tick(B); tick(Cc); tick(D); tick(E)
check(#sent("CHATON", "host", "a") == 1 and #sent("CHATON", "host", "b") == 0, "a client asks CHATON once acked; a waiting one does not")
E.rec.pc._invalid = true   -- e's controller is gone on the host (stays so)
deliver()
check(#sent("CHATON", "a", "host") == 1, "the host answers a player it let in")
check(#sent("CHATON", "c", "host") == 0 and #sent("CHATON", "d", "host") == 0, "no answer to a password-pending or kicked one")
tick(H)
check(#sent("CHATON", "e", "host") == 0, "no answer to a player whose controller is gone")
use(H)
local peers = t.peers()
check(peers[A.rec.key] and peers[A.rec.key].ok and peers[Cc.rec.key] and not peers[Cc.rec.key].ok,
    "host: a, c recorded; only a has the chat")
tick(A)
check(A.chat._t.cl().host_ok == true and A.chat._t.st.allowed == true, "client a: the host has the chat -> the line may open")
tick(Cc)
check(Cc.chat._t.st.allowed == false, "client c (no answer yet): no chat")
-- c is let in later: the host's tick answers its earlier ask
Cc.rec.access = "ok"
tick(H)
check(#sent("CHATON", "c", "host") == 1, "c let in: the host's tick sends the answer it held")
deliver(); tick(Cc)
check(Cc.chat._t.st.allowed == true, "client c: chat now")
tick(H)
check(H.chat._t.st.allowed == true and #BUILT > built0, "host with a chat peer: allowed, line and feed built")
local hui = H.chat._t.ui()
check(hui.w and hui.w._in_vp and hui.w._z == 880 and hui.root._vis == 1, "built on screen at z 880; empty feed collapsed")

-- ===================================================================
say("== 5. open: input mode, typing, stop, Esc")
local reads0 = H.jp_reads or 0
step(H, 0.02, 2)
check((H.jp_reads or 0) >= reads0 + 2, "host: the chat key read each frame while the line may open")
H.pawn["AutoRun?"] = true
local car_m = new_obj("ChaosWheeledVehicleMovementComponent", "VMC_host", { bRequiresControllerForInputs = false })
local car = new_obj("BP_Car_C", "Car_1", { VehicleMovementComponent = car_m })
H.pawn["InVehicle?"] = true
H.pawn.VehicleDrivingComponent = new_obj("VehicleDrivingComponent_C", "VDC_host", { Vehicle = car })
local m0 = mark()
H.keys.Enter = true
step(H)
local field = hui.field
local ui_calls = calls_since(m0, "SetInputMode_UIOnlyEx", "host")
check(H.chat.is_open() and #ui_calls == 1 and ui_calls[1].args[1] == H.pc and ui_calls[1].args[2] == field
    and ui_calls[1].args[3] == 0 and ui_calls[1].args[4] == true, "Enter: SetInputMode_UIOnlyEx(pc, line, 0, flush=true)")
check(H.mode == "ui" and H.focus == field and H.pc.bShowMouseCursor == false, "UI-only input, keyboard on the line, no cursor")
check(hui.input._vis == 0 and hui.root._vis == 4, "the line shows (Visible), the feed root too")
check(H.pawn["AutoRun?"] == false, "auto-run off")
check(#calls_since(m0, "SetThrottleInput") == 1 and calls_since(m0, "SetThrottleInput")[1].args[1] == 0
    and #calls_since(m0, "SetSteeringInput") == 1 and #calls_since(m0, "SetBrakeInput") == 1,
    "the car this machine drives: throttle, steering, brake 0")
local nav = field._nav or {}
check(nav[2] == 3 and nav[3] == 3 and nav[4] == 3 and nav[5] == 3 and nav[0] == 3 and nav[1] == 3,
    "navigation rule Stop on every direction (Tab / arrows keep the line)")
check(field.ClearKeyboardFocusOnCommit == false and field.RevertTextOnEscape == false and field.AllowContextMenu == false
    and field.SelectAllTextWhenFocused == false, "line options set before it is shown")
use(H)
check(W.game_window_open() == "the chat", "sdc_widgets.game_window_open: 'the chat' while the line holds the keyboard")
local gm0 = #calls("SetInputMode_GameOnly", nil, "host")
check(W.game_input(H.pc, "test: setup check") == false and #calls("SetInputMode_GameOnly", nil, "host") == gm0,
    "the mod's own 'back to game controls' does not take the line's keyboard")
local reads1, jreads1 = H.key_reads, H.jp_reads
type_keys("wasd 123 tab j m y f5")
step(H, 0.02, 3)
check(#H.game_actions == 0 and field._text == "wasd 123 tab j m y f5", "typing goes to the line; the game gets no key")
check(H.key_reads == reads1 and H.jp_reads == jreads1, "no key reads while the line is open")
check(H.chat.is_open() and #sent("CHATM", nil, "host") == 0, "no line break: nothing sent, still open")
H.keys.Enter = false
-- Esc: closes, text gone, the game's input back only 0.3 s later
H.esc = true
local m1 = mark()
step(H)
check(not H.chat.is_open() and field._text == "" and H.chat._t.st.draft == nil, "Esc: closed, the text dropped")
check(#calls_since(m1, "SetInputMode_GameOnly") == 0 and H.mode == "ui" and H.focus == "viewport",
    "Esc: the game's input not yet back (a held Esc must not reach its pause menu); the hidden line has no keyboard")
step(H, 0.1, 3)
check(#calls_since(m1, "SetInputMode_GameOnly") == 1 and H.mode == "game", "0.3 s later: game controls back")
type_keys("w")
check(#H.game_actions == 1, "afterwards keys reach the game again")
H.game_actions = {}
use(H)
check(W.game_window_open() == nil, "closed: game_window_open is free again")
H.pawn["InVehicle?"] = false

-- ===================================================================
say("== 6. Enter from the line's text")
-- Esc is not the chat key: Enter opens again at once
H.keys.Enter = true
step(H)
check(H.chat.is_open(), "after Esc: Enter opens at once")
-- the opening key held: its repeat types a line break within 0.6 s: removed
type_keys("\r\n")
step(H)
check(H.chat.is_open() and field._text == "", "a line break right after opening (the key repeating): removed")
H.keys.Enter = false
step(H)
advance(0.7)
-- letters typed right before Enter are in the text when the frame sees the
-- line break; that Enter goes down while the line has the keyboard
local w0 = #wire
H.keys.Enter = true
type_keys("давай сюда\r\n")
step(H)
local cm = sent("CHATM", "a", "host")
local last = cm[#cm]
check(#wire > w0 and last and t.unesc(fields_of(last)[3]) == "давай сюда", "Enter: the whole text, its last letter included")
check(not H.chat.is_open() and H.mode == "game" and #H.game_actions == 0, "sent: closed, game controls back, no letter reached the game")
check(fields_of(last)[1] == "256" and t.unesc(fields_of(last)[2]) == "Хост", "CHATM: the host's id and name")
local hist = H.chat._t.st.hist
check(#hist == 1 and hist[1].text == "давай сюда" and hist[1].own and hist[1].shown_at, "the host's own line shows at once")
-- the Enter that sent, still held: the game gets only its repeats, no press
step(H, 0.05, 30)
check(not H.chat.is_open(), "Enter held after sending (repeats): no reopen")
check((H.jp_reads or 0) > 0, "the chat key is read as a press the game got (WasInputKeyJustPressed)")
H.keys.Enter = false
step(H)
H.keys.Enter = true
step(H)
check(H.chat.is_open(), "let go, pressed again: opens")
H.keys.Enter = false
advance(0.7)
-- an empty line + Enter closes, nothing sent
local n_cm = #sent("CHATM")
type_keys("   \r\n")
step(H)
check(not H.chat.is_open() and #sent("CHATM") == n_cm, "Enter on an empty line: closed, nothing sent")
-- review 2026-11-13 (an Enter eaten): a quick second press right after an
-- Enter close opens at once (the older down-edge read waited 1.1 s)
step(H, 0.05)
H.keys.Enter = true
step(H)
check(H.chat.is_open(), "pressed again 0.05 s after an Enter close: opens at once")
H.keys.Enter = false
step(H)
advance(0.7)
-- a paste with a line break: sent at once, the break as a space
type_keys("line one\nline two")
step(H)
cm = sent("CHATM", "a", "host")
check(not H.chat.is_open() and t.unesc(fields_of(cm[#cm])[3]) == "line one line two", "a pasted line break sends; it becomes a space")
step(H, 0.6, 3)

-- ===================================================================
say("== 7. relay, names, spoofing, players not let in")
local function open_and_send(m, text)
    m.keys.Enter = false
    step(m, 1.2)
    m.keys.Enter = true
    step(m)
    m.keys.Enter = false
    local was_open = m.chat.is_open()
    advance(0.7)
    type_keys(text .. "\r\n")
    step(m)
    return was_open
end
check(open_and_send(A, "Привет, ёжик | 100%"), "client a: the line opened")
check(#A.chat._t.st.pending == 1 and #A.chat._t.st.hist == 0, "client: own line waits for the host's copy")
local a_chat = sent("CHAT", "host", "a")
check(#a_chat == 1 and select(2, a_chat[1].raw:gsub("|", "")) == 2, "CHAT|<text>: the | escaped, two separators only")
local before = #wire
deliver()
local to = {}
for i = before + 1, #wire do
    local w = wire[i]
    if w.kind == "CHATM" then to[w.to] = (to[w.to] or 0) + 1 end
end
check(to.a == 1 and to.c == 1 and not to.b and not to.d and not to.e and not to.old,
    "CHATM to every chat peer (author included), not to waiting / kicked / gone / old players")
local hm = H.chat._t.st.hist
check(hm[#hm].text == "Привет, ёжик | 100%" and hm[#hm].name == "Аня" and hm[#hm].id == 257, "the host shows it with a's name and id")
deliver()
local ah = A.chat._t.st.hist
local own_n = 0
for _, e in ipairs(ah) do if e.text == "Привет, ёжик | 100%" then own_n = own_n + 1 end end
check(#A.chat._t.st.pending == 0 and own_n == 1 and ah[#ah].own and ah[#ah].text == "Привет, ёжик | 100%",
    "client a: the host's copy settles its own line, one line")
local ch = Cc.chat._t.st.hist
check(ch[#ch].name == "Аня" and ch[#ch].text == "Привет, ёжик | 100%" and not ch[#ch].own, "client c: whole text, name from the host")
check(#O.no_handler == 0 and #sent("CHATM", "old") == 0, "the older client never gets CHATM (nothing in its log either)")
-- spoofing: extra fields in CHAT are not a name
local function inject(from, raw, dt)
    advance(dt or 2.1)   -- the host's rate per player: 1 per 2 s after 5
    wire[#wire + 1] = { from = from.name, to = "host", kind = "CHAT", raw = raw, via = from.remote_pc }
    deliver()
end
local nh = #H.chat._t.st.hist
inject(A, "SDC1|CHAT|x|Хост|hi")
hm = H.chat._t.st.hist
check(#hm == nh + 1 and hm[#hm].text == "x" and hm[#hm].name == "Аня" and hm[#hm].id == 257,
    "CHAT|x|Хост|...: shown as a's text 'x' under a's name and id")
-- look-alike names
A.rec.name = "Хост"
inject(A, "SDC1|CHAT|one")
hm = H.chat._t.st.hist
check(hm[#hm].name == "Хост 2", "a guest named like the host gets ' 2'")
A.rec.name = "Xoст"   -- Latin X and o
inject(A, "SDC1|CHAT|two")
hm = H.chat._t.st.hist
check(hm[#hm].name == "Xoст 2", "look-alike Latin letters: ' 2' too")
A.rec.name = "Хо\u{200B}ст"
inject(A, "SDC1|CHAT|three")
hm = H.chat._t.st.hist
check(hm[#hm].name == "Хост 2", "an invisible character in the name: removed, ' 2'")
A.rec.name = "Вася"
Cc.rec.name = "вася"
inject(Cc, "SDC1|CHAT|four")
hm = H.chat._t.st.hist
check(hm[#hm].name == "вася 2", "two players with one name: the later one gets ' 2'")
inject(A, "SDC1|CHAT|five")
hm = H.chat._t.st.hist
check(hm[#hm].name == "Вася", "the earlier one keeps it")
A.rec.name = "Аня"
Cc.rec.name = "Вика"
-- players not let in
local drops0 = H.chat.stats.dropped
local relayed0 = H.chat.stats.relayed
inject(B, "SDC1|CHAT|from waiting")
inject(Cc, "SDC1|CHAT|ok")   -- c is in now
Cc.rec.access = "pw"
inject(Cc, "SDC1|CHAT|from pw")
Cc.rec.access = "ok"
inject(D, "SDC1|CHAT|from kicked")
inject(E, "SDC1|CHAT|from gone")
check(H.chat.stats.dropped == drops0 + 4, "waiting / password / kicked / gone controller: dropped (4)")
inject(A, "SDC1|CHAT|bad\xFF")
inject(A, "SDC1|CHAT|   ")
check(H.chat.stats.dropped == drops0 + 6, "broken UTF-8 and empty text: dropped")
check(logged("chat: dropped from id=") ~= nil, "drops logged (id and reason only)")

-- ===================================================================
say("== 8. rates")
advance(30)
local rate_drops = H.chat.stats.dropped
for i = 1, 6 do inject(A, "SDC1|CHAT|r" .. i, 0) end
check(H.chat.stats.dropped == rate_drops + 1, "host: 5 at once from one guest, the 6th dropped")
inject(A, "SDC1|CHAT|r7")
check(H.chat.stats.dropped == rate_drops + 1, "2 s later one more goes")
local b = {}
local ok4 = true
for _ = 1, 4 do ok4 = ok4 and t.take(b, 0, t.RATE.own) end
check(ok4 and not t.take(b, 0.5, t.RATE.own) and t.take(b, 2.5, t.RATE.own), "own: 4 at once, then 1 per 2 s")
-- in the line: "not so fast", the text stays, the line stays open
local per0 = t.RATE.own.per
t.RATE.own.per = 1000
advance(30)
t.st.own_rate = {}
for i = 1, 4 do open_and_send(H, "m" .. i) end
check(not H.chat.is_open(), "4 messages sent")
open_and_send(H, "fifth")
check(H.chat.is_open() and field._text == "fifth", "the 5th: line stays open with its text")
check(hui.side._text == i18n.T("chat_slow") and hui.side._vis == 3, "dim 'not so fast' at the right of the line")
step(H, 0.5, 4)
check(hui.side._vis == 1, "the note goes after 1.5 s")
t.RATE.own.per = per0
H.esc = true
step(H)
step(H, 0.2, 3)

-- ===================================================================
say("== 9. delivery of own lines")
deliver()
H.offline = true
open_and_send(A, "kein echo")
step(A)
advance(3.1)
tick(A)
ah = A.chat._t.st.hist
local fl = ah[#ah]
check(fl.text == "kein echo" and fl.failed and fl.own, "no copy from the host in 3 s: shown as not delivered")
check(logged("chat: not delivered len=9") ~= nil, "logged with length and hash")
step(A, 0.02)
local aui = A.chat._t.ui()
local shown_mark = false
for _, r in ipairs(aui.rows) do
    if r.mark._vis == 3 and r.mark._text == i18n.T("chat_undelivered") then shown_mark = true end
end
check(shown_mark, "the line shows 'not delivered' (signal colour)")
local n_ah = #ah
H.offline = false
deliver()
deliver()
ah = A.chat._t.st.hist
local ke = {}
for _, e in ipairs(ah) do if e.text == "kein echo" then ke[#ke + 1] = e end end
check(#ah == n_ah and #ke == 1 and not ke[1].failed and ke[1].name == "Аня", "a late copy fixes that line, no second one")

-- ===================================================================
say("== 10. the feed")
advance(60)
tick(H)
step(H)
-- 7 short lines within 2 s (two senders: each within its rate) on the host's feed
local hst = H.chat._t.st
local hist0 = #hst.hist
for i = 1, 7 do inject(i % 2 == 1 and A or Cc, "SDC1|CHAT|msg " .. i, 0.2) end
step(H)
local now_h = H.chat._t.visible(CLK, false)
check(#hst.hist == math.min(10, hist0 + 7) and now_h[#now_h].e.text == "msg 7", "history keeps every line (" .. #hst.hist .. ")")
check(#now_h == 5 and now_h[1].e.text == "msg 3", "closed: the newest 5 lines, the 6th pushed the oldest out")
local shown_h = 0
for _, r in ipairs(hui.rows) do if r.box._vis == 3 then shown_h = shown_h + 1 end end
check(shown_h == 5 and hui.root._vis == 4, "5 rows on screen")
tick(Cc)
step(Cc)
local cst = Cc.chat._t.st
local cui = Cc.chat._t.ui()
-- fade
local newest = cst.hist[#cst.hist]
advance(newest.shown_at + newest.life + 0.5 - CLK)
local fading = Cc.chat._t.visible(CLK, false)
check(#fading >= 1 and fading[#fading].alpha < 1 and fading[#fading].alpha > 0, "after its time a line fades")
step(Cc)
check(cst.fading, "fading: the frame loop renders each frame")
advance(1)
step(Cc)
check(#Cc.chat._t.visible(CLK, false) == 0 and cui.root._vis == 1, "gone after the fade; the empty feed is collapsed")
-- missed while the cursor was on (inventory): shown when back
Cc.pc.bShowMouseCursor = true
tick(Cc)
check(not cst.feed_on, "cursor on: the feed is hidden")
inject(A, "SDC1|CHAT|while in inventory")
deliver()
local miss = cst.hist[#cst.hist]
check(miss.unseen and not miss.shown_at, "a line that came meanwhile waits")
Cc.pc.bShowMouseCursor = false
tick(Cc)
check(cst.feed_on and miss.shown_at == CLK and not miss.unseen, "cursor off: the missed line shows with its full time")
-- older than 60 s: only in the history
Cc.pc.bShowMouseCursor = true
tick(Cc)
advance(2.1)
inject(A, "SDC1|CHAT|old news")
deliver()
local oldn = cst.hist[#cst.hist]
advance(61)
Cc.pc.bShowMouseCursor = false
tick(Cc)
check(not oldn.shown_at and not oldn.unseen, "a missed line older than 60 s does not pop up")
-- HUD hidden (Y): no feed; Enter still opens with the history
Cc.hud._vis = 2
tick(Cc)
check(not cst.feed_on, "HUD hidden: no feed")
Cc.keys.Enter = false
step(Cc, 1.2)
Cc.keys.Enter = true
step(Cc)
Cc.keys.Enter = false
local open_rows = Cc.chat._t.visible(CLK, true)
check(Cc.chat.is_open() and #open_rows >= 6 and cui.root._vis == 4, "HUD hidden: Enter opens, the history shows (" .. #open_rows .. " lines)")
local all_one = true
for _, r in ipairs(open_rows) do if r.alpha ~= 1 then all_one = false end end
local plates_ok, shown_n = true, 0
for _, r in ipairs(cui.rows) do
    if r.box._vis == 3 then
        shown_n = shown_n + 1
        if not (r.bg._brush and r.bg._brush.A == 0.6 and r.bg._brush.R == 0) then plates_ok = false end
    end
end
check(all_one and plates_ok and shown_n == #open_rows, "history: no fade, every row on its black 0.6 plate")
Cc.esc = true
step(Cc)
step(Cc, 0.2, 3)
tick(Cc)
check(cui.root._vis == 1, "closed again with the HUD hidden: no feed")
Cc.hud._vis = 4
tick(Cc)
-- height cap: long lines show fewer rows
advance(30)
for i = 1, 5 do inject(A, "SDC1|CHAT|" .. string.rep("слово ", 33) .. i); advance(2.1) end
deliver()
tick(Cc)
local cap_rows = Cc.chat._t.visible(CLK, false)
check(#cap_rows >= 1 and #cap_rows < 5, "long lines: fewer rows fit the feed's height (" .. #cap_rows .. ")")
local cap_h = 0
for _, r in ipairs(cap_rows) do cap_h = cap_h + Cc.chat._t.est_height(r.e) end
check(cap_h <= Cc.chat._t.feed_cap(false), "their estimated height fits the room below the infection plate (" .. cap_h .. ")")
-- wrapping, clipping, font, colours
local msg_tb = cui.rows[1].msg
check(msg_tb.WrappingPolicy == 1 and msg_tb.AutoWrapText == false and type(msg_tb.WrapTextAt) == "number",
    "message text: wraps at a fixed width (not at the width it got), a long word breaks between letters")
check(cui.rows[1].msg_box._clip == 1 and cui.rows[1].msg_box._max_h == Cc.chat._t.L.MSG_MAX_H,
    "a message taller than the feed's room is cut, not drawn over the HUD")
check(field.WrappingPolicy == 1 and field.AutoWrapText == true and cui.input_box._width == 460 - 28,
    "the line wraps too, inside its fixed width")
check(msg_tb._font and msg_tb._font.FontObject == FONT and msg_tb._font.TypefaceFontName == "Default" and msg_tb._font.Size == 12,
    "Montserrat Bold (Default), 12 - the game's notification text")
check(field.WidgetStyle.Font.FontObject == FONT and field.WidgetStyle.Font.Size == 12, "the line: the same font")
check(msg_tb._shadow and msg_tb._shadow.X == 1 and msg_tb._shadow.Y == 1, "text shadow 1x1")
local ae = nil
for _, e in ipairs(cst.hist) do if e.id == 257 then ae = e end end
check(ae and math.abs(ae.color.R - 1.0) < 1e-6 and math.abs(ae.color.G - 0.625) < 1e-6 and math.abs(ae.color.B - 0.2875) < 1e-6,
    "nick: a's marker colour (orange), a quarter toward white")

-- ===================================================================
say("== 11. closes forced by something else; the input given back or left")
local function open(m)
    m.keys.Enter = false
    step(m, 1.2)
    m.keys.Enter = true
    step(m)
    m.keys.Enter = false
    return m.chat.is_open()
end
check(open(H), "host open")
type_keys("half a mess")
H.pc.bShowMouseCursor = true          -- the inventory opened over it
use(H)
check(not H.chat.holds_input() and W.game_window_open() == nil, "cursor on: the line no longer holds the input (F7 / inventory own it)")
local g0 = #calls("SetInputMode_GameOnly", nil, "host")
step(H)
check(not H.chat.is_open() and #calls("SetInputMode_GameOnly", nil, "host") == g0, "cursor on: closed in the same frame, input left alone")
check(H.chat._t.st.draft == "half a mess", "the typed text stays as a draft")
H.pc.bShowMouseCursor = false
H.mode = "game"
check(open(H) and field._text == "half a mess", "next open: the draft is back")
-- the panel (F7): sdc_ui.set_open closes the line first
g0 = #calls("SetInputMode_GameOnly", nil, "host")
use(H)
H.chat.close("panel")
check(not H.chat.is_open() and #calls("SetInputMode_GameOnly", nil, "host") == g0 and H.focus == "viewport",
    "F7: closed, input left to the panel, the hidden line lets the keyboard go")
H.mode = "game"
-- everyone left while the host types: the line closes and the game gets its input back
check(open(H), "open again")
local saved = {}
for k, r in pairs(H.S.remote) do saved[k] = r end
H.S.remote = {}
tick(H)
check(not H.chat.is_open() and H.mode == "game", "the last guest left: closed, game controls back (not stuck in UI-only)")
H.S.remote = saved
-- they come back: new connections ask again
for _, m in ipairs({ A, Cc }) do
    m.S.client.pc_key = m.S.client.pc_key .. "+"
    tick(m)
end
deliver()
tick(H); tick(A); tick(Cc)
check(H.chat._t.st.allowed and A.chat._t.st.allowed, "back again: chat again")
-- console opened during typing: closed, game input after the console closes
check(open(H), "open again")
H.console.ConsoleState = "Open"
tick(H)
check(not H.chat.is_open() and H.mode == "ui", "console open: closed, the input waits for the console")
H.console.ConsoleState = "None"
tick(H)
check(H.mode == "game", "console closed: game controls back")
-- death in the 250 ms before the tick saw it: the press checks live
step(H, 1.2)
check(H.chat._t.st.allowed, "(the 250 ms flag still says the line may open)")
H.pawn["PlayerDead?"] = true
local u0 = #calls("SetInputMode_UIOnlyEx", nil, "host")
H.keys.Enter = true
step(H)
H.keys.Enter = false
check(not H.chat.is_open() and #calls("SetInputMode_UIOnlyEx", nil, "host") == u0, "dead (not yet in the tick): Enter takes nothing")
H.pawn["PlayerDead?"] = false
local rs = new_obj("RespawnScreen_C", "RespawnScreen_0", { _in_vp = true })
H.all.RespawnScreen_C = { rs }
step(H, 0.1)
H.keys.Enter = true
step(H)
H.keys.Enter = false
check(not H.chat.is_open(), "a death screen on screen: no line")
H.all.RespawnScreen_C = nil
H.window = "the map"
step(H, 0.1)
H.keys.Enter = true
step(H)
H.keys.Enter = false
check(not H.chat.is_open(), "a game window open: no line")
H.window = nil
H.keys.LeftAlt = true
step(H, 0.1)
H.keys.Enter = true
step(H)
H.keys.Enter, H.keys.LeftAlt = false, false
check(not H.chat.is_open(), "Alt+Enter (full screen): no line")
-- dies while typing: closed, input left to the death screen
check(open(H), "open again")
H.pawn["PlayerDead?"] = true
g0 = #calls("SetInputMode_GameOnly", nil, "host")
step(H)
check(not H.chat.is_open() and #calls("SetInputMode_GameOnly", nil, "host") == g0, "death while typing: closed, input left alone")
H.pawn["PlayerDead?"] = false
H.mode = "game"
-- a click elsewhere takes the focus: taken back after 0.25 s
check(open(H), "open again")
H.focus = "viewport"
local f0 = #calls("SetKeyboardFocus", field)
step(H, 0.02)
check(#calls("SetKeyboardFocus", field) == f0, "focus lost: not taken back the same frame")
step(H, 0.3)
check(H.focus == field and #calls("SetKeyboardFocus", field) == f0 + 1 and H.chat.is_open(), "0.25 s later: the line has the keyboard again")
check(logged("), refocus") ~= nil, "logged (no text)")
-- focus never comes back: closed after 3 s, game controls back
H.block_focus = true
H.focus = "viewport"
step(H, 0.3, 12)
check(not H.chat.is_open() and H.mode == "game", "no focus for 3 s: closed, game controls back")
H.block_focus = false
-- the game's RemoveAllWidgets (the line goes off screen while open)
check(open(H), "open again")
hui.w._in_vp = false
H.focus = "viewport"
step(H, 0.3)
check(not H.chat.is_open() and H.mode == "game", "the line taken off screen: closed, controls back")
tick(H)
check(hui.w._in_vp == true, "the 250 ms tick puts the widget back on screen")
-- Esc and then the cursor in the 0.3 s: no forced game input
check(open(H), "open again")
H.esc = true
step(H)
H.pc.bShowMouseCursor = true
g0 = #calls("SetInputMode_GameOnly", nil, "host")
step(H, 0.2, 3)
check(#calls("SetInputMode_GameOnly", nil, "host") == g0, "Esc, then a window with the cursor within 0.3 s: its input stays")
H.pc.bShowMouseCursor = false
H.mode = "game"

-- ===================================================================
say("== 12. client details")
-- an older host: never answers CHATON
local OH = machine("oldhost", "host", 300, "Old")
local Z = machine("z", "client", 301, "Зоя")
Z.host = "oldhost"
Z.remote_pc = new_obj("BP_PlayerController_C", "Remote_z")
Z.remote_pc._machine = "z"
Z.S.client = { acked = true, pc_key = "z_PC" }
install_chat(Z)
for _ = 1, 3 do tick(Z); deliver(); advance(5.1) end
check(#sent("CHATON", "oldhost", "z") >= 2 and #OH.no_handler >= 2, "asked; the older host has no handler")
tick(Z)
check(not Z.chat._t.st.allowed and Z.chat._t.st.hint_poll, "no chat; Enter will say why")
step(Z)
Z.keys.Enter = true
step(Z)
local zh = Z.chat._t.st.hist
check(#zh == 1 and zh[1].sys and zh[1].text == i18n.T("chat_old_host") and not Z.chat.is_open() and #sent("CHAT", "oldhost") == 0,
    "Enter: a dim hint line, no input line, nothing sent")
Z.keys.Enter = false
step(Z)
Z.keys.Enter = true
step(Z)
check(#Z.chat._t.st.hist == 1, "the hint at most every 10 s")
Z.keys.Enter = false
for _ = 1, 10 do tick(Z); advance(5.1) end
check(#sent("CHATON", "oldhost", "z") <= 6, "asks stop after 6")
-- a chat_key that is also a game key: one warning
H.cfg.chat_key = "T"
tick(H)
check(logged("chat: key 'T' is also a game key") ~= nil, "chat_key T: warned once (the game's action runs too)")
H.cfg.chat_key = nil
tick(H)
-- left the host: the role is single player again (its client state may linger)
A.S.role = "standalone"
tick(A)
check(not A.chat._t.st.allowed and not A.chat.frame_wanted(), "back in single player: the chat is off at once")
A.S.role = "client"
tick(A)
-- a waiting client: nothing
tick(B)
check(not B.chat._t.st.allowed and #sent("CHATON", "host", "b") == 0, "waiting for the host's answer: no chat, no ask")
-- chat off on a client: says so, the host leaves it out; CHATM ignored
A.cfg.chat = false
tick(A)
check(#sent("CHATON", "host", "a") >= 2 and fields_of(sent("CHATON", "host", "a")[#sent("CHATON", "host", "a")])[2] == "0",
    "a switched the chat off: CHATON|1|0")
deliver()
local before_a = #sent("CHATM", "a")
inject(Cc, "SDC1|CHAT|to all but a")
check(#sent("CHATM", "a") == before_a, "the host sends it nothing then")
local na = #A.chat._t.st.hist
wire[#wire + 1] = { from = "host", to = "a", kind = "CHATM", raw = "SDC1|CHATM|259|Вика|hi" }
deliver()
check(#A.chat._t.st.hist == na, "chat off: an incoming line is not shown")
A.cfg.chat = nil
tick(A); deliver()
-- a client in a car someone else drives: the car is not touched
local cm2 = new_obj("ChaosWheeledVehicleMovementComponent", "VMC_a", { bRequiresControllerForInputs = true })
A.pawn["InVehicle?"] = true
A.pawn.VehicleDrivingComponent = new_obj("VehicleDrivingComponent_C", "VDC_a",
    { Vehicle = new_obj("BP_Car_C", "Car_2", { VehicleMovementComponent = cm2 }) })
local th0 = #calls("SetThrottleInput", cm2)
check(open(A) and #calls("SetThrottleInput", cm2) == th0, "a car on the replicated inputs (someone else drives): untouched")
A.esc = true
step(A); step(A, 0.2, 3)
A.pawn["InVehicle?"] = false
-- sound: other players' lines, at most every 3 s, not own, switchable
local s0 = #calls("PlaySound2D", GPS, "c")
inject(A, "SDC1|CHAT|ding")
deliver()
local s1 = calls("PlaySound2D", GPS, "c")
check(#s1 == s0 + 1 and s1[#s1].args[2] == CLICK and s1[#s1].args[3] == 0.6 and s1[#s1].args[8] == true,
    "another player's line: the game's UI click, volume 0.6, a UI sound")
inject(A, "SDC1|CHAT|ding again", 1)
deliver()
check(#calls("PlaySound2D", GPS, "c") == s0 + 1, "not again within 3 s")
local sa = #calls("PlaySound2D", GPS, "a")
deliver()
check(#calls("PlaySound2D", GPS, "a") == sa, "own line: no sound")
advance(3.1)
Cc.cfg.chat_sound = false
inject(A, "SDC1|CHAT|quiet")
deliver()
check(#calls("PlaySound2D", GPS, "c") == s0 + 1, "chat_sound off: no sound")
Cc.cfg.chat_sound = nil

-- ===================================================================
say("== 13. logs")
local secrets = { "Привет", "ёжик", "давай", "сюда", "Хост", "Аня", "Вася", "вася", "Вика", "line one", "half a mess",
                  "kein echo", "wasd", "fifth", "ding", "Зоя", "слово" }
local leaked, non_ascii = {}, {}
for _, l in ipairs(LOG) do
    if not ascii_only(l) then non_ascii[#non_ascii + 1] = l end
    for _, s in ipairs(secrets) do
        if l:find(s, 1, true) then leaked[#leaked + 1] = s .. " in: " .. l end
    end
end
check(#non_ascii == 0, "every log line is ASCII " .. (non_ascii[1] or ""))
check(#leaked == 0, "no text or name in the log " .. (leaked[1] or ""))
check(logged("chat: sent len=10 hash=") ~= nil and logged("chat: from id=257 len=") ~= nil, "sent / from lines: length and hash")
check(logged("chat: on (key Enter, sound on)") ~= nil, "start line")

-- ===================================================================
say("== 14. world reset")
check(open(H), "open")
type_keys("draft")
use(H)
local rm0 = #calls("RemoveFromParent", hui.w)
H.chat.reset("loadmap")
check(not H.chat.is_open() and #H.chat._t.st.hist == 0 and H.chat._t.st.draft == nil and #calls("RemoveFromParent", hui.w) == rm0 + 1,
    "loadmap: closed, history and draft gone, widget off screen")
check(next(H.chat._t.peers()) == nil and H.chat._t.ui().w == nil, "handshakes and widget refs dropped")

;(function()
-- ===================================================================
-- a second world for 15 / 16: host h2, guests g1 (a long name), g2 (no fade
-- texture in memory), later g3, g4 (no WasInputKeyJustPressed)
local H2 = machine("h2", "host", 400, "Хозяин")
install_chat(H2)
local function guest(name, pid, nick, index)
    local m = machine(name, "client", pid, nick)
    m.host = "h2"
    m.remote_pc = new_obj("BP_PlayerController_C", "Remote_" .. name,
        { PlayerState = new_obj("PlayerState", "RPS_" .. name, { _pid = pid }) })
    m.remote_pc._machine = name
    local r = { key = m.remote_pc._name, pc = m.remote_pc, index = index, name = nick, hello = true, access = "ok" }
    H2.S.remote[r.key] = r
    m.rec = r
    m.S.client = { acked = true, pc_key = name .. "_PC" }
    install_chat(m)
    return m
end
local function join(list)
    for _, m in ipairs(list) do tick(m) end
    deliver()
    tick(H2)
    deliver()
    for _, m in ipairs(list) do tick(m) end
end
local function inject2(from, raw, dt)
    advance(dt or 2.1)
    wire[#wire + 1] = { from = from.name, to = "h2", kind = "CHAT", raw = raw, via = from.remote_pc }
    deliver()
end
local function open2(m)
    m.keys.Enter = false
    step(m, 1.2)
    m.keys.Enter = true
    step(m)
    m.keys.Enter = false
    step(m)
    return m.chat.is_open()
end
local function last_of(m) local h = m.chat._t.st.hist; return h[#h] end
local function last_chatm(to)
    local l = sent("CHATM", to, "h2")
    return l[#l] and fields_of(l[#l]) or {}
end
-- the game font's real advance widths (Montserrat-Bold.ufont, 1/1000 em):
-- the estimate must never be below them
local REAL = {
    [32]=283, [33]=289, [34]=437, [35]=720, [36]=638, [37]=877, [38]=728, [39]=230, [40]=357, [41]=358, [42]=434,
    [43]=599, [44]=262, [45]=386, [46]=262, [47]=392, [48]=679, [49]=392, [50]=590, [51]=592, [52]=689, [53]=595,
    [54]=637, [55]=620, [56]=660, [57]=637, [58]=262, [59]=262, [60]=599, [61]=599, [62]=599, [63]=589, [64]=1035,
    [65]=766, [66]=765, [67]=733, [68]=826, [69]=671, [70]=639, [71]=771, [72]=808, [73]=328, [74]=541, [75]=740,
    [76]=604, [77]=955, [78]=808, [79]=844, [80]=732, [81]=844, [82]=735, [83]=638, [84]=618, [85]=788, [86]=746,
    [87]=1163, [88]=714, [89]=676, [90]=671, [91]=368, [92]=392, [93]=368, [94]=600, [95]=500, [96]=600, [97]=617,
    [98]=690, [99]=591, [100]=692, [101]=631, [102]=387, [103]=700, [104]=691, [105]=301, [106]=307, [107]=660,
    [108]=301, [109]=1049, [110]=691, [111]=655, [112]=690, [113]=690, [114]=431, [115]=531, [116]=435, [117]=687,
    [118]=598, [119]=937, [120]=595, [121]=598, [122]=543, [123]=391, [124]=309, [125]=391, [126]=599,
    [1040]=799, [1041]=738, [1042]=745, [1043]=593, [1044]=831, [1045]=673, [1046]=1079, [1047]=656, [1048]=821,
    [1049]=821, [1050]=735, [1051]=799, [1052]=963, [1053]=817, [1054]=842, [1055]=812, [1056]=724, [1057]=726,
    [1058]=637, [1059]=724, [1060]=950, [1061]=722, [1062]=841, [1063]=749, [1064]=1098, [1065]=1130, [1066]=845,
    [1067]=1028, [1068]=721, [1069]=714, [1070]=1114, [1071]=734, [1072]=604, [1073]=673, [1074]=622, [1075]=514,
    [1076]=701, [1077]=643, [1078]=913, [1079]=563, [1080]=710, [1081]=710, [1082]=642, [1083]=666, [1084]=815,
    [1085]=694, [1086]=654, [1087]=685, [1088]=694, [1089]=592, [1090]=535, [1091]=614, [1092]=849, [1093]=592,
    [1094]=704, [1095]=634, [1096]=971, [1097]=971, [1098]=682, [1099]=859, [1100]=605, [1101]=590, [1102]=903,
    [1103]=628, [1025]=673, [1105]=643, [8230]=798, [8211]=500, [8212]=1000,
}
-- the font's line height: hhea ascender 968, descender -251 (1/1000 em), no line gap
local FONT_LINE_EM = (968 + 251) / 1000
local function real_w(s, size)
    local em = 0
    for _, cp in utf8.codes(s) do em = em + (REAL[cp] or 1000) / 1000 end
    return em * (size or 12) * 4 / 3
end

say("== 15. look and layout")
local G1 = guest("g1", 401, "LongNameForTest02", 1)
local G2 = guest("g2", 402, "Вторая", 2)
G2.no_fade = true
join({ G1, G2 })
local t2 = H2.chat._t
local L = t2.L
check(t2.st.allowed and G1.chat._t.st.allowed and G2.chat._t.st.allowed, "h2 world: host and guests have the chat")
local hu = t2.ui()
local rs = hu.root and hu.root._slot
check(rs and rs._pos and rs._pos.X == 10 and rs._pos.Y == -180 and rs._anchors.Minimum.X == 0 and rs._anchors.Minimum.Y == 1
    and rs._align.X == 0 and rs._align.Y == 1,
    "bottom left at Stats' left edge (x 10), the input line's bottom at y 900 of 1080 (above the battery chips)")
check(L.AVAIL_H == 320 and L.SCREEN_H + L.POS_Y - L.AVAIL_H == 580,
    "nothing of the chat above y 580: the game's infection plate (left middle) ends at 560")
check(L.LINE_H >= FONT_LINE_EM * 16 and L.LINE_H == math.ceil(FONT_LINE_EM * 16),
    "a line is counted " .. L.LINE_H .. " px: the game font's own line height at 16 px (19.5) rounded up, not less")
-- every row: the game's notification plate, mirrored
local rows_ok, fades_ok = true, true
for _, r in ipairs(hu.rows) do
    local br = r.bg.Background
    local cr = br.OutlineSettings.CornerRadii
    if not (br.DrawAs == 4 and br.OutlineSettings.RoundingType == 0 and cr.X == 10 and cr.Y == 0 and cr.Z == 0 and cr.W == 10
        and r.bg._brush.R == 0 and r.bg._brush.G == 0 and r.bg._brush.B == 0 and r.bg._brush.A == 0.6
        and r.bg._pad.Left == 5 and r.bg._pad.Top == 5 and r.bg._pad.Right == 10 and r.bg._pad.Bottom == 5
        and r.bg._slot._valign == 0) then rows_ok = false end
    local f = r.fade
    if not (f and f.Background.ResourceObject == FADE and f.Background.DrawAs == 3 and f._angle == 180
        and math.abs(f._brush.A - 0.6 / 0.91) < 1e-9 and f._brush.R == 1 and f._parent._width == 28
        and f._parent._slot._valign == 0) then fades_ok = false end
end
check(rows_ok, "row plate: black 0.6, RoundedBox radius 10 on the left, padding 5 (the game's) and 10 before the fade")
check(fades_ok, "its end: the game's own fade-right texture, turned 180 as the game turns its notifications, "
    .. "starting at the plate's alpha, 28 wide, the row's height")
local ib = hu.input_bg
check(ib._brush.A == 0.75 and ib._brush.R == 0 and hu.input_box._width == 432 and ib.Background.OutlineSettings.CornerRadii.X == 10
    and ib.Background.OutlineSettings.CornerRadii.Y == 0 and ib._pad.Left == 8 and ib._pad.Top == 5,
    "input line: black 0.75 (the game's infection plate), 432 wide + the fade")
local g2u = G2.chat._t.ui()
local cr2 = g2u.rows and g2u.rows[1].bg.Background.OutlineSettings.CornerRadii
check(cr2 and g2u.rows[1].fade == nil and cr2.X == 10 and cr2.Y == 10 and cr2.Z == 10 and cr2.W == 10 and g2u.input_box._width == 460,
    "fade texture not in memory: plates rounded all round, no fade, the line 460 wide")
check(logged("chat: the game's notification fade is not in memory") ~= nil, "... logged")
-- the estimate of a text's width is never below the game font's
local under = {}
for cp, adv in pairs(REAL) do
    local real = adv * 16 / 1000
    if t2.text_w(utf8.char(cp), 12) - 2 < real then under[#under + 1] = utf8.char(cp) end
end
check(#under == 0, "width estimate >= the real advance of every Latin / Cyrillic / digit / sign " .. table.concat(under, " "))
check(t2.text_w("\u{1F600}", 12) - 2 >= 16 and t2.text_w("\u{4E2D}", 12) - 2 >= 16,
    "a character the font has no width for (emoji, CJK: a fallback font): at least 1 em")
check(t2.text_w("ЩШЖЮ", 12) >= real_w("ЩШЖЮ") and t2.text_w("ЩШЖЮ", 12) < real_w("ЩШЖЮ") * 1.1
    and t2.text_w("ilt.", 12) < real_w("ilt.") * 1.6 and t2.text_w("— –", 12) < real_w("— –") * 1.1,
    "... and not far above it (dashes too: they are in the hint)")
-- a long message right after a short one from the same player
local long = "Длинные предложения больше не должны переноситься по две-три буквы в строке: текст идёт на всю ширину "
    .. "строки и переносится по словам, как в уведомлениях игры."
inject2(G1, "SDC1|CHAT|да")
inject2(G1, "SDC1|CHAT|" .. long)
step(H2)
local el = last_of(H2)
local lrow = hu.rows[#hu.rows]
local want = L.TEXT_W - el.nick_w - L.TEXT_GAP
check(el.nick == "LongNameForTest…" and el.text == long, "h2 shows g1's long message")
check(lrow.msg.WrapTextAt == want and lrow.msg._wrap == want and lrow.msg.AutoWrapText == false,
    "it wraps at the row's room less the nick (" .. want .. " of 411), whatever the row showed before")
check(el.nick_w >= real_w(el.nick)
    and L.PAD + L.NICK_PAD + el.nick_w + L.TEXT_GAP + want + L.END_PAD + L.FADE_W <= L.FEED_W,
    "nick (never estimated below its real width) and message fit the 460-wide row")
check(lrow.nick._text == "LongNameForTest…" and lrow.msg._text == long and lrow.box._vis == 3, "the row shows nick and text")
check(lrow.msg_slot._pad.Left == 10 and lrow.nick._slot._pad.Left == 6, "6 before the nick, 10 between nick and text")
check(t2.msg_wrap({ sys = true }) == L.TEXT_W, "a hint line (no nick): the row's whole room")
check(t2.msg_wrap({ nick_w = 60, failed = true }) == L.TEXT_W - 60 - 10 - t2.text_w(i18n.T("chat_undelivered"), 10) - 8,
    "'not delivered': its mark's room left out too")
check(t2.msg_wrap({ nick_w = 500 }) == 120, "an absurdly wide nick: the message still gets 120")
-- lines: never fewer than the real text needs
local lines = t2.lines_of(long, want)
check(lines >= math.ceil(real_w(long) / want) and lines <= math.ceil(real_w(long) / want) + 2,
    "line estimate: at least what the text needs (" .. lines .. ")")
check(t2.lines_of("ok", want) == 1, "a short text: one line")
check(t2.lines_of("WWWWW WWWWW WWWWW", 150) == 3, "words wrap whole: three 95-wide words at 150 take 3 lines")
check(t2.lines_of(string.rep("W", 20), 100) == 4, "a word wider than the line breaks between letters (380 at 100: 4)")
-- five long messages: the feed stays below y 580
for i = 1, 5 do inject2(i % 2 == 1 and G1 or G2, "SDC1|CHAT|" .. string.rep("широкий щит ", 16) .. i) end
step(H2)
local vis = t2.visible(CLK, false)
local tot = 0
for _, r in ipairs(vis) do tot = tot + t2.est_height(r.e) end
check(#vis >= 1 and #vis < 5 and tot <= t2.feed_cap(false), "five long messages: only those that fit (" .. #vis .. ")")
check(900 - t2.input_h(1) - L.GAP - tot >= 580, "the feed's top stays below y 580 (" .. (900 - t2.input_h(1) - L.GAP - tot) .. ")")
check(t2.est_height({ text = string.rep("Щ", 200), nick_w = 0, sys = true }) <= L.MSG_MAX_H + 2 * L.PAD + L.ROW_GAP,
    "a message taller than the room counts as cut (its box clips it)")
-- open with a long draft: the line grows upward, the feed above it shrinks
check(open2(H2), "h2 open")
local cap1 = t2.feed_cap(true)
type_keys(string.rep("слово ", 30))
step(H2)
check(t2.st.input_lines > 1 and t2.feed_cap(true) == L.AVAIL_H - L.GAP - t2.input_h(t2.st.input_lines)
    and t2.feed_cap(true) < cap1, "a long draft: the input line grows (" .. t2.st.input_lines .. " lines), the feed's room shrinks")
local vo, to2 = t2.visible(CLK, true), 0
for _, r in ipairs(vo) do to2 = to2 + t2.est_height(r.e, t2.msg_max_h(true)) end
check(#vo >= 1 and to2 <= t2.feed_cap(true), "open: the history above it still below y 580 (" .. to2 .. ")")
step(H2)
check(hu.rows[#hu.rows].msg_box._max_h == t2.msg_max_h(true) and t2.msg_max_h(true) < L.MSG_MAX_H,
    "a message taller than the smaller room is cut at it (" .. t2.msg_max_h(true) .. ")")
H2.esc = true
step(H2)
step(H2, 0.1, 4)
check(t2.st.input_lines == 1 and not H2.chat.is_open(), "closed: the line back to one line")
-- the hint line (sys) and a row that shows "not delivered" on a client
local g1u = G1.chat._t.ui()
check(g1u.rows and g1u.rows[1].fade and g1u.rows[1].fade.Background.ResourceObject == FADE, "g1: built with the game's fade")

say("== 16. review findings 2026-11-13")
-- 1. a fix in the middle of the line, Enter where the caret is: no extra space
local hf = hu.field
check(open2(H2), "h2 open")
advance(0.7)
hf._text = "превет"
step(H2)
hf._text = "привет"           -- the typo fixed, the caret left after "при"
step(H2)
hf._text = "при\r\nвет"       -- Enter there (Windows line break)
step(H2)
check(not H2.chat.is_open() and t2.unesc(last_chatm("g1")[3] or "") == "привет",
    "a typo fixed mid-line, Enter mid-line: 'привет' (not 'при вет')")
check(open2(H2), "open")
advance(0.7)
hf._text = "abc def"
step(H2)
hf._text = "abc d\nXef"       -- Enter and a letter typed after it in one frame
step(H2)
check(t2.unesc(last_chatm("g1")[3] or "") == "abc def", "Enter mid-line + a letter after it in the same frame: the text as it was")
check(open2(H2), "open")
advance(0.7)
hf._text = "ab"
step(H2)
hf._text = "aone\ntwob"       -- a paste with a line break in the middle
step(H2)
check(t2.unesc(last_chatm("g1")[3] or "") == "aone twob", "a pasted line break in the middle: a space")
local dp, di, ds = t2.diff("аб", "ав\n")
check(dp == "а" and di == "в\n" and ds == "", "diff: whole characters (a shared first byte of two letters stays out of the prefix)")
local sp, si, ss = t2.diff("xа", "x\n\u{470}")
check(sp == "x" and si == "\n\u{470}" and ss == "", "diff: whole characters at the end too (two letters sharing a last byte)")
check(t2.message_of("abc", "a\nbc") == "abc" and t2.message_of("abc", "\nabc") == "abc" and t2.message_of("ab", "ab\r\n") == "ab"
    and t2.message_of("", "one\r\ntwo") == "one two" and t2.message_of("ёж", "ё\nж") == "ёж",
    "message_of: typed Enter anywhere (Cyrillic too) / a paste")
-- 3. a quick short reply right after opening (within 0.6 s) is sent
check(open2(H2), "open")
type_keys("ок\r\n")
step(H2)
check(not H2.chat.is_open() and t2.unesc(last_chatm("g1")[3] or "") == "ок", "'ок' + Enter 0.04 s after opening: sent")
-- 2. long nicks keep " 2"
H2.nick = "LongNameForTest01"
local G3 = guest("g3", 403, "LongNameForTest03", 3)
join({ G3 })
use(H2)
check(t2.display_name(G1.rec) == "LongNameForTe… 2" and t2.display_name(G3.rec) == "LongNameForTe… 3",
    "names cut to 16 like the host's: ' 2' / ' 3' kept whole after the cut")
inject2(G1, "SDC1|CHAT|кто я")
check(t2.unesc(last_chatm("g2")[2] or "") == "LongNameForTe… 2" and last_of(G2).nick == "LongNameForTe… 2"
    and t2.skeleton(last_of(G2).nick) ~= t2.skeleton(t2.nick_shown("LongNameForTest01")),
    "on the wire and in another player's feed: 'LongNameForTe… 2', unlike the host's 'LongNameForTest…'")
G1.rec.name = "Bob"
G2.rec.name = "Bob 2"
H2.nick = "Bob"
check(t2.display_name(G1.rec) == "Bob 3" and t2.display_name(G2.rec) == "Bob 2",
    "a later player really named 'Bob 2' keeps it; the earlier look-alike 'Bob' gets ' 3', not a second 'Bob 2'")
G1.rec.name, G2.rec.name, H2.nick = "LongNameForTest02", "Вторая", "Хозяин"
-- 3. without WasInputKeyJustPressed: the key's down edge, the first press counts
local G4 = guest("g4", 404, "Четвёртый", 4)
G4.no_jp = true
join({ G4 })
step(G4)
check(logged("chat: WasInputKeyJustPressed failed") ~= nil and not G4.chat.is_open(), "g4: the call fails -> down-edge read (warned)")
G4.keys.Enter = true
step(G4)
check(G4.chat.is_open(), "g4: the first press after the switch opens")
G4.keys.Enter = false
step(G4)
advance(0.7)
G4.keys.Enter = true      -- the second press goes down while the line has the keyboard
type_keys("тест\r\n")
step(G4)
step(G4, 0.05, 10)
check(not G4.chat.is_open(), "g4: the Enter that sent, held: no reopen")
G4.keys.Enter = false
step(G4)
G4.keys.Enter = true
step(G4)
check(G4.chat.is_open(), "g4: let go and pressed: opens")
G4.keys.Enter = false
G4.esc = true
step(G4)
step(G4, 0.1, 4)
-- 4. Esc held after closing the line: the pause menu it opens is closed again
local function esc_close(m)
    check(open2(m), m.name .. " open")
    m.esc = true
    step(m)
    step(m, 0.1, 4)
    return m.mode == "game"
end
local function pause_opens(m, name)
    local pw = new_obj("PauseScreen_C", name, { _in_vp = true })
    m.all.PauseScreen_C = { pw }
    m.mode, m.pc.bShowMouseCursor = "ui", true
    return pw
end
local function pause_gone(m)
    m.all.PauseScreen_C = nil
    m.mode, m.pc.bShowMouseCursor = "game", false
    tick(m)
end
check(esc_close(H2), "Esc: closed, the game's input back after 0.3 s")
local pw = pause_opens(H2, "PauseScreen_1")
local m5 = mark()
tick(H2)     -- the 250 ms tick sees the cursor: the line may not open now (the guard still runs)
check(not t2.st.allowed and H2.chat.frame_wanted(), "pause menu up: the chat key is not read, the guard still runs")
step(H2, 0.02)
check(pw._in_vp, "the held Esc's pause menu: not at once (a new press may still come from UE4SS's key thread)")
step(H2, 0.02, 5)
local en = calls_since(m5, "EnableInput", "h2")
check(not pw._in_vp and H2.mode == "game" and H2.pc.bShowMouseCursor == false and #en == 1 and en[1].o == H2.pawn
    and en[1].args[1] == H2.pc and H2.chat.stats.unpaused == 1,
    "then closed the game's way: removed, game input, cursor off, the character's input on")
check(#calls_since(m5, "SetGamePaused", "h2") == 0 and logged("chat: the pause menu that the Esc held") ~= nil,
    "no SetGamePaused (co-op never pauses), logged")
step(H2, 0.1, 3)
check(t2.st.esc_guard ~= nil and H2.chat.frame_wanted(), "the guard stays on after closing it (the key may still be held)")
step(H2, 0.1, 8)
check(t2.st.esc_guard == nil, "guard over 1 s after the menu last came back")
pause_gone(H2)
-- a new Esc press after the close: the pause menu is wanted
check(esc_close(H2), "Esc again")
H2.esc = true
step(H2)
local pw2 = pause_opens(H2, "PauseScreen_2")
step(H2, 0.02, 10)
check(pw2._in_vp and H2.chat.stats.unpaused == 1, "a new Esc press after the close: its pause menu stays")
pause_gone(H2)
-- too late (the guard is 1.5 s): left alone
check(esc_close(H2), "Esc again")
step(H2, 1.2)
local pw3 = pause_opens(H2, "PauseScreen_3")
step(H2, 0.02, 10)
check(pw3._in_vp and H2.chat.stats.unpaused == 1, "a pause menu 1.6 s after the Esc: stays")
pause_gone(H2)
-- another window shows the cursor in the guard's time: left alone
check(esc_close(H2), "Esc again")
H2.mode, H2.pc.bShowMouseCursor = "ui", true    -- the inventory
local gm5 = #calls("SetInputMode_GameOnly", nil, "h2")
step(H2, 0.02, 10)
check(#calls("SetInputMode_GameOnly", nil, "h2") == gm5 and H2.pc.bShowMouseCursor == true and H2.chat.stats.unpaused == 1
    and t2.st.esc_guard == nil, "the inventory (cursor, no pause menu) in that time: left alone, the guard ends")
pause_gone(H2)
step(H2, 1.5)
-- 5. what the earlier mutation run let through
use(H2)
-- the host's chat peers: only the record that told CHATON (a reconnect under the same key is not it)
local old_rec = G1.rec
local new_rec = { key = old_rec.key, pc = new_obj("BP_PlayerController_C", "Remote_g1b", { PlayerState = old_rec.pc.PlayerState }),
                  index = 1, name = old_rec.name, hello = true, access = "ok" }
new_rec.pc._machine = "g1"
H2.S.remote[old_rec.key] = new_rec
local has_new = false
for _, r in ipairs(t2.chat_peers()) do if r == new_rec then has_new = true end end
check(not has_new, "a player reconnected under the same key: no CHATM until its new CHATON")
H2.S.remote[old_rec.key] = old_rec
-- a client waiting for its password check: no chat
G1.S.client.access = "wait"
tick(G1)
check(not G1.chat._t.st.allowed, "client waiting (password): no chat")
G1.S.client.access = nil
tick(G1)
check(G1.chat._t.st.allowed, "... chat again once let in")
-- focus that cannot be read: never a false "focus lost"
check(open2(H2), "open")
H2.focus_error = true
local fk = #calls("SetKeyboardFocus", hf)
step(H2, 0.3, 12)
check(H2.chat.is_open() and #calls("SetKeyboardFocus", hf) == fk, "focus unreadable for 3.6 s: still open, no refocus, no close")
H2.focus_error = false
H2.esc = true
step(H2)
step(H2, 0.1, 4)
-- chat off on a client: an incoming line is not shown (the history is full: the text is checked)
deliver()
G2.cfg.chat = false
wire[#wire + 1] = { from = "h2", to = "g2", kind = "CHATM", raw = real_net.encode("CHATM", "401", "x", "off-line-text") }
deliver()
local off_shown = false
for _, e in ipairs(G2.chat._t.st.hist) do if e.text == "off-line-text" then off_shown = true end end
check(not off_shown, "client chat off: an incoming line is not shown")
G2.cfg.chat = nil
-- chat off on the host: relayed, not shown there
H2.cfg.chat = false
tick(H2)
inject2(G1, "SDC1|CHAT|host-off-text")
check(last_of(H2).text ~= "host-off-text" and t2.unesc(last_chatm("g2")[3] or "") == "host-off-text",
    "host chat off: relayed to the others, not shown on the host")
H2.cfg.chat = nil
tick(H2)
-- own echo: no sound; another player's line: the click
advance(3.1)
local s_g1, s_g2 = #calls("PlaySound2D", GPS, "g1"), #calls("PlaySound2D", GPS, "g2")
check(open2(G1), "g1 open")
advance(0.7)
type_keys("echo-text\r\n")
step(G1)
deliver()
deliver()
check(last_of(G1).text == "echo-text" and last_of(G1).own and #calls("PlaySound2D", GPS, "g1") == s_g1
    and #calls("PlaySound2D", GPS, "g2") == s_g2 + 1, "own line back from the host: no sound (another player: the click)")
-- names on the wire at most 24, in the feed at most 16 characters
H2.nick = string.rep("N", 30)
check(open2(H2), "open")
advance(0.7)
type_keys("from a long name\r\n")
step(H2)
deliver()
local wire_name = t2.unesc(last_chatm("g2")[2] or "")
check(utf8.len(wire_name) == 24 and last_of(G2).nick == string.rep("N", 15) .. "…" and utf8.len(last_of(G2).nick) == 16,
    "a 30-character host name: 24 on the wire, 16 in the feed ('…')")
H2.nick = "Хозяин"
-- the join cover goes up between two ticks: Enter takes nothing
tick(H2)
H2.cover = true
H2.keys.Enter = false
step(H2, 1.2)
H2.keys.Enter = true
step(H2)
H2.keys.Enter = false
check(not H2.chat.is_open(), "join cover up (not yet in the tick): Enter takes nothing")
H2.cover = false
tick(H2)
-- more than 4 own lines waiting for the host: the oldest is 'not delivered'
local g1t = G1.chat._t
local burst0 = g1t.RATE.own.burst
g1t.RATE.own.burst = 10
g1t.st.own_rate = {}
H2.offline = true
G1.keys.Enter = false
step(G1, 1.2)
for i = 1, 5 do
    G1.keys.Enter = true
    step(G1)
    G1.keys.Enter = false
    type_keys("pend-" .. i .. "\r\n")
    step(G1)
end
check(#g1t.st.pending == 5, "five sent quickly, the host away: five wait")
tick(G1)
local fl1 = last_of(G1)
check(#g1t.st.pending == 4 and fl1.failed and fl1.text == "pend-1", "past 4 waiting: the oldest ('pend-1') is 'not delivered'")
g1t.RATE.own.burst = burst0
H2.offline = false
deliver()
deliver()
-- typing past 200 characters: cut, the counter at 0
check(open2(H2), "open")
type_keys(string.rep("я", 250))
step(H2)
check(utf8.len(hf._text) == 200 and hu.side._text == "0" and hu.side._vis == 3, "250 characters typed: 200 kept, '0' left")
H2.esc = true
step(H2)
step(H2, 0.1, 4)
-- a name from the network is cleaned like any text (invisible, control characters out; broken: '?')
wire[#wire + 1] = { from = "h2", to = "g2", kind = "CHATM",
                    raw = real_net.encode("CHATM", "405", t2.esc("Ev\u{200B}il\1"), "named") }
deliver()
check(last_of(G2).name == "Evil" and last_of(G2).text == "named", "a name with invisible / control characters: cleaned ('Evil')")
wire[#wire + 1] = { from = "h2", to = "g2", kind = "CHATM", raw = real_net.encode("CHATM", "406", "\xFF\xFE", "broken") }
deliver()
check(last_of(G2).name == "?" and last_of(G2).text == "broken", "a broken name: '?'")
-- drops logged at most every 10 s
local function count_log(pat)
    local n = 0
    for _, l in ipairs(LOG) do if l:find(pat, 1, true) then n = n + 1 end end
    return n
end
local d0 = count_log("chat: dropped from id=403")
G3.rec.access = "pw"
inject2(G3, "SDC1|CHAT|one", 11)
inject2(G3, "SDC1|CHAT|two", 1)
inject2(G3, "SDC1|CHAT|three", 1)
check(count_log("chat: dropped from id=403") == d0 + 1, "three drops within 10 s: one log line")
inject2(G3, "SDC1|CHAT|four", 10.5)
check(count_log("chat: dropped from id=403") == d0 + 2, "... the next after 10 s")
G3.rec.access = "ok"
say("== 17. second review 2026-11-13")
-- 1. the input line's hint: one line in either language (the Russian one was
-- 415 px in the game font, the line 414: "закрыть" went to a second line,
-- the plate grew, the feed's room was counted 20 px too big)
local field_px = hu.input_box._width - hu.input_bg._pad.Left - hu.input_bg._pad.Right
local hint_bad = {}
for _, lang in ipairs({ "ru", "en" }) do
    local h = i18n.STR[lang].chat_hint
    if not (real_w(h) + 1 <= field_px - 8 and t2.text_w(h, 12) <= L.FIELD_W and t2.lines_of(h, L.FIELD_W) == 1) then
        hint_bad[#hint_bad + 1] = lang .. " " .. string.format("%.1f", real_w(h))
    end
end
check(field_px == 414 and #hint_bad == 0,
    "the hint fits the input line (414 px) on one line, RU and EN, with room to spare " .. table.concat(hint_bad, ", "))
check(t2.field_lines("") == 1, "an empty line counts as the hint's one line")
local hint_ru, hint_en = i18n.STR.ru.chat_hint, i18n.STR.en.chat_hint
i18n.STR.ru.chat_hint = string.rep("подсказка ", 5)
i18n.STR.en.chat_hint = string.rep("hint text ", 6)
check(t2.field_lines("") == 2, "an empty line counts as many lines as its hint takes (a longer hint: 2)")
i18n.STR.ru.chat_hint, i18n.STR.en.chat_hint = hint_ru, hint_en
check(open2(H2), "h2 open, the line empty")
check(t2.st.input_lines == 1 and t2.feed_cap(true) == L.AVAIL_H - L.GAP - t2.input_h(1),
    "open with the hint: one line, the feed's room above it as counted")
H2.esc = true
step(H2)
step(H2, 0.1, 4)
-- 2. Esc held on past the guard's 1.5 s: the game's pause menu flickers (each
-- repeat opens it from the game / closes it from its own OnKeyDown)
local function pause_flicker(m, n, on_s, off_s, tag)
    for i = 1, n do
        local p = pause_opens(m, "PauseScreen_" .. tag .. i)
        step(m, on_s)
        if p._in_vp then      -- the next repeat: its OnKeyDown closes it
            m.all.PauseScreen_C = nil
            p._in_vp = false
            m.mode, m.pc.bShowMouseCursor = "game", false
        end
        step(m, off_s)
    end
end
check(esc_close(H2), "Esc: closed")
local un0 = H2.chat.stats.unpaused
pause_flicker(H2, 40, 0.033, 0.033, "F")      -- 0.4 + 2.6 s after the Esc
check(t2.st.esc_guard ~= nil and H2.chat.stats.unpaused == un0,
    "Esc held 3 s, the menu flickering: the guard still on, the flicker itself left alone")
local pwe = pause_opens(H2, "PauseScreen_End")
step(H2, 0.02, 6)
check(not pwe._in_vp and H2.mode == "game" and H2.pc.bShowMouseCursor == false and H2.chat.stats.unpaused == un0 + 1,
    "let go while the menu shows: it is closed again")
step(H2, 0.1, 11)
check(t2.st.esc_guard == nil, "... and the guard is over a second later")
pause_gone(H2)
check(esc_close(H2), "Esc again")
pause_flicker(H2, 30, 0.033, 0.033, "G")
step(H2, 0.1, 11)
check(t2.st.esc_guard == nil, "let go while the menu was closed: the guard ends a second after it last came")
local pwl = pause_opens(H2, "PauseScreen_Later")
step(H2, 0.02, 10)
check(pwl._in_vp and H2.chat.stats.unpaused == un0 + 1, "a pause menu after that stays")
pause_gone(H2)
-- a slow key repeat (2.5 a second): the menu stays 0.4 s each time, the guard
-- closes it each time, past 1.5 s
check(esc_close(H2), "Esc again")
local un1 = H2.chat.stats.unpaused
for i = 1, 6 do
    pause_opens(H2, "PauseScreen_S" .. i)
    step(H2, 0.02, 6)
    step(H2, 0.28)
end
check(H2.chat.stats.unpaused == un1 + 6 and H2.mode == "game" and H2.pc.bShowMouseCursor == false,
    "a slow repeat for 2.4 s: closed again each time (6)")
step(H2, 0.1, 11)
check(t2.st.esc_guard == nil, "... the guard over after")
pause_gone(H2)
-- the guard's own end: 20 s after the Esc whatever happens
check(esc_close(H2), "Esc again")
pause_flicker(H2, 200, 0.05, 0.05, "L")
check(t2.st.esc_guard == nil, "held 20 s: the guard gives up (bounded)")
pause_gone(H2)
-- 3. a draft sent by a quick double Enter (the second press was taken for
-- the opening key's repeat and eaten)
local function make_draft(m, text)
    check(open2(m), m.name .. " open")
    type_keys(text)
    step(m)
    m.pc.bShowMouseCursor = true      -- the inventory over it
    step(m)
    m.pc.bShowMouseCursor = false
    m.mode = "game"
    tick(m)
    return m.chat._t.st.draft == text
end
check(make_draft(H2, "черновик раз"), "a draft kept")
local n_cm2 = #sent("CHATM", "g1", "h2")
H2.keys.Enter = false
step(H2, 1.2)
H2.keys.Enter = true
step(H2)
check(H2.chat.is_open() and hf._text == "черновик раз", "Enter: the draft is back in the line")
H2.keys.Enter = false
step(H2, 0.05)
type_keys("\r\n")                   -- the second press, 0.1 s after the first
step(H2, 0.05)
check(not H2.chat.is_open() and #sent("CHATM", "g1", "h2") == n_cm2 + 1 and t2.unesc(last_chatm("g1")[3] or "") == "черновик раз",
    "a second Enter 0.1 s after opening (before any key repeat): the draft is sent")
check(make_draft(H2, "черновик два"), "another draft")
n_cm2 = #sent("CHATM", "g1", "h2")
H2.keys.Enter = false
step(H2, 1.2)
H2.keys.Enter = true
step(H2)
step(H2, 0.1, 4)                    -- the key held: its repeat, 0.5 s on
type_keys("\r\n")
step(H2)
check(H2.chat.is_open() and hf._text == "черновик два" and #sent("CHATM", "g1", "h2") == n_cm2,
    "the opening Enter held (its repeat 0.5 s on): the draft stays, nothing sent")
H2.keys.Enter = false
H2.esc = true
step(H2)
step(H2, 0.1, 4)
-- an empty line keeps the whole guard: a second Enter right after opening does not close it
check(open2(H2), "open, empty")
type_keys("\r\n")
step(H2, 0.05)
check(H2.chat.is_open() and hf._text == "", "empty line: a line break 0.07 s after opening is removed, the line stays")
H2.esc = true
step(H2)
step(H2, 0.1, 4)
-- 4. what the second mutation run let through
check(t2.message_of("да", "да\nа") == "да" and t2.message_of("aa", "aa\na") == "aa",
    "message_of: the text after a typed Enter that repeats its end ('да' + Enter + 'а') is not doubled")
-- a late copy from the host with another name: the nick's width follows it
local g3t = G3.chat._t
deliver()
tick(G3)
H2.offline = true
check(open2(G3), "g3 open")
advance(0.7)
type_keys("late-copy\r\n")
step(G3)
advance(3.1)
tick(G3)
local lc = last_of(G3)
check(lc.text == "late-copy" and lc.failed and lc.nick == "LongNameForTest…", "g3: no copy in 3 s, 'not delivered' under its own name")
local w_before = lc.nick_w
H2.offline = false
deliver()
deliver()
check(not lc.failed and lc.nick == "LongNameForTe… 2" and lc.nick_w == g3t.text_w(lc.nick, 12) and lc.nick_w ~= w_before,
    "the late copy: the host's name ('LongNameForTe… 2') and its width, for the wrap")
step(G3)
local g3row = nil
for _, r in ipairs(G3.chat._t.ui().rows or {}) do
    if r.msg._text == "late-copy" and r.box._vis == 3 then g3row = r end
end
check(g3row and g3row.nick._text == "LongNameForTe… 2" and g3row.msg._wrap == g3t.msg_wrap(lc) and g3row.mark._vis == 1,
    "its row: the new nick, the wrap from its width, the mark gone")

-- logs of 15 - 17: still ASCII, still no text or name
local leaked2 = {}
for _, l in ipairs(LOG) do
    if not ascii_only(l) then leaked2[#leaked2 + 1] = l end
    for _, sec in ipairs({ "LongNameForTest", "Хозяин", "привет", "pend-", "echo-text", "Evil", "Bob", "late-copy", "черновик" }) do
        if l:find(sec, 1, true) then leaked2[#leaked2 + 1] = sec .. " in: " .. l end
    end
end
check(#leaked2 == 0, "logs: ASCII, no text or name " .. (leaked2[1] or ""))

end)()

print = real_print
io.write(string.format("mock_chat: %d checks, %s\n", checks, fails == 0 and "ALL OK" or (fails .. " FAILED")))
os.exit(fails == 0 and 0 or 1)
