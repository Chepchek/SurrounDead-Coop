-- Mock test: the host's player list in the co-op panel (sdc_ui): Kick / Ban
-- unchanged, «Ещё ›» at the row's end and its strip under the row with
-- «Притянуть к себе» (sdc_players.pull_to_host).
--   1. the model: the strip's actions per player (pull only "in game"),
--      a long name next to the buttons cut only past 24 characters
--   2. the widgets: «Ещё» after Ban (a wider gap), shown only with something
--      in its strip (else hidden, keeping its space), the strip closed
--   3. open / close: a second click, another row's «Ещё», the panel closing,
--      an action; the strip follows its player when the rows move, and goes
--      when the player leaves or has nothing in it any more
--   4. polling: the strip's buttons only while it is open
--   5. the action: pull_to_host(key, the row's full name), the strip closes;
--      a second pull of the same player within 3 s of a pull really sent
--      does nothing, after a refusal it goes through; Kick / Ban never pull
--   6. one more action in EXTRA_ACTIONS: its own button in every strip
--   7. English; a client has no buttons
--   8. a press the rows moved under (a strip closed / opened above, another
--      player took the row) within 0.6 s is no click: Pull, then a quick
--      click on the next row's Kick / Ban / «Ещё» does nothing
--   9. the row's layout (0.10.x: «UI съедает ники»): line 1 = dot, name (the
--      Fill slot), state, ping; line 2 = Kick / Ban / «Ещё ›» right-aligned
--      (the host's view; the own row and a client's list one line); names
--      whole up to 24 characters, longer ones «…» with a tooltip, from 17 on
--      the tooltip anyway and the engine's own «…» when too wide; the dots
--      of "menu" / "lag"; a row above getting its buttons' line moves the
--      rows under it, a row's own buttons appearing (a hello; the only
--      client's line of buttons lands where the tabs were) - a quick click
--      there is no click
-- The engine stubs are mock_fix_a2_ui.lua's.
-- usage: lua mock_pull_ui.lua <scripts dir>
local dir = arg[1] or "."
package.path = dir .. "/?.lua;" .. package.path
table.insert(package.searchers, 1, function(name)
    if name == "sdc_steamlink" then return function() error("sdc_steamlink: not loaded in this test") end end
end)

local fails, nchecks = 0, 0
local function check(cond, what)
    nchecks = nchecks + 1
    if cond then io.write("  ok   ", what, "\n") else io.write("  FAIL ", what, "\n"); fails = fails + 1 end
end
local real_print = print
local LOGS = {}
print = function(s) LOGS[#LOGS + 1] = tostring(s) end

local CLK = 500.0
os.clock = function() return CLK end

-- ---------------------------------------------------------------------------
-- Engine stubs
-- ---------------------------------------------------------------------------
FName = function(s) return { name = s, ToString = function() return s end } end
FText = function(s) return s end
local function autostruct()
    return setmetatable({}, { __index = function(t, k)
        local s = autostruct(); rawset(t, k, s); return s
    end })
end
local widget_mt
local function make_widget(class)
    return setmetatable({ _class = class, _children = {}, _text = "", _checked = false }, widget_mt)
end
local STRUCT_PROPS = { Font = true, WidgetStyle = true, Background = true }
widget_mt = {
    __index = function(t, k)
        if STRUCT_PROPS[k] then local s = autostruct(); rawset(t, k, s); return s end
        if k == "IsValid" then return function() return true end end
        if k == "SetText" then return function(self, s) self._text = s end end
        if k == "GetText" then return function(self) return self._text end end
        if k == "SetToolTipText" then return function(self, s) self._tip = s end end
        if k == "SetVisibility" then return function(self, v) self._vis = v end end
        if k == "SetBrushColor" then return function(self, c) self._color = c end end
        if k == "SetRenderTransformAngle" then return function(self, a) self._angle = a end end
        if k == "SetPadding" then return function(self, m) self._pad = m end end
        if k == "SetHorizontalAlignment" then return function(self, a) self._halign = a end end
        if k == "SetSize" then return function(self, s) self._size = s end end
        if k == "SetWidthOverride" then return function(self, w) self._w = w end end
        if k == "SetJustification" then return function(self, j) self._justify = j end end
        if k == "SetIsChecked" then return function(self, v) self._checked = v end end
        if k == "IsChecked" then return function(self) return self._checked end end
        if k == "IsHovered" or k == "IsPressed" then return function() return false end end
        if k == "IsInViewport" then return function() return true end end
        if k:find("^AddChild") or k == "SetContent" then
            return function(self, c)
                self._children[#self._children + 1] = c
                local s = make_widget("Slot")
                s._child = c
                local slots = rawget(self, "_slots") or {}
                rawset(self, "_slots", slots)
                slots[#slots + 1] = s
                return s
            end
        end
        return function() return nil end
    end,
}
local classes = {}
StaticConstructObject = function(cls) return make_widget(cls and cls.name or "?") end
StaticFindObject = function() return nil end
FindFirstOf = function() return nil end
local culture_lib = { GetCurrentCulture = function() return "en" end, IsValid = function() return true end }
local ksl = { GetDefaultLanguage = function() return "ru-RU" end, IsValid = function() return true end }
local ue = {
    ROLE_AUTHORITY = 3,
    valid = function(o) return type(o) == "table" end,
    try = function(fn, ...) local okk, v = pcall(fn, ...); if okk then return v end end,
    str = function(v) if v == nil then return "" end return type(v) == "table" and (v.name or "") or tostring(v) end,
    fstring = function(v) return v == nil and "" or tostring(v) end,
    name = function(o) return o and "Obj" or "<none>" end,
    short = function() return "Obj" end,
    path = function() return "/Game/Fonts/Test.Test" end,
    class_name = function(o) return o and o._class or "" end,
    prop = function(o, k) return o and rawget(o, k) end,
    set_prop = function(o, k, v) if o then rawset(o, k, v) end return true end,
    find_object = function(path)
        local short = path:match("^/Script/UMG%.(.+)$")
        if short then classes[short] = classes[short] or { name = short, IsValid = function() return true end }; return classes[short] end
        if path:find("KismetInternationalizationLibrary", 1, true) then return culture_lib end
        return nil
    end,
    find_first = function() return nil end,
    find_all = function() return {} end,
    ksl = function() return ksl end,
    game_instance = function() return { IsValid = function() return true end } end,
    local_pc = function() return { IsValid = function() return true end } end,
    local_pawn = function() return {} end,
    pawn_of = function() return {} end,
    ping_ms = function() return 42 end,
    in_main_menu = function() return false end,
    map_name = function() return "PersistentLevel" end,
    widget_lib = function() return nil end,
    has_pending_connection = function() return false end,
    delay = function() end,
}
package.loaded["sdc_ue"] = ue

local ROSTER = {}
local session = {
    VERSION = "0.7.3",
    state = { role = "host", remote = {}, remote_pcs = { {} }, join = { attempts = 0 } },
    world_reset_hooks = {}, ui_hooks = {},
    join = function() end, disconnect = function() end, host_on_next_load = function() end,
    start_fresh_server = function() end, request_respawn = function() end,
    roster = function() return ROSTER end,
}
package.loaded["sdc_session"] = session
package.loaded["sdc_widgets"] = { child = function() return nil end, first_text = function() return nil end }
local kicks, pulls, pull_names = {}, {}, {}
local PULL_OK = true   -- false: sdc_players refuses (it says why itself)
package.loaded["sdc_admin"] = { banned_names = function() return {} end,
    kick = function(key, ban) kicks[#kicks + 1] = { key = key, ban = ban }; return true end }
package.loaded["sdc_players"] = { pull_to_host = function(key, name)
    pulls[#pulls + 1] = key
    pull_names[#pulls] = name
    if PULL_OK then return true end
    return false, "host_air"
end }

local log = require("sdc_log")
local errors = {}
local real_err = log.err
log.err = function(msg, ...) errors[#errors + 1] = string.format(tostring(msg), ...); real_err(msg, ...) end
local cfg = require("sdc_config")
local i18n = require("sdc_i18n")
local UI = require("sdc_ui")
UI.VERSION = "0.7.3"
cfg.set("language", "ru")

-- 6. one more action (before the build): only for Eve
local notes = {}
table.insert(UI.EXTRA_ACTIONS, { id = "note", key = "btn_more", tip = "more_tip",
    avail = function(e) return e.key == "k_eve" end, run = function(key) notes[#notes + 1] = key end })

local okb, errb = pcall(UI.build)
check(okb, "UI.build runs: " .. tostring(errb))
UI.set_open(true)

local function vis(w) return w ~= nil and w._vis ~= 1 end
local function players(list)
    ROSTER = { { name = "Me", state = "host", host = true, me = true } }
    session.state.remote = {}
    for _, e in ipairs(list) do
        ROSTER[#ROSTER + 1] = e
        session.state.remote[e.key] = { name = e.name }
    end
    UI.players_sig = nil
    UI.refresh_status()
end
local BOB = { name = "Bob", state = "game", ping = 42, key = "k_bob" }
local VASYA = { name = "Vasya-with-a-very-long-name", state = "loading", ping = 90, key = "k_vasya" }
local GLEB = { name = "Gleb", state = "connecting", key = "k_gleb" }
local DEAD = { name = "Dima", state = "dead", ping = 70, key = "k_dima" }
local EVE = { name = "Eve", state = "game", ping = 30, key = "k_eve" }
players({ BOB, VASYA, GLEB, DEAD, EVE })

-- ------------------------------------------------------------ 1. the model
local pm = UI.players_model()
check(#pm.rows[2].extra == 1 and pm.rows[2].extra[1] == "pull", "Bob (in game): Pull")
check(#pm.rows[3].extra == 0 and #pm.rows[5].extra == 0, "loading / dead: nothing in the strip")
check(#pm.rows[4].extra == 0 and pm.rows[4].acts == false, "connecting: no buttons at all")
check(#pm.rows[6].extra == 2 and pm.rows[6].extra[2] == "note", "Eve: Pull and the added action")
check(pm.rows[3].name == "Vasya-with-a-very-long-…" and utf8.len(pm.rows[3].name) == 24,
    "a long name with the buttons: cut only past 24 characters (the buttons are on their own line): " .. pm.rows[3].name)
check(not pm.rows[2].extra_open, "nothing open")

-- ------------------------------------------------------------ 2. the widgets
local row2 = UI.player_rows[2]
local acts_kids = row2.acts._children
check(#acts_kids == 3 and acts_kids[3] == row2.more, "Kick, Ban, then «Ещё» at the row's end")
local s3, s2 = rawget(row2.acts, "_slots")[3], rawget(row2.acts, "_slots")[2]
check(rawget(s3, "_pad") and s3._pad.Left == 10 and rawget(s2, "_pad") and s2._pad.Left == 4,
    "a wider gap before «Ещё» (10) than between Kick and Ban (4)")
local function texts_of(w, out)
    out = out or {}
    local t = rawget(w, "_text")
    if t and t ~= "" then out[#out + 1] = t end
    for _, c in ipairs(w._children or {}) do texts_of(c, out) end
    return out
end
local labels = table.concat(texts_of(row2.acts), "|")
check(labels:find("Кик|Бан|Ещё|›", 1, true) ~= nil, "labels: Кик | Бан | Ещё ›: " .. labels)
check(vis(row2.more) and UI.player_rows[3].more._vis == 2 and UI.off[UI.player_rows[3].more] == true,
    "«Ещё» only with something in the strip; loading: hidden, keeping its space")
check(UI.player_rows[5].more._vis == 2, "dead: «Ещё» hidden")
for i = 1, 8 do check(not vis(UI.player_rows[i].strip), "strip " .. i .. " closed") end
check(table.concat(texts_of(row2.strip), "|") == "Притянуть к себе|Ещё", "the strip: «Притянуть к себе» (+ the added action's button)")
check(row2.extra_btns.note._vis == 1 and vis(row2.extra_btns.pull), "Bob's strip: the added action hidden (not his)")
check(row2.more_rec.w._tip == "Другие действия с этим игроком" and row2.extra_btns.pull and true, "«Ещё» tooltip")

-- ------------------------------------------------------------ 4. polling
local function polled(label, i)
    UI.frame_tick()
    for _, b in ipairs(UI.active) do
        if b.label == label then
            for _, g in ipairs(b.gates) do
                if g == UI.player_rows[i].acts or g == UI.player_rows[i].strip then return b end
            end
        end
    end
    return nil
end
check(polled("more", 2) and polled("kick", 2) and polled("ban", 2), "Bob: Kick, Ban, «Ещё» polled")
check(not polled("more", 3), "Vasya's hidden «Ещё» not polled")
check(not polled("pull", 2), "the closed strip's buttons not polled")

-- ------------------------------------------------------------ 3. open / close
polled("more", 2).fn()   -- the rows got their buttons just now: no click (section 9)
check(UI.extra_open == nil, "«Ещё» clicked the moment the buttons appeared: nothing")
CLK = CLK + 1
polled("more", 2).fn()   -- a click on Bob's «Ещё»
check(UI.extra_open == "k_bob" and vis(row2.strip) and row2.more_arrow._angle == 90, "a click opens Bob's strip (arrow down)")
check(row2.more_rec.colors.base == row2.more._color, "«Ещё» looks pressed while open")
local strip_slot, strip_n, acts_n = nil, nil, nil
for n, sl in ipairs(rawget(row2.row, "_slots") or {}) do
    if sl._child == row2.strip then strip_slot, strip_n = sl, n end
    if sl._child == row2.acts then acts_n = n end
end
check(strip_slot and rawget(strip_slot, "_halign") == 3 and acts_n and strip_n == acts_n + 1,
    "the strip hangs under the row's buttons, right-aligned (under «Ещё»)")
local pb = polled("pull", 2)
check(pb ~= nil and not polled("note", 2), "the open strip: Pull polled (the hidden action not)")
check(UI.player_rows[6].strip._vis == 1, "Eve's strip stays closed")
UI.on_extra(2)
check(UI.extra_open == nil and not vis(row2.strip) and row2.more_arrow._angle == 0, "a second click closes it")
UI.on_extra(2)
UI.on_extra(6)
check(UI.extra_open == "k_eve" and not vis(row2.strip) and vis(UI.player_rows[6].strip), "another row's «Ещё»: only that strip open")
check(vis(UI.player_rows[6].extra_btns.note) and vis(UI.player_rows[6].extra_btns.pull), "Eve's strip: both actions")
UI.set_open(false)
check(UI.extra_open == nil and not vis(UI.player_rows[6].strip), "the panel closes: the strip too")
UI.set_open(true)
UI.on_extra(3)
check(UI.extra_open == nil, "Vasya (loading): «Ещё» does nothing")
UI.on_extra(4)
check(UI.extra_open == nil, "a connecting player's row: nothing")

-- ------------------------------------------------------------ 5. the action
UI.on_extra(2)
CLK = CLK + 1   -- the strip opened a while ago (a press right after it is no click: section 8)
polled("pull", 2).fn()
check(#pulls == 1 and pulls[1] == "k_bob", "Pull: sdc_players.pull_to_host(Bob's key)")
check(UI.extra_open == nil and not vis(row2.strip), "the strip closes after the action")
UI.on_extra(2)
UI.on_extra_action(2, "pull")
check(#pulls == 1, "a second pull of Bob within 3 s: nothing")
CLK = CLK + 3.5
UI.on_extra(2)
UI.on_extra_action(2, "pull")
check(#pulls == 2, "after 3 s: pulled again")
UI.on_extra_action(2, "pull")
check(#pulls == 2, "the strip is closed: a stale click does nothing")
CLK = CLK + 5
UI.on_extra(6)
UI.on_extra_action(6, "note")
check(#notes == 1 and notes[1] == "k_eve" and #pulls == 2, "the added action runs for its player")
UI.on_extra(2)
UI.on_extra_action(2, "note")
check(#notes == 1, "not Bob's action: nothing")
UI.on_kick(2)
UI.on_ban(6)
check(#kicks == 1 and kicks[1].key == "k_bob" and kicks[1].ban == false and #pulls == 2, "Kick / Ban unchanged, no pull")
UI.on_extra(2)
check(UI.extra_open == "k_bob", "Bob's strip open again")
package.loaded["sdc_admin"].is_kicked = function(k) return k == "k_bob" end
players({ BOB, VASYA, GLEB, DEAD, EVE })
check(row2.acts._vis == 2 and UI.extra_open == nil and not vis(row2.strip), "a kicked player: no buttons (space kept), its strip gone")
package.loaded["sdc_admin"].is_kicked = nil

-- the rows move under an open strip
players({ BOB, VASYA, EVE })
UI.on_extra(2)
check(UI.extra_open == "k_bob" and vis(UI.player_rows[2].strip), "Bob's strip open on row 2")
players({ VASYA, BOB, EVE })
check(vis(UI.player_rows[3].strip) and not vis(UI.player_rows[2].strip), "Bob moved to row 3: his strip with him")
CLK = CLK + 5
UI.on_extra_action(2, "pull")
check(#pulls == 2, "a click on row 2's old strip: not Vasya")
UI.on_extra_action(3, "pull")
check(#pulls == 3 and pulls[3] == "k_bob", "row 3's strip: Bob")
UI.on_extra(3)
players({ VASYA, { name = "Bob", state = "dead", ping = 42, key = "k_bob" }, EVE })
check(UI.extra_open == nil and not vis(UI.player_rows[3].strip) and UI.player_rows[3].more._vis == 2,
    "Bob died: nothing to do, the strip and «Ещё» go")
players({ BOB, EVE })
UI.on_extra(2)
players({ EVE })
check(UI.extra_open == nil, "Bob left: the strip goes")
check(not vis(UI.player_rows[3].strip), "no strip left on an unused row")

-- the test hook's direct pull (no strip needed)
players({ BOB, EVE })
CLK = CLK + 5
UI.on_pull(2)
check(#pulls == 4 and pulls[4] == "k_bob", "UI.on_pull (ui_test pull=<row>)")
UI.on_pull(1)
check(#pulls == 4, "the host's own row: nothing")

-- the row's full name goes with the key (said if the player has left meanwhile)
check(pull_names[4] == "Bob", "pull_to_host(key, the row's name): " .. tostring(pull_names[4]))
local LONG = { name = "Vasya-with-a-very-long-name", state = "game", ping = 60, key = "k_vlong" }
players({ LONG, EVE })
CLK = CLK + 5
UI.on_pull(2)
check(#pulls == 5 and pulls[5] == "k_vlong" and pull_names[5] == "Vasya-with-a-very-long-name",
    "a long name: the full one, not the row's cut one: " .. tostring(pull_names[5]))

-- a refusal (sdc_players said why: in the air, still joining...): the host may
-- try again at once; only a pull really sent blocks a second click for 3 s
players({ BOB, EVE })
CLK = CLK + 5
PULL_OK = false
local np0 = #pulls
UI.on_pull(2)
check(#pulls == np0 + 1, "a refused pull: asked")
CLK = CLK + 1
UI.on_pull(2)
check(#pulls == np0 + 2, "a retry 1 s after the refusal reaches pull_to_host again (not swallowed)")
PULL_OK = true
CLK = CLK + 0.5
UI.on_pull(2)
check(#pulls == np0 + 3, "0.5 s later, now sent")
CLK = CLK + 1
UI.on_pull(2)
check(#pulls == np0 + 3, "a click 1 s after a pull really sent: ignored")
CLK = CLK + 2.5
UI.on_pull(2)
check(#pulls == np0 + 4, "3.5 s after it: pulled again")

-- ------------------------------------------------------------ 8. a press the rows moved under
-- A click as the frame loop makes it: the polled record's handler, with
-- pressed_at = when the press began. A strip closing moves the rows under it
-- up by its height: the next row's Kick / Ban / «Ещё» slide under the cursor.
local function click(label, i, at)
    local b = polled(label, i)
    if not b then return false end
    b.pressed_at = at or CLK
    b.fn()
    b.pressed_at = nil
    return true
end
local function logged(from, s)
    for k = from, #LOGS do if LOGS[k]:find(s, 1, true) then return true end end
    return false
end
local ZED = { name = "Zed", state = "game", ping = 50, key = "k_zed" }
CLK = CLK + 10
UI.ban_confirm = nil   -- section 5's Ban question
players({ BOB, EVE, ZED })
local nk, np = #kicks, #pulls
UI.on_extra(2)
CLK = CLK + 1
check(click("pull", 2) and #pulls == np + 1 and pulls[#pulls] == "k_bob" and UI.extra_open == nil,
    "Pull on row 2 (Bob): pulled, the strip closed")
CLK = CLK + 0.3
local nlog = #LOGS + 1
check(click("kick", 3) and #kicks == nk, "row 3's Kick 0.3 s later (it moved up under the cursor): Eve not kicked")
check(logged(nlog, "'kick' on row 3 not done: the row moved"), "the log says why")
check(click("ban", 3) and UI.ban_confirm == nil and #kicks == nk, "row 3's Ban: not even «Точно?»")
check(click("more", 3) and UI.extra_open == nil, "row 3's «Ещё»: no strip")
check(click("kick", 4) and #kicks == nk, "row 4's Kick (moved up too): nothing")
CLK = CLK + 0.4
check(click("kick", 3) and #kicks == nk + 1 and kicks[#kicks].key == "k_eve" and kicks[#kicks].ban == false,
    "0.7 s after the move: row 3's Kick kicks Eve")
check(click("ban", 2) and UI.ban_confirm ~= nil and UI.ban_confirm.key == "k_bob",
    "row 2 (Bob's own row did not move): Ban asks «Точно?» at once")
UI.ban_confirm = nil

-- the 1 Hz refresh closes the strip by itself (Bob died) while the host aims at Pull
CLK = CLK + 10
players({ BOB, EVE, ZED })
nk = #kicks
UI.on_extra(2)
CLK = CLK + 1
players({ { name = "Bob", state = "dead", ping = 42, key = "k_bob" }, EVE, ZED })
check(UI.extra_open == nil, "Bob died: his strip closed by itself")
CLK = CLK + 0.2
check(click("kick", 3) and click("ban", 3) and #kicks == nk and UI.ban_confirm == nil,
    "Kick / Ban of row 3 0.2 s later: nothing")

-- a player leaves: the next one takes the row while a press on it is down
CLK = CLK + 10
players({ BOB, EVE, ZED })
nk = #kicks
local pressed = CLK
CLK = CLK + 0.1
players({ BOB, ZED })
check(click("kick", 3, pressed) and #kicks == nk,
    "a press on row 3's Kick begun while Eve was there, released after Zed took the row: Zed not kicked")
CLK = CLK + 0.7
check(click("kick", 3) and #kicks == nk + 1 and kicks[#kicks].key == "k_zed", "a new press after the row settled: Zed kicked")

-- «Ещё» of the row under an open strip: that strip closes, the row moves up
-- and its own strip opens where the cursor is
CLK = CLK + 10
players({ BOB, EVE, ZED })
np = #pulls
UI.on_extra(2)
CLK = CLK + 1
check(click("more", 3) and UI.extra_open == "k_eve", "row 3's «Ещё» with row 2's strip open: Eve's strip, Bob's closed")
CLK = CLK + 0.2
check(click("pull", 3) and #pulls == np and UI.extra_open == "k_eve", "a quick second click on Eve's new strip: no pull, the strip stays")
check(click("more", 3) and UI.extra_open == "k_eve", "a double-click on «Ещё»: the strip stays open")
check(click("kick", 2) and #kicks == nk + 2 and kicks[#kicks].key == "k_bob", "row 2 above it did not move: its Kick works at once")
CLK = CLK + 0.5
check(click("pull", 3) and #pulls == np + 1 and pulls[#pulls] == "k_eve", "Pull once the strip settled: Eve pulled")

-- the same Ban twice (nothing moved): bans as before; the ui_test hooks are
-- commands, not clicks
CLK = CLK + 10
players({ BOB, EVE, ZED })
nk = #kicks
click("ban", 4)
CLK = CLK + 0.2
click("ban", 4)
check(#kicks == nk + 1 and kicks[#kicks].key == "k_zed" and kicks[#kicks].ban == true, "two clicks on Zed's Ban: banned")
UI.on_extra(2)
UI.on_kick(3)
check(#kicks == nk + 2 and kicks[#kicks].key == "k_eve", "UI.on_kick (ui_test kick=<row>) right after a move: done")
UI.on_extra(2)

-- ------------------------------------------------------------ 9. the row's layout (the host's view)
-- A row: line 1 = the dot, the name (the Fill slot: all the room the state
-- and the ping leave), the state (Auto), the ping (a 58 box, right-aligned);
-- line 2 = Kick / Ban / «Ещё ›» right-aligned; the own row one line. A name
-- is cut only past 24 characters ("…", the tooltip says it whole). The
-- names are made up.
local function contains(w, x)
    if w == x then return true end
    for _, c in ipairs(rawget(w, "_children") or {}) do if contains(c, x) then return true end end
    return false
end
local function gap(i) local p = rawget(UI.player_rows[i].slot, "_pad"); return p and p.Bottom end
local function lines(i)
    local r = UI.player_rows[i]
    if not vis(r.row) then return 0 end
    return rawget(r.acts, "_vis") == 1 and 1 or 2   -- collapsed: one line; hidden (2): its place kept
end
CLK = CLK + 10
UI.ban_confirm, UI.extra_open = nil, nil
local OWN_LONG = "Christopher_The_Hosting_One"                                               -- 27
local LONG24 = { name = "Alexander_The_Long_Named", state = "game", ping = 16, key = "k_alex" }     -- 24
local LONG31 = { name = "Maximilian_Von_Extremely_Longer", state = "menu", ping = 40, key = "k_max" } -- 31
local LAGGY = { name = "Bartholomew_Lagging", state = "lag", ping = 900, key = "k_bart" }
local NEWBIE = { name = "Gleb", state = "connecting", key = "k_gleb" }
local CYR = { name = "Святослав_Длинноименный_Третий", state = "loading", ping = 120, key = "k_svyat" }  -- 30
players({ LONG24, LONG31, LAGGY, NEWBIE, CYR, DEAD })
ROSTER[1].name = OWN_LONG
UI.players_sig = nil
UI.refresh_status()
pm = UI.players_model()
local r2 = UI.player_rows[2]
check(r2.name._text == "Alexander_The_Long_Named" and rawget(r2.name, "_tip") == "Alexander_The_Long_Named",
    "a 24-letter name next to the buttons: whole (the tooltip too: in wide letters it may not fit): " .. tostring(r2.name._text))
local long_shown = UI.player_rows[3].name._text
check(utf8.len(long_shown) == 24 and long_shown == LONG31.name:sub(1, 23) .. "…"
    and UI.player_rows[3].name._tip == LONG31.name, "a 31-letter name: 23 letters + «…», the tooltip whole: " .. long_shown)
check(rawget(UI.player_rows[3].name, "_vis") == 0, "the name hit-testable (else its tooltip never shows)")
local cyr_shown = UI.player_rows[6].name._text
check(utf8.len(cyr_shown) == 24 and cyr_shown:sub(-3) == "…" and UI.player_rows[6].name._tip == CYR.name,
    "a long Cyrillic name: 24 characters with «…»: " .. cyr_shown)
check(UI.player_rows[1].name._text == OWN_LONG:sub(1, 21) .. "… (вы)", "the own name: 22 + « (вы)»: " .. UI.player_rows[1].name._text)
check(UI.player_rows[4].name._text == "Bartholomew_Lagging" and UI.player_rows[5].name._text == "Gleb", "short names whole")
check(UI.player_rows[4].name._tip == LAGGY.name and UI.player_rows[5].name._tip == "",
    "a 19-letter name: the tooltip whole (uncut, but it may be too wide), a short one: none")
local ends = true
for i = 1, 8 do ends = ends and rawget(UI.player_rows[i].name, "TextOverflowPolicy") == 1 end
check(ends, "every name: too wide for its room after all - the engine ends it with «…» (TextOverflowPolicy = Ellipsis)")
-- the widgets of a row
local kids = r2.row._children
check(kids[1] == r2.line1 and kids[2] == r2.acts and kids[3] == r2.strip, "a row: line 1, the buttons' line, the strip")
local l1 = r2.line1._children
check(#l1 == 4 and l1[2] == r2.name and l1[3] == r2.state and l1[4]._children[1] == r2.ping, "line 1: dot, name, state, ping")
local ls = rawget(r2.line1, "_slots")
local nsz = rawget(ls[2], "_size")
check(nsz and nsz.SizeRule == 1 and nsz.Value == 1, "the name: the Fill slot (the room the others leave)")
check(rawget(ls[1], "_size") == nil and rawget(ls[3], "_size") == nil and rawget(ls[4], "_size") == nil,
    "dot / state / ping: Auto slots")
check(rawget(l1[4], "_w") == 58 and rawget(r2.ping, "_justify") == 2, "the ping: a 58 box, right-aligned")
check(not contains(r2.line1, r2.acts) and not contains(r2.line1, r2.more) and contains(r2.acts, r2.more),
    "no button on the name's line")
check(rawget(rawget(r2.row, "_slots")[2], "_halign") == 3, "the buttons' line: right-aligned (under the ping)")
check(r2.state._text == "в игре" and r2.ping._text == "16 мс" and UI.player_rows[3].state._text == "в меню"
    and UI.player_rows[4].state._text == "не отвечает", "line 1: state and ping texts")
-- two lines for players, one for the own row; a row without buttons keeps their place
check(lines(1) == 1 and gap(1) == 1, "the own row: one line")
check(lines(2) == 2 and vis(r2.acts) and gap(2) == 6, "a player in game: two lines (buttons under the name), a wider gap after")
check(lines(3) == 2 and vis(UI.player_rows[3].acts) and lines(4) == 2 and vis(UI.player_rows[4].acts),
    "in the menu / not responding: two lines with Kick / Ban")
check(UI.player_rows[4].more._vis == 2 and vis(UI.player_rows[3].more), "not responding: «Ещё» hidden (nothing to pull), in the menu: shown")
check(UI.player_rows[5].acts._vis == 2 and lines(5) == 2 and gap(5) == 6, "connecting: the buttons' line hidden, its place kept")
check(lines(7) == 2 and lines(8) == 0, "dead: two lines; the unused row hidden")
check(pm.rows[1].two_lines == false and pm.rows[2].two_lines == true and pm.rows[5].two_lines == true, "the model says the lines")
-- the dots: menu yellow like connecting / loading, not responding orange, none grey
local grey = UI.player_rows[8].dot._color
local c = function(i) return UI.player_rows[i].dot._color end
check(c(3) == c(5) and c(3) == c(6) and c(3) ~= grey and c(3) ~= c(2), "in the menu: the yellow dot (as connecting / loading)")
check(c(4) ~= grey and c(4) ~= c(2) and c(4) ~= c(3) and c(4) ~= c(7), "not responding: its own colour (not grey, green, yellow, red)")
-- the guards on the new layout: Ban asks «Точно?», then bans
CLK = CLK + 10
nk = #kicks
check(click("ban", 2) and UI.player_rows[2].ban_text._text == "Точно?", "Ban: «Точно?» on the second line")
CLK = CLK + 0.3
check(click("ban", 2) and #kicks == nk + 1 and kicks[#kicks].key == "k_alex" and kicks[#kicks].ban == true, "a second click: banned")
-- a row above gets its line of buttons: the rows under it move down (stamped)
CLK = CLK + 10
local A_NEW = { name = "Arkady_Newcomer", state = "connecting", key = "k_ark" }
local B_NEW = { name = "Boris_Newcomer", state = "connecting", key = "k_bor" }
players({ A_NEW, B_NEW })
check(lines(2) == 1 and lines(3) == 1, "only players still connecting: one line each (no buttons anywhere)")
CLK = CLK + 5
local t_flip = CLK
players({ { name = "Arkady_Newcomer", state = "game", ping = 20, key = "k_ark" }, B_NEW })
check(lines(2) == 2 and lines(3) == 2 and UI.player_rows[3].changed_at == t_flip,
    "Arkady in: his buttons' line pushes Boris's row down (stamped as moved)")
CLK = CLK + 0.3
players({ { name = "Arkady_Newcomer", state = "game", ping = 20, key = "k_ark" }, { name = "Boris_Newcomer", state = "game", ping = 20, key = "k_bor" } })
nk = #kicks
check(click("kick", 3) and #kicks == nk, "a click on Boris's new Kick 0.3 s after his row moved: nothing")
CLK = CLK + 0.4
check(click("kick", 3) and #kicks == nk, "0.4 s after his own Kick appeared: still nothing")
CLK = CLK + 0.3
check(click("kick", 3) and #kicks == nk + 1 and kicks[#kicks].key == "k_bor", "0.7 s after his buttons appeared: kicked")
check(UI.player_rows[2].changed_at == t_flip, "Arkady's own buttons appeared under his name: stamped too")
-- the only client's hello: his line of buttons appears under his name where
-- the tabs were a moment ago (they move down): a press there right after it
-- was aimed at a tab - no Kick, no «Точно?» (a second click would ban)
CLK = CLK + 10
UI.ban_confirm = nil
local SOLO = { name = "Solomon_Single_Friend", state = "connecting", key = "k_solo" }
players({ SOLO })
check(lines(2) == 1 and lines(3) == 0, "the only client still connecting: one line, nothing under it")
CLK = CLK + 5
local t_hello = CLK
local SOLO_IN = { name = "Solomon_Single_Friend", state = "loading", ping = 30, key = "k_solo" }
players({ SOLO_IN })
check(lines(2) == 2 and UI.player_rows[2].changed_at == t_hello, "his hello: his line of buttons appears (stamped)")
CLK = CLK + 0.15
nk = #kicks
local nlog9 = #LOGS + 1
check(click("kick", 2) and #kicks == nk, "Kick 0.15 s after it appeared (the press was aimed at a tab): not kicked")
check(logged(nlog9, "'kick' on row 2 not done: the row moved"), "the log says why")
check(click("ban", 2) and UI.ban_confirm == nil and #kicks == nk, "Ban then: not even «Точно?»")
CLK = CLK + 0.55
check(click("kick", 2) and #kicks == nk + 1 and kicks[#kicks].key == "k_solo", "0.7 s after: kicked")
-- a player first seen past his hello: a new row at the list's end, buttons and all
CLK = CLK + 10
players({ SOLO_IN })
CLK = CLK + 10
local LATE = { name = "Leopold_Late_Arrival", state = "loading", ping = 70, key = "k_leo" }
players({ SOLO_IN, LATE })
CLK = CLK + 0.2
nk = #kicks
check(click("kick", 3) and click("ban", 3) and #kicks == nk and UI.ban_confirm == nil,
    "a new row with its buttons: Kick / Ban 0.2 s after it appeared do nothing")
check(click("kick", 2) and #kicks == nk + 1 and kicks[#kicks].key == "k_solo", "the row above it (nothing new there): Kick works at once")
CLK = CLK + 0.5
check(click("kick", 3) and #kicks == nk + 2 and kicks[#kicks].key == "k_leo", "0.7 s after: kicked")
-- nothing new on the rows (the same players, the 1 Hz refresh): no stamp
local before2, before3 = UI.player_rows[2].changed_at, UI.player_rows[3].changed_at
CLK = CLK + 1
players({ SOLO_IN, LATE })
check(UI.player_rows[2].changed_at == before2 and UI.player_rows[3].changed_at == before3, "the same rows again: not stamped")
-- the tooltip from 17 characters on (a name of 16 fits its room)
players({ { name = "Wilhelmina_Woods", state = "game", ping = 10, key = "k_w16" },
          { name = "Wilhelmina_Wright", state = "game", ping = 10, key = "k_w17" },
          { name = "Ярополк_Мудрейший", state = "game", ping = 10, key = "k_yar" } })   -- 17 letters, 33 bytes
check(UI.player_rows[2].name._text == "Wilhelmina_Woods" and UI.player_rows[2].name._tip == ""
    and UI.player_rows[3].name._tip == "Wilhelmina_Wright" and UI.player_rows[4].name._tip == "Ярополк_Мудрейший",
    "the tooltip: none for 16 characters, the whole name from 17 on (Cyrillic too)")
players({ { name = "Ярослав_Мудрый", state = "game", ping = 10, key = "k_yar" } })   -- 14 letters, 27 bytes
check(UI.player_rows[2].name._text == "Ярослав_Мудрый" and UI.player_rows[2].name._tip == "",
    "a short Cyrillic name (more bytes than letters): no tooltip (letters counted, not bytes)")
-- the row's own strip just opened under its buttons (nothing above moved):
-- a quick second click is no click
CLK = CLK + 10
players({ LONG24, EVE })
CLK = CLK + 1
np = #pulls
check(click("more", 2) and UI.extra_open == "k_alex", "«Ещё»: Alexander's strip opens under his buttons")
CLK = CLK + 0.2
check(click("more", 2) and UI.extra_open == "k_alex", "a double-click on «Ещё»: the strip stays open")
check(click("pull", 2) and #pulls == np, "Pull 0.2 s after the strip appeared under the cursor: nothing")
CLK = CLK + 0.5
check(click("pull", 2) and #pulls == np + 1 and pulls[#pulls] == "k_alex", "0.7 s after: pulled")

-- ------------------------------------------------------------ 7. English, client
cfg.set("language", "en")
i18n.notify()
local en = table.concat(texts_of(UI.player_rows[2].acts), "|")
check(en:find("Kick|Ban|More|›", 1, true) ~= nil, "English: Kick | Ban | More ›: " .. en)
check(table.concat(texts_of(UI.player_rows[2].strip), "|"):find("Pull to me", 1, true) == 1, "English: Pull to me")
check(UI.player_rows[2].extra_btns.pull and i18n.STR.en.pull_tip == "Move the player next to you: stuck, fell through the ground or lost",
    "English tooltip")
cfg.set("language", "ru")
i18n.notify()
session.state.role = "client"
session.state.client = { host_name = "Alice", roster = { { name = "Alice", state = "host", host = true },
    { name = "Me", state = "game", me = true, ping = 30 }, { name = "Bob", state = "game", key = "k_bob" } } }
ROSTER = session.state.client.roster
UI.players_sig = nil
UI.refresh_status()
pm = UI.players_model()
check(not pm.rows[3].acts and #pm.rows[3].extra == 0 and not vis(UI.player_rows[3].acts), "a client: no Kick / Ban / «Ещё»")
-- 9 (a client): one line per player, long names as in the host's view
session.state.client.roster = { { name = "Alexander_The_Long_Named", state = "host", host = true },
    { name = "Christopher_Clientside_Longname", state = "game", me = true, ping = 30 },
    { name = "Maximilian_Von_Extremely_Longer", state = "lag", key = "k_max" } }
ROSTER = session.state.client.roster
UI.players_sig = nil
UI.refresh_status()
check(lines(1) == 1 and lines(2) == 1 and lines(3) == 1 and gap(1) == 1 and gap(2) == 1 and gap(3) == 1,
    "a client: one line per player (the gaps back to 1)")
check(UI.player_rows[1].name._text == "Alexander_The_Long_Named" and UI.player_rows[1].state._text == "хост"
    and UI.player_rows[1].name._tip == "Alexander_The_Long_Named", "a client: the host's 24-letter name whole (and its tooltip)")
check(UI.player_rows[2].name._text == ("Christopher_Clientside_Longname"):sub(1, 21) .. "… (вы)"
    and UI.player_rows[3].name._text == LONG31.name:sub(1, 23) .. "…", "a client: long names cut only past 24 (own: 22)")
local cs = rawget(rawget(UI.player_rows[3].line1, "_slots")[2], "_size")
check(cs and cs.SizeRule == 1 and UI.player_rows[3].ping._text == "", "a client: the name in the Fill slot")
check(#errors == 0, "no errors: " .. table.concat(errors, "; "))

print = real_print
io.write(string.format("pull_ui: %d checks, %d failed\n", nchecks, fails))
io.write(fails == 0 and "ALL OK\n" or (fails .. " FAILED\n"))
os.exit(fails == 0 and 0 or 1)
