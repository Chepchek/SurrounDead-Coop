-- SDCoop: text chat between the players of one co-op world (0.7.3).
--
-- What the player sees (config chat, chat_sound, chat_key):
--   * Enter (chat_key, an Unreal key name) opens a one-line input at the
--     bottom left, above the health bars and the light / night-vision icons.
--     Enter sends, Esc closes. While it is open the game gets no keyboard or
--     mouse: the character does not move or shoot, WASD, digits, Tab, J, M,
--     Y, F5 and Esc do nothing in the game, the mouse does not turn the
--     camera. Cyrillic works (Montserrat Bold, the game's HUD font).
--   * A calm feed above it, made like the game's own notifications (the
--     game has no chat; NotficationUI_C, mirrored for the left side): each
--     message on its own black plate, rounded on the left, ending in the
--     game's own fade texture (the game's plate is that fade across its whole
--     width; here a solid 0.6 with only its end faded, so the end of a long
--     message stays readable on snow); Montserrat Bold 12 (16 px) in white, the nick
--     in the player's map / compass colour (sdc_playermarks.color_of, a
--     quarter toward white). A row is as wide as its text (at most 460); a
--     long message wraps inside it at a fixed width worked out from the nick
--     (screenshots 2026-11-13: wrapped at the width the layout had given the
--     previous, short message - two or three letters a line). The feed sits
--     between Stats and the game's infection plate (left middle, ends at y
--     560 of 1080): no row above y 580 - fewer rows, and a message taller
--     than the room is cut. Up to 5 rows, each gone after ~10 s (+1 s per 40
--     characters, 1 s fade); while the line is open the last 10 messages show
--     (as many as fit). The game's notification widget itself is not used:
--     its Blueprint removes itself after its Delay and has one text (no
--     nick colour), and its settings are Blueprint properties (the UE4SS
--     property cache, sdc_widgets). Nothing else: no icons, frames or
--     markers. A quiet click of the game's own UI sound on another player's
--     message (at most every 3 s, chat_sound).
--   * The feed hides with the HUD (Y), under the cursor (inventory, map,
--     journal, pause, F7...) and on death; what came meanwhile shows when it
--     is back (up to 5 lines of the last 60 s). Off in single player and for
--     a host without guests. A world change clears it.
--
-- Keyboard (why it works this way):
--   * Open: the chat key is read on the game thread every frame while the
--     chat may open (pc:WasInputKeyJustPressed; no UE4SS key bind): only
--     presses the game itself received count, so the Steam overlay, a game
--     window or the console never open it. A real press only: the Windows
--     auto-repeat of a held key comes to the game as a repeat, not a press,
--     so the Enter that sent a message and is still held never reopens the
--     line, while a quick second Enter right after sending does (review
--     2026-11-13: the older down-edge read ate a press within 1.1 s of a
--     send). main.lua's frame loop runs every engine tick: no press is
--     missed. Should that call fail, the key's down state is read instead
--     (pc:IsInputKeyDown, as sdc_vehicles' Tab), and after a close by Enter
--     the key must be let go (or 1.1 s pass with it up) first. Each attempt
--     checks live what may hold the input (cursor, F7 panel, join cover,
--     death and death screen, game windows, console, Alt for Alt+Enter);
--     the 250 ms tick only decides whether the key is read at all.
--   * While open: WidgetBlueprintLibrary.SetInputMode_UIOnlyEx(pc, field, 0,
--     true), as the game's own rename window (HUD_Game @522): the viewport
--     ignores input (GameViewportClient.SetIgnoreInput), held keys are let go
--     (bFlushInput), the field has the keyboard. Auto-run (AutoRun?, which
--     the game drives every frame without a key, BP_PlayerCharacter @132407)
--     is switched off, and a car whose inputs this machine drives gets
--     throttle / steering / brake 0 (the calls the game makes when the keys
--     are let go; not on a copy that follows the replicated inputs).
--   * Enter: the field is a MultiLineEditableText, where Enter types a line
--     break. The frame loop reads the text every frame while the line is
--     open; a line break means "send". Everything typed before Enter is in
--     the text by then (Slate hands typed keys to widgets after the engine
--     tick, in order), and no letter typed before it can reach the game after
--     the switch back. (A UE4SS key bind for Enter fires on UE4SS's own thread
--     before the last letters reach the field: the message lost its tail and
--     the letter went to the game as a key - Russian "а" is the interact key
--     F.) The break goes in where the caret is, so the frame compares the
--     text with the one a frame earlier (message_of): a break that came with
--     at most 3 other characters is a typed Enter - the message is the text
--     without it (a fix mid-text: "приве|т" + Enter sends "привет", not
--     "приве т"), characters typed after it in that frame dropped. More is a
--     paste: it sends too, its line breaks become spaces. A line break within
--     0.6 s of opening with nothing typed since (the text is what the line
--     opened with) is the opening key repeating: removed (Windows repeats
--     only the last key, so a letter typed in between ends the repeat). With
--     a draft in the line, only from 0.2 s on: Windows starts repeating 0.25
--     s after a press at the soonest, so an earlier one is a second press - a
--     quick double Enter sends the draft (review 2026-11-13); the empty line
--     keeps the whole 0.6 s (a second Enter there would only close it).
--   * Esc: the field cannot report it and the game does not see it, so a
--     UE4SS key bind only flips main.lua's KEYS.chat_esc and the frame loop
--     calls M.on_esc. The game's input comes back 0.3 s later: an Esc let go
--     before the keyboard's repeat delay (Windows: 0.25-1 s, 0.5 by default)
--     never reaches the game. Held longer, its repeats reach the game and
--     open its pause menu; held on, the next repeat closes it again (the
--     menu's OnKeyDown takes repeats too) and the one after opens it: it
--     flickers until the key is let go (the release cannot be seen while the
--     game has no input). The menu the held key leaves open is closed the
--     game's way (esc_guard: from the closing Esc for 1.5 s, and on for 1 s
--     after each time the menu comes back, no new Esc press since - review
--     2026-11-13: a hold past 1.5 s left it to chance).
--   * Leaving: Enter / Esc / everyone left / no focus for 3 s give the game
--     its input back (sdc_widgets.game_input) unless something else holds it
--     now (cursor on, F7 panel, a game window, death or a death screen; the
--     console: once it closes). Whatever takes the input (cursor on, death,
--     F7: sdc_ui closes the line first) closes the line in the same frame
--     without touching the input mode; the text typed so far stays as a
--     draft for the next open (Esc and sending clear it).
--   * The field keeps the keyboard: navigation rules Stop (Tab, arrows); a
--     focus lost without Enter / Esc (a click, Alt-Tab) is taken back every
--     0.25 s. sdc_widgets.game_window_open answers "the chat" while the line
--     holds the input (open, cursor off), so none of the mod's "back to game
--     controls" steals it.
--
-- Network (sdc_net; CHAT / CHATM are SECRET there: never logged):
--   client -> host  CHATON|1|<0/1>   this mod has the chat (+ shown here or not)
--   host -> client  CHATON|1         the answer, only to a player the host let in
--   client -> host  CHAT|<text>
--   host -> client  CHATM|<PlayerId>|<name>|<text>
--   The host takes CHAT only from a player it let in (HI, access "ok", not
--   kicked, live controller: sdc_admin's rule) and finds the sender by the
--   controller the RPC came on: the name and id are the host's, never the
--   message's. Names are compared as the feed shows them (cut to 16
--   characters with "…"): one that looks like the host's or an earlier
--   player's (case, look-alike Latin / Cyrillic letters, invisible
--   characters) gets " 2", " 3"..., kept whole after a cut
--   ("LongPlayerNa… 2"), never a name another player already shows (review
--   2026-11-13: a long name lost its " 2" to the cut). The host sends the
--   name as the feed shows it, and CHATM to every player that told CHATON -
--   the author too: its own line shows when the host's copy comes back (no copy
--   within 3 s, or more than 4 waiting - the oldest: shown dim, "not
--   delivered"; a late copy fixes it). An older
--   mod never sees CHATM (it sends no CHATON), and a client of an older host
--   has no chat (Enter shows why).
--   Text: control and invisible characters out, spaces squeezed, at most
--   200 characters cut on a character boundary; broken UTF-8 from the
--   network is dropped. '%' and '|' are escaped (%25, %7C): sdc_net turns
--   '|' into a space. Rate: 4 at once then 1 per 2 s (own messages), 5 at
--   once then 1 per 2 s per player (host).
-- Logs: never a text or a name (UE4SS.log cannot show Cyrillic and logs get
--   shared): lengths and an FNV-1a hash (to match sender and receiver), the
--   PlayerId (a small session number, not a SteamID).

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local i18n = require("sdc_i18n")
local W = require("sdc_widgets")

local function T(key) return i18n.T(key) end

local M = {
    stats = { sent = 0, shown = 0, relayed = 0, dropped = 0, undelivered = 0, opened = 0, refocus = 0, unpaused = 0 },
}

local S = nil   -- sdc_session.state

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local PROTO = "1"
local MAX_CHARS = 200          -- characters (not bytes) of one message
local NAME_MAX = 24            -- characters of a name on the wire
local NICK_SHOWN = 16          -- characters of a nick in the feed ("…" after)
local HISTORY = 10             -- messages kept (memory only) and shown while open
local FEED_ROWS = 5            -- lines shown while closed
local LIFE_S, LIFE_STEP, LIFE_MAX, FADE_S = 10, 40, 16, 1
local SYS_LIFE_S = 5           -- a hint line of the chat itself
local UNSEEN_S = 60            -- missed lines younger than this show when the feed is back
local OPEN_GUARD_S = 0.6       -- a line break this soon after opening, nothing typed: the opening key repeating
local REPEAT_MIN_S = 0.2       -- ... but with a draft not before this (Windows: a repeat 0.25 s after the press at the soonest, less a frame)
local TYPED_MAX = 3            -- other characters with a line break in one frame: at most this = typed, more = a paste
local REARM_S = 1.1            -- fallback read only: after an Enter close the key up this long (or let go) first
local ESC_GIVE_BACK_S = 0.3    -- the game's input after Esc (an Esc let go by then never reaches the game)
local ESC_GUARD_S = 1.5        -- after an Esc close: a pause menu the held Esc opens is closed again
local ESC_HOLD_S = 1.0         -- ... and on this long after each time it comes back (the key still held: 2 repeats at 2.5/s)
local ESC_GUARD_MAX_S = 20     -- ... at most this long after the closing Esc
local PAUSE_SETTLE_S = 0.08    -- ... once it is on screen this long with no new Esc press (UE4SS's key thread may lag)
local REFOCUS_S = 0.25         -- the field's focus taken back at most this often
local NOFOCUS_GIVE_UP_S = 3    -- no focus this long: the line closes, the game gets its input back
local NOTE_S = 1.5             -- "not so fast" in the line
local COUNT_FROM = 20          -- characters left shown from here
local PENDING_S = 3            -- own message without the host's copy this long: "not delivered"
local PENDING_MAX = 4
local SOUND_GAP_S, SOUND_VOL = 3, 0.6
local ASK_EVERY_S, ASK_MAX = 5, 6      -- client: CHATON asks until the host answers
local OLD_HOST_AFTER_S = 8             -- client: asked this long without an answer -> the host's mod has no chat
local HINT_EVERY_S = 10
local DROP_LOG_S = 10
local RATE = { own = { burst = 4, per = 2 }, guest = { burst = 5, per = 2 } }

-- Layout, in Slate units: the screen is 1080 high at any resolution (the
-- game's DPI curve), so these are 1080p pixels. Where the game's HUD is
-- (BP_Ingame): Stats 275x135 at (10,-10) bottom left, the light / NVG /
-- respirator chips 60x20 at 147.5..167.5 above the bottom, InfectionBorder
-- (a dark plate) at the left middle, y 520..560; notifications at the right
-- middle; the hotbar centred at the bottom. The chat stays between: x from
-- Stats' left edge, the input line's bottom at y 900, nothing above y 580.
local L = {
    POS_X = 10, POS_Y = -180,          -- the input line's bottom left
    SCREEN_H = 1080, TOP_Y = 580,
    GAP = 6,                           -- between the feed and the input line
    ROW_GAP = 2,                       -- between the feed's rows
    FEED_W = 460,                      -- a row at most / the input line, fade included
    -- One row, after the game's notification (NotficationUI_C: Border padding
    -- 5, the icon slot 6 from the left, the text 12 after it and 24 before
    -- the faded end; its plate is the fade texture across the whole width),
    -- mirrored for the left side: plate | nick | text | the fade. Ours: the
    -- game's padding 5 and 6 before the nick, then 10 / 10 (more room for the
    -- text), a solid plate with only a 28 px faded end (readable on snow).
    -- Its width follows the text (as the game's), the message wraps at a
    -- fixed width (WrapTextAt) worked out from the nick.
    PAD = 5,                           -- plate padding, top / bottom / left
    NICK_PAD = 6, TEXT_GAP = 10, END_PAD = 10, MARK_GAP = 8,
    FADE_W = 28,                       -- the plate's faded end
    MIN_WRAP = 120,
    LINE_H = 20,                       -- Montserrat at 16 px: line height 1.219 em = 19.5
    IN_PAD_L = 8, IN_PAD_V = 5, SIDE_W = 40,   -- the input line's plate padding, its counter
    RADIUS = 10,
    ROW_A = 0.6, INPUT_A = 0.75,       -- plate alpha: a row, the input line
    FADE_MAX_A = 0.91,                 -- the fade texture's darkest alpha
}
L.AVAIL_H = L.SCREEN_H + L.POS_Y - L.TOP_Y                              -- 320: feed + gap + input line
L.TEXT_W = L.FEED_W - L.FADE_W - L.PAD - L.NICK_PAD - L.END_PAD          -- 411: a message's room without a nick
L.MSG_MAX_H = L.AVAIL_H - L.GAP - (2 * L.IN_PAD_V + L.LINE_H) - 2 * L.PAD - L.ROW_GAP   -- 272: taller is cut
L.FIELD_W = L.FEED_W - L.FADE_W - L.IN_PAD_L - L.END_PAD - L.SIDE_W      -- the input text's wrap (estimate)
local ZORDER = 880                     -- above the HUD (2) and inventory (1), under the F7 panel (900)
-- The game's notification text: Montserrat Bold 12 (16 px), white; its
-- secondary HUD texts (LVL, FPS, battery %) 10.
local SIZE_TEXT, SIZE_SIDE = 12, 10
local FONT_PATH = "/Game/UI/Fonts/Montserrat-Bold_Font.Montserrat-Bold_Font"
-- The game's notification plate: black, alpha 0 -> 0.92 across (BGRA8
-- 622x731, constant down), RoundedBox, radius 10 on its dark side.
local FADE_PATH = "/Game/UI/Textures/fade-right.fade-right"
local CLICK_PATH = "/Game/Audio/SurvivalSoundPack/Cues/UI_click_sound_Cue.UI_click_sound_Cue"

-- ESlateVisibility, alignment, navigation, wrapping, clipping, brushes
local VIS_VISIBLE, VIS_COLLAPSED, VIS_HIDDEN, VIS_HIT_TEST_INVISIBLE, VIS_SELF_HIT_TEST_INVISIBLE = 0, 1, 2, 3, 4
local HALIGN_LEFT = 1
local VALIGN_FILL, VALIGN_TOP, VALIGN_CENTER = 0, 1, 2
local SIZE_FILL = 1
local NAV_STOP = 3                     -- EUINavigationRule::Stop
local NAV_DIRS = { 0, 1, 2, 3, 4, 5 }  -- Left Right Up Down Next Previous
local WRAP_PER_CHAR = 1                -- ETextWrappingPolicy::AllowPerCharacterWrapping
local CLIP_BOUNDS = 1                  -- EWidgetClipping::ClipToBounds
local DRAW_IMAGE, DRAW_ROUNDED = 3, 4  -- ESlateBrushDrawType
local ROUND_FIXED = 0                  -- ESlateBrushRoundingType::FixedRadius

-- Keys of the game's input context (work\re\json\IMC_General.json, the only
-- one: walking, vehicles, weapons and UI share it). A chat_key among them
-- also runs the game's action.
local GAME_KEYS = {}
for k in ("A B Backslash C D Down E Eight Equals Escape F F5 Five Four H Hyphen J K L Left LeftAlt LeftControl "
    .. "LeftMouseButton LeftShift M MiddleMouseButton N Nine O One Q R Right RightMouseButton S Semicolon Seven "
    .. "Six SpaceBar T Tab Three Two Up V W X Y Z"):gmatch("%S+") do GAME_KEYS[k] = true end

-- Colours: sRGB tokens ("chalk and signal"), Slate wants linear.
local function srgb(hex, a)
    local function ch(i)
        local c = tonumber(hex:sub(i, i + 1), 16) / 255
        return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
    end
    return { R = ch(1), G = ch(3), B = ch(5), A = a or 1 }
end
local function alpha(c, a) return { R = c.R, G = c.G, B = c.B, A = a } end
-- The game's HUD colours: white text (its TextBlocks keep the default
-- colour), black plates - 0.5 (Stats, the battery chips), 0.75
-- (InfectionBorder). The mod's signal colour only for "not delivered".
local WHITE, BLACK, SIGNAL = { R = 1, G = 1, B = 1, A = 1 }, { R = 0, G = 0, B = 0, A = 1 }, srgb("F2552C")
local C = {
    text = WHITE,
    dim = alpha(WHITE, 0.6),
    failed = alpha(WHITE, 0.55),
    mark = alpha(SIGNAL, 0.85),
    row_bg = alpha(BLACK, L.ROW_A),
    input_bg = alpha(BLACK, L.INPUT_A),
    shadow = alpha(BLACK, 0.5),
}

local function clock() return os.clock() end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------

-- Only whole, valid characters (local input; a message from the network
-- with broken UTF-8 is dropped instead).
local function utf8_fix(s)
    if utf8.len(s) then return s end
    local out = {}
    for ch in s:gmatch("[\0-\127\194-\244][\128-\191]*") do
        if utf8.len(ch) == 1 then out[#out + 1] = ch end
    end
    return table.concat(out)
end

-- nil = keep, "" = drop, " " = a space
local function replace_cp(cp)
    if cp < 32 or cp == 127 or (cp >= 0x80 and cp <= 0x9F) then return " " end
    if cp == 0xA0 or cp == 0x2028 or cp == 0x2029 or cp == 0x3000 or cp == 0x202F or cp == 0x205F
        or (cp >= 0x2000 and cp <= 0x200A) then return " " end
    -- invisible: soft hyphen, zero-width, direction marks / embeddings /
    -- isolates, word joiners, BOM, Mongolian vowel separator, grapheme
    -- joiner, interlinear annotations, tags
    if cp == 0xAD or cp == 0x34F or cp == 0x180E or (cp >= 0x200B and cp <= 0x200F)
        or (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2060 and cp <= 0x206F) or cp == 0xFEFF
        or (cp >= 0xFFF9 and cp <= 0xFFFB) or (cp >= 0xE0000 and cp <= 0xE007F) then return "" end
    return nil
end

local function combining(cp)
    return (cp >= 0x300 and cp <= 0x36F) or (cp >= 0x1AB0 and cp <= 0x1AFF) or (cp >= 0x1DC0 and cp <= 0x1DFF)
        or (cp >= 0x20D0 and cp <= 0x20FF) or (cp >= 0xFE20 and cp <= 0xFE2F)
end

-- Cut to `max` characters on a character boundary.
local function cut(s, max)
    local n = utf8.len(s)
    if n and n > max then s = s:sub(1, utf8.offset(s, max + 1) - 1) end
    return s
end

-- A message / name as it may be shown and sent: control and invisible
-- characters out, at most 2 combining marks in a row, spaces squeezed and
-- trimmed, at most `max` characters. strict: broken UTF-8 -> nil, "bad utf8"
-- (else the broken bytes are dropped). Empty -> nil, "empty". Idempotent.
local function clean_text(s, max, strict)
    s = tostring(s or "")
    if not utf8.len(s) then
        if strict then return nil, "bad utf8" end
        s = utf8_fix(s)
    end
    local out, marks = {}, 0
    for _, cp in utf8.codes(s) do
        local r = replace_cp(cp)
        if r == nil then
            if combining(cp) then marks = marks + 1 else marks = 0 end
            if marks <= 2 then out[#out + 1] = utf8.char(cp) end
        elseif r == " " then
            out[#out + 1] = " "
            marks = 0
        end
    end
    s = table.concat(out):gsub("%s+", " ")
    s = s:gsub("^ ", ""):gsub(" $", "")
    s = cut(s, max or MAX_CHARS):gsub(" $", "")
    if s == "" then return nil, "empty" end
    return s
end

local function esc(s)
    return (tostring(s or ""):gsub("[%%|]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function unesc(s)
    return (tostring(s or ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- FNV-1a (32 bit) of the bytes: matches a sender's and a receiver's log line.
local function hash(s)
    local h = 2166136261
    for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff end
    return string.format("%08x", h)
end

local function ulen(s) return utf8.len(s or "") or #(s or "") end

-- How a name looks: lower case, then Cyrillic letters that look like Latin
-- ones in either case (А В Е К М Н О Р С Т У Х) as those, 0 / 1 / i as
-- o / l / l. Two names with the same skeleton look the same (a few that only
-- look alike in one case count too: one more " 2" is harmless).
local LOOK = {
    [0x430] = "a", [0x432] = "b", [0x435] = "e", [0x451] = "e", [0x43A] = "k", [0x43C] = "m", [0x43D] = "h",
    [0x43E] = "o", [0x440] = "p", [0x441] = "c", [0x442] = "t", [0x443] = "y", [0x445] = "x",
    [0x456] = "l", [0x458] = "j", [0x455] = "s",
    [0x30] = "o", [0x31] = "l", [0x69] = "l",
}
local UPPER = { [0x401] = 0x451, [0x405] = 0x455, [0x406] = 0x456, [0x408] = 0x458 }
local function skeleton(s)
    local out = {}
    for _, cp in utf8.codes(s) do
        if cp >= 0x41 and cp <= 0x5A then cp = cp + 32
        elseif cp >= 0x410 and cp <= 0x42F then cp = cp + 32
        elseif UPPER[cp] then cp = UPPER[cp]
        end
        out[#out + 1] = LOOK[cp] or utf8.char(cp)
    end
    return table.concat(out)
end

local function clean_name(s, fallback)
    return clean_text(s, NAME_MAX, false) or fallback or "Player"
end

-- How a name shows in the feed: at most NICK_SHOWN characters, "…" where it
-- was cut; tail (the host's " 2" for a look-alike name) always whole.
local function nick_shown(name, tail)
    tail = tail or ""
    local room = NICK_SHOWN - ulen(tail)
    if ulen(name) <= room then return name .. tail end
    return (cut(name, room - 1):gsub(" +$", "")) .. "…" .. tail
end

-- seconds a line stays (before its fade)
local function life_of(len)
    return math.min(LIFE_MAX, LIFE_S + math.floor(math.max(0, len - 1) / LIFE_STEP))
end

-- Widths in the game's font (Montserrat Bold): advance widths in 1/1000 em
-- read from the game's own Montserrat-Bold.ufont (hmtx), printable ASCII
-- and Russian Cyrillic; anything else (emoji, other scripts: a fallback
-- font) counts as 1.2 em. Each character rounded up to a whole pixel, the
-- kerning the game applies only narrows: never below the real width, so a
-- nick and its message never need more than the row has, and the line
-- count (a word wrap done the same way) never falls short.
local ADV = {}
do
    local ascii = { -- 32 .. 126
        283, 289, 437, 720, 638, 877, 728, 230, 357, 358, 434, 599, 262, 386, 262, 392, 679, 392, 590, 592, 689, 595,
        637, 620, 660, 637, 262, 262, 599, 599, 599, 589, 1035, 766, 765, 733, 826, 671, 639, 771, 808, 328, 541, 740,
        604, 955, 808, 844, 732, 844, 735, 638, 618, 788, 746, 1163, 714, 676, 671, 368, 392, 368, 600, 500, 600, 617,
        690, 591, 692, 631, 387, 700, 691, 301, 307, 660, 301, 1049, 691, 655, 690, 690, 431, 531, 435, 687, 598, 937,
        595, 598, 543, 391, 309, 391, 599 }
    local cyr = { -- 0x410 .. 0x44F (А .. я)
        799, 738, 745, 593, 831, 673, 1079, 656, 821, 821, 735, 799, 963, 817, 842, 812, 724, 726, 637, 724, 950, 722,
        841, 749, 1098, 1130, 845, 1028, 721, 714, 1114, 734, 604, 673, 622, 514, 701, 643, 913, 563, 710, 710, 642,
        666, 815, 694, 654, 685, 694, 592, 535, 614, 849, 592, 704, 634, 971, 971, 682, 859, 605, 590, 903, 628 }
    for i, a in ipairs(ascii) do ADV[31 + i] = a end
    for i, a in ipairs(cyr) do ADV[0x40F + i] = a end
    ADV[0x401], ADV[0x451], ADV[0x2026] = 673, 643, 798   -- Ё ё …
    ADV[0x2013], ADV[0x2014] = 500, 1000                  -- – —
end

-- one character's width in Slate units (UMG font size is points at 96 dpi: 12 -> 16)
local function char_w(cp, size)
    return math.ceil((ADV[cp] or 1200) * size / 750)
end

local function text_w(s, size)
    s = s or ""
    local w = 0
    if utf8.len(s) then
        for _, cp in utf8.codes(s) do w = w + char_w(cp, size) end
    else
        w = #s * char_w(-1, size)
    end
    return w + 2
end

-- Lines a text takes at a wrap width: wrapped at spaces as the game's text
-- layout does, a word longer than the line broken between letters.
local function lines_of(s, wrap)
    wrap = math.max(20, wrap)
    s = s or ""
    if not utf8.len(s) then return math.ceil(text_w(s, SIZE_TEXT) / math.max(1, wrap)) end
    local space = char_w(32, SIZE_TEXT)
    local lines, x = 1, 0
    for word in s:gmatch("[^ ]+") do
        local w = 0
        for _, cp in utf8.codes(word) do w = w + char_w(cp, SIZE_TEXT) end
        if x > 0 and x + space + w > wrap then
            lines, x = lines + 1, 0
        elseif x > 0 then
            x = x + space
        end
        while x + w > wrap and w > 0 do   -- a word wider than the line
            local fits = wrap - x
            w = w - fits
            lines, x = lines + 1, 0
        end
        x = x + w
    end
    return lines
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local st = {
    open = false, owns = false, opened_at = 0, closed_at = -1e9,
    draft = nil, note_until = 0, side = nil,
    open_text = "", last_text = "",    -- the line's text when it opened / a frame ago (never a line break)
    input_lines = 1,                   -- lines the input text takes (estimate: the feed's room above it)
    esc_guard = nil,                   -- after an Esc close: { until_at, fresh, seen_at } (the held Esc)
    allowed = false, session_ok = false, feed_on = false, hint_poll = false,
    restore_at = nil, restore_why = nil, restore_console = false,
    nofocus_since = nil, focus_try_at = 0, focus_logged = false,
    poll = { armed = true, was_down = true, saw_down = false, edge = false },   -- edge: the fallback read
    key_name = nil, key = nil,
    pending = {}, hist = {}, seq = 0,
    own_rate = {}, last_sound = -1e9, last_hint = -1e9,
    dirty = false, fading = false, next_render_at = nil,
    drops = { n = 0, logged_at = -1e9 },
    said = {},
}
local peers = {}         -- host: [session key] = { rec, ok, want }
local guest_rate = {}    -- host: [session key] = { rec, b }
local cl = {}            -- client: { cs, pc_key, host_ok, asks, ask_at, first_ask_at, sent_want }
local ui = { failed = 0 }

local function once(key, fmt, ...)
    if st.said[key] then return end
    st.said[key] = true
    log.info(fmt, ...)
end

-- ---------------------------------------------------------------------------
-- Engine helpers
-- ---------------------------------------------------------------------------

local function in_viewport(w)
    if not ue.valid(w) then return false end
    local ok, v = pcall(function() return w:IsInViewport() end)
    return ok and v == true
end

local function cursor_on(pc)
    return ue.prop(pc, "bShowMouseCursor") == true
end

local function dead(pawn)
    return ue.prop(pawn, "PlayerDead?") == true
end

local function panel_open()
    local p = package.loaded["sdc_ui"]
    return type(p) == "table" and p.open == true
end

local function cover_on()
    local p = package.loaded["sdc_ui"]
    if type(p) ~= "table" or type(p.join_cover_model) ~= "function" then return false end
    local ok, m = pcall(p.join_cover_model)
    return ok and type(m) == "table" and m.visible == true
end

local function game_window()
    local p = package.loaded["sdc_uiinput"]
    if type(p) ~= "table" or type(p.game_ui_open) ~= "function" then return nil end
    local ok, what = pcall(p.game_ui_open)
    if ok and what then return tostring(what) end
    return nil
end

local DEATH_SCREENS = { "RespawnScreen_C", "ScreenPermadeath_C" }
local function death_screen()
    for _, cls in ipairs(DEATH_SCREENS) do
        for _, w in ipairs(ue.find_all(cls)) do
            if in_viewport(w) then return cls end
        end
    end
    return nil
end

local function console_open()
    for _, c in ipairs(ue.find_all("Console")) do
        local s = ue.str(ue.prop(c, "ConsoleState"))
        if s ~= "" and s ~= "None" then return true end
    end
    return false
end

local function key_down(pc, key)
    return ue.try(function() return pc:IsInputKeyDown(key) end) == true
end

local ALT_KEYS = nil
local function alt_down(pc)
    if not ALT_KEYS then ALT_KEYS = { { KeyName = FName("LeftAlt") }, { KeyName = FName("RightAlt") } } end
    return key_down(pc, ALT_KEYS[1]) or key_down(pc, ALT_KEYS[2])
end

local function has_focus(w)
    if not ue.valid(w) then return false end
    local ok, v = pcall(function() return w:HasKeyboardFocus() end)
    if not ok then return true end   -- cannot tell: never a false "focus lost"
    return v == true
end

local function ps_id(pc)
    local ps = ue.prop(pc, "PlayerState")
    if not ue.valid(ps) then return nil end
    local ok, id = pcall(function() return ps:GetPlayerId() end)
    if ok and type(id) == "number" then return math.floor(id) end
    local v = ue.prop(ps, "PlayerId")
    if type(v) == "number" then return math.floor(v) end
    return nil
end

local function my_id()
    local pc = ue.local_pc()
    return pc and ps_id(pc) or nil
end

-- the nick colour: the player's marker colour, a quarter of the way to white
-- (readable on the dark plate)
local function nick_color(id)
    local pm = package.loaded["sdc_playermarks"]
    if id and type(pm) == "table" and type(pm.color_of) == "function" then
        local ok, c = pcall(pm.color_of, id)
        if ok and type(c) == "table" and c.R then
            return { R = c.R * 0.75 + 0.25, G = c.G * 0.75 + 0.25, B = c.B * 0.75 + 0.25, A = 1 }
        end
    end
    return WHITE
end

-- ---------------------------------------------------------------------------
-- Who may talk
-- ---------------------------------------------------------------------------

local function chat_on() return cfg.get("chat") ~= false end

-- Host: a player let in (sdc_admin: hello, access ok, not kicked, live controller).
local function admitted(r)
    return type(r) == "table" and r.hello == true and r.access == "ok" and not r.kicked and ue.valid(r.pc)
end

-- Host: players that get CHATM (they told CHATON, were let in, show the chat).
local function chat_peers()
    local out = {}
    local remote = (S and S.remote) or {}
    for key, p in pairs(peers) do
        local r = remote[key]
        if r == p.rec and p.ok and p.want ~= false and admitted(r) then out[#out + 1] = r end
    end
    table.sort(out, function(a, b) return (a.index or 0) < (b.index or 0) end)
    return out
end

local function client_sync()
    local cs = S and S.client
    if cl.cs ~= cs or (cs and cl.pc_key ~= cs.pc_key) then
        cl = { cs = cs, pc_key = cs and cs.pc_key, host_ok = false, asks = 0 }
    end
    return cs
end

local function client_ok()
    local cs = client_sync()
    return cs ~= nil and cs.acked == true and cs.access ~= "wait" and cl.host_ok == true
end

-- the client asked and the host's mod never answered
local function old_host(now)
    local cs = client_sync()
    return cs ~= nil and cs.acked == true and cs.access ~= "wait" and not cl.host_ok
        and (cl.asks or 0) >= 2 and cl.first_ask_at ~= nil and now - cl.first_ask_at >= OLD_HOST_AFTER_S
end

local function base_name(r)
    return clean_name(r.name, "Player " .. tostring(r.index or "?"))
end

-- Host: the names players show with, by record (every player let in, in
-- join order). Compared as the feed shows them (cut to NICK_SHOWN): the
-- host's own name never changes; a player whose name looks like the host's
-- or an earlier player's gets " 2", " 3"... (kept after a cut), never a name
-- another player shows or has (review 2026-11-13: "LongPlayerName99 2" was
-- cut back to "LongPlayerName9…", and a third "Bob" got a second "Bob 2").
local function display_names()
    local list = {}
    for _, o in pairs((S and S.remote) or {}) do
        if admitted(o) then list[#list + 1] = o end
    end
    table.sort(list, function(a, b)
        if (a.index or 0) ~= (b.index or 0) then return (a.index or 0) < (b.index or 0) end
        return tostring(a.key) < tostring(b.key)
    end)
    local plain = {}     -- every player's own name as shown
    for _, o in ipairs(list) do plain[skeleton(nick_shown(base_name(o)))] = true end
    local taken = { [skeleton(nick_shown(clean_name(cfg.player_name())))] = true }
    local out = {}
    for _, o in ipairs(list) do
        local base = base_name(o)
        local name = nick_shown(base)
        local sk = skeleton(name)
        if taken[sk] then
            name = nil
            for n = 2, 99 do
                local cand = nick_shown(base, " " .. n)
                local csk = skeleton(cand)
                if not taken[csk] and not plain[csk] then
                    name, sk = cand, csk
                    break
                end
            end
            if not name then
                name = nick_shown(base, " #" .. tostring(o.index or "?"))
                sk = skeleton(name)
            end
        end
        taken[sk] = true
        out[o] = name
    end
    return out
end

local function display_name(r)
    return display_names()[r] or nick_shown(base_name(r))
end

-- ---------------------------------------------------------------------------
-- Rate
-- ---------------------------------------------------------------------------

local function take(b, now, rule)
    if not b.at then b.at, b.tokens = now, rule.burst end
    b.tokens = math.min(rule.burst, b.tokens + math.max(0, now - b.at) / rule.per)
    b.at = now
    if b.tokens >= 1 then
        b.tokens = b.tokens - 1
        return true
    end
    return false
end

local function drop(id, why)
    M.stats.dropped = M.stats.dropped + 1
    st.drops.n = st.drops.n + 1
    local now = clock()
    if now - st.drops.logged_at >= DROP_LOG_S then
        st.drops.logged_at = now
        log.info("chat: dropped from id=%s: %s (%d so far)", tostring(id or "?"), why, st.drops.n)
    end
end

-- ---------------------------------------------------------------------------
-- History and the feed's model
-- ---------------------------------------------------------------------------

local function add_entry(e, now)
    st.seq = st.seq + 1
    e.seq = st.seq
    e.at = now
    e.len = ulen(e.text)
    e.hash = e.hash or hash(e.text)
    e.life = e.sys and SYS_LIFE_S or life_of(e.len)
    e.nick = e.sys and "" or nick_shown(e.name or "?")
    e.nick_w = e.sys and 0 or text_w(e.nick, SIZE_TEXT)
    e.color = e.sys and C.dim or nick_color(e.id)
    if st.open or st.feed_on then e.shown_at = now else e.unseen = true end
    st.hist[#st.hist + 1] = e
    while #st.hist > HISTORY do table.remove(st.hist, 1) end
    st.dirty = true
    M.stats.shown = M.stats.shown + 1
    return e
end

-- the feed is on screen again: lines it missed (at most FEED_ROWS, the last
-- UNSEEN_S seconds) show with their full time; older ones stay in the history
local function surface(now)
    local n = 0
    for i = #st.hist, 1, -1 do
        local e = st.hist[i]
        if e.unseen then
            e.unseen = nil
            if n < FEED_ROWS and now - e.at <= UNSEEN_S then
                e.shown_at = now
                n = n + 1
            end
        end
    end
    if n > 0 then st.dirty = true end
end

local function mark_w() return text_w(T("chat_undelivered"), SIZE_SIDE) end

-- Where a row's message wraps: the row's room less the nick and the "not
-- delivered" mark. A fixed width, not the width the layout gave the text
-- (UMG's AutoWrapText): in a row whose width follows its text that width is
-- the previous text's - a short message ("ok") left the row a few letters
-- wide, and a long one in it then wrapped every 2-3 letters (screenshots
-- 2026-11-13).
local function msg_wrap(e)
    local w = L.TEXT_W
    if not e.sys then w = w - (e.nick_w or 0) - L.TEXT_GAP end
    if e.failed then w = w - mark_w() - L.MARK_GAP end
    return math.max(L.MIN_WRAP, math.floor(w))
end

-- a row's height (estimate on the high side) for the feed's room
-- (max_h: the tallest message a row shows now - its box cuts a taller one)
local function est_height(e, max_h)
    local h = lines_of(e.text, msg_wrap(e)) * L.LINE_H
    return 2 * L.PAD + math.min(h, max_h or L.MSG_MAX_H) + L.ROW_GAP
end

-- the input line's height for `lines` lines of text
local function input_h(lines) return 2 * L.IN_PAD_V + (lines or 1) * L.LINE_H end

-- lines the input line's text takes (it grows upward, the feed above it
-- shrinks); an empty line shows the hint, which wraps the same way (review
-- 2026-11-13: the Russian hint was wider than the line and took two)
local function field_lines(s)
    s = s or ""
    if s == "" then s = T("chat_hint") end
    return math.min(10, lines_of(s, L.FIELD_W))
end

-- the feed's room: from the input line up to TOP_Y (the input line keeps
-- its place while closed: hidden, not collapsed)
local function feed_cap(open)
    return L.AVAIL_H - L.GAP - input_h(open and st.input_lines or 1)
end

-- the tallest message a row may show: the whole room (one row alone)
local function msg_max_h(open)
    return math.min(L.MSG_MAX_H, feed_cap(open) - 2 * L.PAD - L.ROW_GAP)
end

-- The lines to show, oldest first: { { e =, alpha = } }.
local function visible(now, open)
    local out, h = {}, 0
    local cap, limit = feed_cap(open), open and HISTORY or FEED_ROWS
    local max_h = msg_max_h(open)
    for i = #st.hist, 1, -1 do
        local e = st.hist[i]
        local a
        if open then
            a = 1
        elseif e.shown_at then
            local t = now - e.shown_at
            if t < e.life then a = 1 elseif t < e.life + FADE_S then a = 1 - (t - e.life) / FADE_S end
        end
        if a and a > 0 then
            local eh = est_height(e, max_h)
            if #out > 0 and h + eh > cap then break end
            h = h + eh
            table.insert(out, 1, { e = e, alpha = a })
            if #out >= limit then break end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The widget
-- ---------------------------------------------------------------------------

local function margin(l, t, r, b) return { Left = l or 0, Top = t or 0, Right = r or 0, Bottom = b or 0 } end

local font_obj = nil
local function game_font()
    if ue.valid(font_obj) then return font_obj end
    font_obj = ue.find_object(FONT_PATH)
    if not font_obj then once("font", "chat: the game's font is not in memory: the engine font for now") end
    return font_obj
end

local function set_font(t, size)
    local fo = game_font()
    pcall(function()
        local f = t.Font
        if fo then
            f.FontObject = fo
            f.TypefaceFontName = FName("Default")
        else
            f.TypefaceFontName = FName("Bold")
        end
        f.Size = size
        t:SetFont(f)
    end)
end

local function set_color(t, c)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = c, ColorUseRule = 0 }) end)
end

local function set_text(t, s)
    pcall(function() t:SetText(FText(s or "")) end)
end

local function set_vis(w, v)
    if ue.valid(w) then pcall(function() w:SetVisibility(v) end) end
end

-- The message text wraps at a fixed width (msg_wrap), never at the width
-- the layout gave it (AutoWrapText off); a word longer than the line (a
-- link) breaks between letters instead of running across the screen.
local function wrap_fixed(t, px)
    pcall(function() t.AutoWrapText = false end)
    pcall(function() t:SetAutoWrapText(false) end)
    pcall(function() t.WrappingPolicy = WRAP_PER_CHAR end)
    pcall(function() t:SetWrappingPolicy(WRAP_PER_CHAR) end)
    pcall(function() t.WrapTextAt = px end)
    pcall(function() t:SetWrapTextAt(px) end)
end

-- A built row's wrap width (the property for a rebuild, the setter for the
-- Slate widget that already shows).
local function set_wrap(t, px)
    pcall(function() t.WrapTextAt = px end)
    pcall(function() t:SetWrapTextAt(px) end)
end

local function text_block(tree, size, color)
    local t = W.new("TextBlock", tree)
    set_font(t, size)
    set_color(t, color)
    pcall(function() t:SetShadowOffset({ X = 1, Y = 1 }) end)
    pcall(function() t:SetShadowColorAndOpacity(C.shadow) end)
    return t
end

local function hadd(hb, w, fill, left, valign)
    local slot = hb:AddChildToHorizontalBox(w)
    pcall(function() slot:SetVerticalAlignment(valign or VALIGN_TOP) end)
    if fill then pcall(function() slot:SetSize({ Value = 1.0, SizeRule = SIZE_FILL }) end) end
    if left then pcall(function() slot:SetPadding(margin(left, 0, 0, 0)) end) end
    return slot
end

local function vadd(vb, w, bottom)
    local slot = vb:AddChildToVerticalBox(w)
    pcall(function() slot:SetHorizontalAlignment(HALIGN_LEFT) end)
    if bottom then pcall(function() slot:SetPadding(margin(0, 0, 0, bottom)) end) end
    return slot
end

local fade_tex = nil
local function fade_texture()
    if ue.valid(fade_tex) then return fade_tex end
    fade_tex = ue.find_object(FADE_PATH)
    if not fade_tex then once("fade", "chat: the game's notification fade is not in memory: plates without it") end
    return fade_tex
end

-- The plate's faded end: the game's own notification fade (opaque on its
-- right), turned 180 degrees as the game turns each notification (the
-- texture is the same top to bottom, so this mirrors it: opaque on the
-- left, against the plate), tinted to start at the plate's alpha. nil
-- without the texture: the plate then ends rounded.
local function fade_end(tree, a)
    local tex = fade_texture()
    if not tex then return nil end
    local f = W.new("Border", tree)
    pcall(function() f:SetBrushFromTexture(tex) end)
    pcall(function() f.Background.DrawAs = DRAW_IMAGE end)
    pcall(function() f:SetBrushColor({ R = 1, G = 1, B = 1, A = math.min(1, a / L.FADE_MAX_A) }) end)
    pcall(function() f:SetPadding(margin()) end)
    pcall(function() f:SetRenderTransformAngle(180) end)
    local box = W.new("SizeBox", tree)
    pcall(function() box:SetWidthOverride(L.FADE_W) end)
    box:SetContent(f)
    return box, f
end

-- A plate of the game's kind: black, RoundedBox, radius 10 on the side
-- away from the fade (the game's notifications: on their screen-edge side;
-- here the left), all round without a fade.
local function plate(tree, color, pad, faded)
    local b = W.new("Border", tree)
    pcall(function()
        local br = b.Background
        br.DrawAs = DRAW_ROUNDED
        br.OutlineSettings.RoundingType = ROUND_FIXED
        local r = br.OutlineSettings.CornerRadii   -- top left, top right, bottom right, bottom left
        local right = faded and 0 or L.RADIUS
        r.X, r.Y, r.Z, r.W = L.RADIUS, right, right, L.RADIUS
    end)
    pcall(function() b:SetBrushColor(color) end)
    pcall(function() b:SetPadding(pad) end)
    return b
end

local function build_field(tree)
    local f = W.new("MultiLineEditableText", tree)
    -- set before the widget is first shown (its Slate widget reads them then);
    -- the line has a fixed width, so wrapping at the width it got is right here
    pcall(function() f.AutoWrapText = true end)
    pcall(function() f.WrappingPolicy = WRAP_PER_CHAR end)
    pcall(function() f.ClearKeyboardFocusOnCommit = false end)
    pcall(function() f.SelectAllTextWhenFocused = false end)
    pcall(function() f.RevertTextOnEscape = false end)
    pcall(function() f.AllowContextMenu = false end)
    local fo = game_font()
    pcall(function()
        local s = f.WidgetStyle
        if fo then
            s.Font.FontObject = fo
            s.Font.TypefaceFontName = FName("Default")
        end
        s.Font.Size = SIZE_TEXT
        s.ColorAndOpacity = { SpecifiedColor = C.text, ColorUseRule = 0 }
        s.ShadowOffset = { X = 1, Y = 1 }
        s.ShadowColorAndOpacity = C.shadow
    end)
    pcall(function() f:SetFont(f.WidgetStyle.Font) end)
    -- Tab and the arrows must not take the keyboard away from the line
    for _, d in ipairs(NAV_DIRS) do pcall(function() f:SetNavigationRuleBase(d, NAV_STOP) end) end
    pcall(function() f:SetHintText(FText(T("chat_hint"))) end)
    return f
end

-- One feed row: [plate: nick, message (in a box that cuts one taller than
-- the feed's room), "not delivered"] [fade]. Its width follows its text.
local function build_row(tree)
    local hb = W.new("HorizontalBox", tree)
    local fb, fade = fade_end(tree, L.ROW_A)
    local bg = plate(tree, C.row_bg, margin(L.PAD, L.PAD, L.END_PAD, L.PAD), fb ~= nil)
    hadd(hb, bg, false, nil, VALIGN_FILL)
    if fb then hadd(hb, fb, false, nil, VALIGN_FILL) end
    local inner = W.new("HorizontalBox", tree)
    bg:SetContent(inner)
    local nick = text_block(tree, SIZE_TEXT, C.text)
    hadd(inner, nick, false, L.NICK_PAD, VALIGN_TOP)
    local msg = text_block(tree, SIZE_TEXT, C.text)
    wrap_fixed(msg, L.TEXT_W)
    local mbox = W.new("SizeBox", tree)
    pcall(function() mbox:SetMaxDesiredHeight(L.MSG_MAX_H) end)
    pcall(function() mbox:SetClipping(CLIP_BOUNDS) end)
    pcall(function() mbox.Clipping = CLIP_BOUNDS end)
    mbox:SetContent(msg)
    local ms = hadd(inner, mbox, false, L.TEXT_GAP, VALIGN_TOP)
    local mark = text_block(tree, SIZE_SIDE, C.mark)
    hadd(inner, mark, false, L.MARK_GAP, VALIGN_CENTER)
    set_vis(mark, VIS_COLLAPSED)
    return { box = hb, bg = bg, fade = fade, nick = nick, msg = msg, msg_box = mbox, msg_slot = ms, mark = mark,
             key = nil, alpha = nil, wrap = L.TEXT_W, max_h = L.MSG_MAX_H }
end

local function build()
    local gi = ue.game_instance()
    if not gi then error("no GameInstance") end
    local w = StaticConstructObject(W.umg("UserWidget"), gi)
    if not ue.valid(w) then error("cannot construct UMG.UserWidget") end
    local tree = StaticConstructObject(W.umg("WidgetTree"), w)
    if not ue.valid(tree) then error("cannot construct UMG.WidgetTree") end
    w.WidgetTree = tree
    local canvas = W.new("CanvasPanel", tree)
    tree.RootWidget = canvas
    pcall(function() canvas:SetVisibility(VIS_SELF_HIT_TEST_INVISIBLE) end)

    local root = W.new("VerticalBox", tree)
    local rs = canvas:AddChildToCanvas(root)
    pcall(function()
        rs:SetAnchors({ Minimum = { X = 0.0, Y = 1.0 }, Maximum = { X = 0.0, Y = 1.0 } })
        rs:SetAlignment({ X = 0.0, Y = 1.0 })
        rs:SetPosition({ X = L.POS_X, Y = L.POS_Y })
        rs:SetAutoSize(true)
    end)

    -- the feed: a row per message, each on its own plate (closed and open)
    local feed = W.new("VerticalBox", tree)
    local rows = {}
    for i = 1, HISTORY do
        local row = build_row(tree)
        vadd(feed, row.box, L.ROW_GAP)
        set_vis(row.box, VIS_COLLAPSED)
        rows[i] = row
    end
    vadd(root, feed, L.GAP)
    pcall(function() feed:SetVisibility(VIS_HIT_TEST_INVISIBLE) end)

    -- the input line: a fixed width (the text wraps inside it), the stronger plate
    local in_row = W.new("HorizontalBox", tree)
    local ifb = fade_end(tree, L.INPUT_A)
    local in_box = W.new("SizeBox", tree)
    pcall(function() in_box:SetWidthOverride(ifb and L.FEED_W - L.FADE_W or L.FEED_W) end)
    local in_bg = plate(tree, C.input_bg, margin(L.IN_PAD_L, L.IN_PAD_V, L.END_PAD, L.IN_PAD_V), ifb ~= nil)
    in_box:SetContent(in_bg)
    hadd(in_row, in_box, false, nil, VALIGN_FILL)
    if ifb then hadd(in_row, ifb, false, nil, VALIGN_FILL) end
    local ihb = W.new("HorizontalBox", tree)
    in_bg:SetContent(ihb)
    local field = build_field(tree)
    hadd(ihb, field, true, nil, VALIGN_CENTER)
    local side = text_block(tree, SIZE_SIDE, C.dim)
    hadd(ihb, side, false, 8, VALIGN_CENTER)
    set_vis(side, VIS_COLLAPSED)
    vadd(root, in_row)
    set_vis(in_row, VIS_HIDDEN)

    set_vis(root, VIS_COLLAPSED)
    w:AddToViewport(ZORDER)
    ui = { failed = ui.failed or 0, w = w, tree = tree, root = root, feed = feed, rows = rows,
           input = in_row, input_box = in_box, input_bg = in_bg, field = field, side = side, lang = i18n.language(),
           root_vis = VIS_COLLAPSED, input_vis = VIS_HIDDEN, side_text = nil }
    st.dirty = true
    log.info("chat: line and feed built (%d rows, game fade %s)", HISTORY, ifb and "yes" or "no")
end

-- The widget exists and is on screen (the game's RemoveAllWidgets at a death
-- takes it off: it goes back). false = not available.
local function ensure_widget()
    if (ui.failed or 0) >= 3 then return false end
    if ue.valid(ui.w) then
        if in_viewport(ui.w) then return true end
        if pcall(function() ui.w:AddToViewport(ZORDER) end) then
            ui.root_vis, ui.input_vis = nil, nil
            st.dirty = true
            log.debug("chat: back on screen")
            return true
        end
    end
    if not ue.local_pc() then return false end
    local ok, err = pcall(build)
    if not ok then
        local n = (ui.failed or 0) + 1
        ui = { failed = n }
        log.err("chat: line not built (%d/3): %s", n, tostring(err))
        return false
    end
    return true
end

local function render(now)
    st.dirty = false
    st.fading, st.next_render_at = false, nil
    if not ue.valid(ui.root) or not ui.rows then return end
    local open = st.open
    local rows = (open or st.feed_on) and visible(now, open) or {}
    local root_vis = (open or #rows > 0) and VIS_SELF_HIT_TEST_INVISIBLE or VIS_COLLAPSED
    if ui.root_vis ~= root_vis then
        ui.root_vis = root_vis
        set_vis(ui.root, root_vis)
    end
    local input_vis = open and VIS_VISIBLE or VIS_HIDDEN
    if ui.input_vis ~= input_vis then
        ui.input_vis = input_vis
        set_vis(ui.input, input_vis)
    end
    local k = #rows
    local first = #ui.rows - k
    local max_h = msg_max_h(open)
    for i, row in ipairs(ui.rows) do
        local m = i > first and rows[i - first] or nil
        if not m then
            if row.key ~= false then
                row.key = false
                set_vis(row.box, VIS_COLLAPSED)
            end
        else
            local e = m.e
            local key = e.seq .. (e.failed and "f" or "") .. ui.lang
            if row.key ~= key then
                if row.key == false or row.key == nil then set_vis(row.box, VIS_HIT_TEST_INVISIBLE) end
                row.key = key
                if e.sys then
                    set_vis(row.nick, VIS_COLLAPSED)
                    pcall(function() row.msg_slot:SetPadding(margin(L.NICK_PAD, 0, 0, 0)) end)
                else
                    set_vis(row.nick, VIS_HIT_TEST_INVISIBLE)
                    set_text(row.nick, e.nick)
                    set_color(row.nick, e.color)
                    pcall(function() row.msg_slot:SetPadding(margin(L.TEXT_GAP, 0, 0, 0)) end)
                end
                local wrap = msg_wrap(e)
                if row.wrap ~= wrap then
                    row.wrap = wrap
                    set_wrap(row.msg, wrap)
                end
                set_text(row.msg, e.text)
                set_color(row.msg, (e.sys and C.dim) or (e.failed and C.failed) or C.text)
                if e.failed then set_text(row.mark, T("chat_undelivered")) end
                set_vis(row.mark, e.failed and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
            end
            if row.max_h ~= max_h then
                row.max_h = max_h
                pcall(function() row.msg_box:SetMaxDesiredHeight(max_h) end)
            end
            local a = math.floor(m.alpha * 50 + 0.5) / 50
            if row.alpha ~= a then
                row.alpha = a
                pcall(function() row.box:SetRenderOpacity(a) end)
            end
            if not open then
                if m.alpha < 1 then
                    st.fading = true
                else
                    local at = e.shown_at + e.life
                    if not st.next_render_at or at < st.next_render_at then st.next_render_at = at end
                end
            end
        end
    end
end

-- The right end of the input line: "not so fast", else the characters left.
local function update_side(now, len)
    if not ue.valid(ui.side) then return end
    local s
    if now < st.note_until then s = T("chat_slow")
    elseif len and MAX_CHARS - len <= COUNT_FROM then s = tostring(math.max(0, MAX_CHARS - len))
    end
    if s == ui.side_text then return end
    ui.side_text = s
    if s then set_text(ui.side, s) end
    set_vis(ui.side, s and VIS_HIT_TEST_INVISIBLE or VIS_COLLAPSED)
end

local function field_text()
    if not ue.valid(ui.field) then return "" end
    local ok, t = pcall(function() return ui.field:GetText() end)
    return ok and ue.str(t) or ""
end

local function set_field(s)
    if ue.valid(ui.field) then set_text(ui.field, s or "") end
end

-- ---------------------------------------------------------------------------
-- Input: take / give back
-- ---------------------------------------------------------------------------

local function take_input(pc, first)
    local wbl = ue.widget_lib()
    if wbl then pcall(function() wbl:SetInputMode_UIOnlyEx(pc, ui.field, 0, first == true) end) end
    -- only right after opening (a retry never hides a cursor someone showed)
    if first then pcall(function() pc.bShowMouseCursor = false end) end
    pcall(function() ui.field:SetKeyboardFocus() end)
end

-- The character stops: auto-run off, a car this machine drives lets go.
local function stop_moving(pawn)
    if ue.prop(pawn, "AutoRun?") == true then ue.set_prop(pawn, "AutoRun?", false) end
    if ue.prop(pawn, "InVehicle?") ~= true then return end
    local dc = ue.prop(pawn, "VehicleDrivingComponent")
    local v = ue.valid(dc) and ue.prop(dc, "Vehicle") or nil
    local m = ue.valid(v) and ue.prop(v, "VehicleMovementComponent") or nil
    if not ue.valid(m) then return end
    -- a copy driven by the replicated inputs (someone else drives): untouched
    if ue.prop(m, "bRequiresControllerForInputs") == true then return end
    pcall(function() m:SetThrottleInput(0) end)
    pcall(function() m:SetSteeringInput(0) end)
    pcall(function() m:SetBrakeInput(0) end)
end

-- Game controls back after the line closed - only when nobody else holds
-- the input now (review 2026-11-13: a close nobody took the input over from
-- left the UI-only mode on: no walking, no camera, no pause menu).
local function give_back(why)
    st.restore_at, st.restore_why = nil, nil
    st.restore_console = false
    if st.open or not st.owns then return end
    local pc = ue.local_pc()
    if not pc then st.owns = false return end
    local pawn = ue.pawn_of(pc)
    local other = (cursor_on(pc) and "the cursor") or (panel_open() and "the co-op panel")
        or ((not pawn or dead(pawn)) and "death") or death_screen() or game_window()
    if other then
        st.owns = false
        log.debug("chat: input left as it is after the line closed (%s holds it)", other)
        return
    end
    if console_open() then
        st.restore_console = true
        log.debug("chat: game controls back once the console closes")
        return
    end
    st.owns = false
    W.game_input(pc, "chat line closed: " .. tostring(why))
end

-- mode: "now" (give the input back now), "esc" (after ESC_GIVE_BACK_S),
-- "keep" (something else holds it: untouched). keep_draft: the typed text
-- comes back at the next open.
local function close(why, mode, keep_draft)
    if not st.open then return end
    local now = clock()
    if keep_draft then
        local raw = field_text():gsub("[\r\n]+", " ")
        st.draft = clean_text(raw, MAX_CHARS, false)
    else
        st.draft = nil
    end
    st.open = false
    st.closed_at = now
    st.nofocus_since = nil
    st.input_lines = 1
    set_field("")
    local p = st.poll
    if (why == "sent" or why == "enter") and st.key_name == "Enter" then
        p.armed, p.saw_down = false, false     -- fallback read: the Enter that closed it let go first (it repeats)
    else
        p.armed, p.was_down, p.saw_down = true, true, false
    end
    -- a hidden field must not keep the keyboard (also when the input is not
    -- given back below: something else holds it)
    if has_focus(ui.field) then
        local wbl = ue.widget_lib()
        if wbl then pcall(function() wbl:SetFocusToGameViewport() end) end
    end
    log.debug("chat: closed (%s)", why)
    if mode == "now" then
        give_back(why)
    elseif mode == "esc" then
        st.restore_at, st.restore_why = now + ESC_GIVE_BACK_S, why
    else
        st.owns = false
        st.restore_at, st.restore_console = nil, false
    end
    st.dirty = true
    render(now)
end

-- What keeps the line from opening now (live: the 250 ms flags may be old).
local function open_blocker(pc)
    if not st.allowed then return "not allowed" end
    if cursor_on(pc) then return "cursor" end
    if panel_open() then return "panel" end
    local pawn = ue.pawn_of(pc)
    if not pawn then return "no character" end
    if dead(pawn) then return "dead" end
    if cover_on() then return "join cover" end
    local ds = death_screen()
    if ds then return ds end
    local gw = game_window()
    if gw then return gw end
    if console_open() then return "console" end
    if alt_down(pc) then return "Alt" end
    return nil
end

local function try_open(now)
    local pc = ue.local_pc()
    if not pc then return false end
    local why = open_blocker(pc)
    if why then
        log.debug("chat: key not taken (%s)", why)
        return false
    end
    if not ensure_widget() or not ue.valid(ui.field) or not in_viewport(ui.w) then return false end
    -- open first: sdc_widgets.game_window_open answers "the chat" from here
    st.open, st.owns = true, true
    st.opened_at = now
    st.restore_at, st.restore_why, st.restore_console = nil, nil, false
    st.nofocus_since, st.focus_try_at, st.focus_logged = nil, now, false
    st.note_until = 0
    ui.side_text = false
    st.open_text = st.draft or ""
    st.last_text = st.open_text
    st.input_lines = field_lines(st.open_text)
    set_field(st.open_text)
    for _, e in ipairs(st.hist) do e.unseen = nil end
    st.dirty = true
    render(now)
    take_input(pc, true)
    stop_moving(ue.pawn_of(pc))
    update_side(now, ulen(st.draft))
    M.stats.opened = M.stats.opened + 1
    log.debug("chat: opened")
    return true
end

-- ---------------------------------------------------------------------------
-- Sending and receiving
-- ---------------------------------------------------------------------------

local function host_self()
    return my_id(), clean_name(cfg.player_name())
end

-- Host: CHATM to every chat peer (the author included). Returns the count.
local function relay(id, name, text)
    local n = 0
    for _, r in ipairs(chat_peers()) do
        if net.send_to(r.pc, "CHATM", tostring(id or ""), esc(name), esc(text)) then n = n + 1 end
    end
    M.stats.relayed = M.stats.relayed + n
    return n
end

local function sound(now)
    if cfg.get("chat_sound") == false or now - st.last_sound < SOUND_GAP_S then return end
    local snd = ue.find_object(CLICK_PATH)
    if not snd then
        once("sound", "chat: the game's click sound is not in memory: no message sound")
        return
    end
    local gps = ue.gameplay_statics()
    local pc = ue.local_pc()
    if not gps or not pc then return end
    st.last_sound = now
    pcall(function() gps:PlaySound2D(pc, snd, SOUND_VOL, 1.0, 0.0, nil, nil, true) end)
end

-- Own message (already clean). false = over the rate (nothing sent).
local function send_own(now, text)
    if not take(st.own_rate, now, RATE.own) then return false end
    local h, len = hash(text), ulen(text)
    M.stats.sent = M.stats.sent + 1
    if S.role == "host" then
        local id, name = host_self()
        add_entry({ id = id, name = name, text = text, own = true, hash = h }, now)
        local n = relay(id, name, text)
        log.info("chat: sent len=%d hash=%s -> %d players", len, h, n)
    else
        net.send_to_host("CHAT", esc(text))
        st.pending[#st.pending + 1] = { hash = h, len = len, text = text, at = now }
        log.info("chat: sent len=%d hash=%s", len, h)
    end
    return true
end

local function not_delivered(p, now)
    M.stats.undelivered = M.stats.undelivered + 1
    add_entry({ id = my_id(), name = clean_name(cfg.player_name()), text = p.text, own = true, failed = true,
                hash = p.hash }, now)
    log.info("chat: not delivered len=%d hash=%s (no copy back from the host in %d s)", p.len, p.hash, PENDING_S)
end

-- Host: CHAT|<text> from a client.
local function on_chat(f, pc)
    if not S or S.role ~= "host" then return end
    local now = clock()
    local r = S.remote and S.remote[ue.name(pc)]
    local id = r and ue.valid(r.pc) and ps_id(r.pc) or nil
    if not admitted(r) then return drop(id, "not admitted") end
    local text, why = clean_text(unesc(f[1] or ""), MAX_CHARS, true)
    if not text then return drop(id, why) end
    local g = guest_rate[r.key]
    if not g or g.rec ~= r then
        g = { rec = r, b = {} }
        guest_rate[r.key] = g
    end
    if not take(g.b, now, RATE.guest) then return drop(id, "rate") end
    -- it has the chat (its CHATON may still be on the way)
    local p = peers[r.key]
    if not p or p.rec ~= r then
        p = { rec = r, want = true }
        peers[r.key] = p
    end
    p.ok = true
    local name = display_name(r)
    local n = relay(id, name, text)
    log.info("chat: from id=%s len=%d hash=%s -> %d players", tostring(id or "?"), ulen(text), hash(text), n)
    if chat_on() then
        add_entry({ id = id, name = name, text = text }, now)
        sound(now)
    end
end

-- Client: CHATM|<id>|<name>|<text> from the host.
local function on_chatm(f)
    if not S or S.role ~= "client" or not chat_on() then return end
    local now = clock()
    local id = tonumber(f[1] or "")
    local name = clean_text(unesc(f[2] or ""), NAME_MAX, true) or "?"
    local text = clean_text(unesc(f[3] or ""), MAX_CHARS, true)
    if not text then return end
    local h = hash(text)
    local me = my_id()
    local pi = nil
    for i, p in ipairs(st.pending) do
        if p.hash == h then pi = i break end
    end
    if (me ~= nil and id == me) or (me == nil and pi) then
        if pi then
            table.remove(st.pending, pi)
        else
            -- a copy after "not delivered": that line is fixed, no second one
            for i = #st.hist, 1, -1 do
                local e = st.hist[i]
                if e.own and e.failed and e.hash == h then
                    e.failed, e.name, e.id = false, name, id
                    e.nick, e.color = nick_shown(name), nick_color(id)
                    e.nick_w = text_w(e.nick, SIZE_TEXT)
                    st.dirty = true
                    return
                end
            end
        end
        add_entry({ id = id, name = name, text = text, own = true, hash = h }, now)
        return
    end
    add_entry({ id = id, name = name, text = text, hash = h }, now)
    sound(now)
end

-- CHATON both ways.
local function on_chaton(f, pc)
    if not S then return end
    if S.role == "host" then
        local key = ue.name(pc)
        local r = S.remote and S.remote[key]
        if not r then return end
        local p = peers[key]
        if not p or p.rec ~= r then
            p = { rec = r, ok = false }
            peers[key] = p
        end
        p.want = f[2] ~= "0"
        if admitted(r) then
            if not p.ok then log.info("chat: player id=%s has the chat", tostring(ps_id(r.pc) or "?")) end
            p.ok = true
            net.send_to(r.pc, "CHATON", PROTO)
        end
    elseif S.role == "client" then
        local cs = client_sync()
        if not cs then return end
        if not cl.host_ok then log.info("chat: the host has the chat") end
        cl.host_ok = true
    end
end

-- ---------------------------------------------------------------------------
-- Frame (while the line is open, or the key may open it)
-- ---------------------------------------------------------------------------

local function cont(b) return b ~= nil and b >= 0x80 and b < 0xC0 end

-- What changed in the line since a frame ago: the text both share at the
-- start, what came in between, the text both share at the end (whole
-- characters each).
local function diff(old, new)
    local n = math.min(#old, #new)
    local p = 0
    while p < n and old:byte(p + 1) == new:byte(p + 1) do p = p + 1 end
    while p > 0 and cont(new:byte(p + 1)) do p = p - 1 end
    local s = 0
    while s < n - p and old:byte(#old - s) == new:byte(#new - s) do s = s + 1 end
    while s > 0 and cont(new:byte(#new - s + 1)) do s = s - 1 end
    return new:sub(1, p), new:sub(p + 1, #new - s), new:sub(#new - s + 1)
end

-- The message once a line break is in the line (old: the text a frame ago).
-- Typed (at most TYPED_MAX other characters came with the break this
-- frame): Enter where the caret was - the text without that break, what was
-- typed after it this frame dropped (review 2026-11-13: "приве|т" + Enter
-- sent "приве т"). A paste (more): every line break a space.
local function message_of(old, new)
    local pre, ins, suf = diff(old, new)
    local at = ins:find("[\r\n]")
    if at then
        local _, others = ins:gsub("[^\r\n\128-\191]", "")
        if others <= TYPED_MAX then return pre .. ins:sub(1, at - 1) .. suf end
    end
    return (new:gsub("[\r\n]+$", ""):gsub("[\r\n]+", " "))
end

-- A line break typed or pasted: send (or close on an empty line).
local function on_newline(now, raw)
    local plain = raw:gsub("[\r\n]", "")
    local since = now - st.opened_at
    if since < OPEN_GUARD_S and plain == st.open_text and (plain == "" or since >= REPEAT_MIN_S) then
        -- nothing typed since the line opened: the opening key repeating
        -- (a draft: before REPEAT_MIN_S it is a second press, which sends it)
        set_field(plain)
        st.last_text = plain
        return
    end
    local body = message_of(st.last_text, raw)
    local text = clean_text(body, MAX_CHARS, false)
    if not text then return close("enter", "now", false) end
    if not send_own(now, text) then
        set_field(body)
        st.last_text = body
        st.note_until = now + NOTE_S
        update_side(now, ulen(body))
        return
    end
    close("sent", "now", false)
end

-- No keyboard focus on the line (a click elsewhere, Alt-Tab, a mode switch).
local function guard(now, pc)
    if not st.nofocus_since then st.nofocus_since = now end
    if now - st.focus_try_at < REFOCUS_S then return end
    st.focus_try_at = now
    local why = (panel_open() and "the co-op panel") or (cover_on() and "the join cover") or death_screen()
        or game_window() or (console_open() and "the console")
    if why then
        log.info("chat: focus lost (%s), closed", why)
        return close(why, why == "the console" and "now" or "keep", true)
    end
    if not in_viewport(ui.w) then
        log.info("chat: focus lost (the line went off screen), closed")
        return close("off screen", "now", true)
    end
    if now - st.nofocus_since >= NOFOCUS_GIVE_UP_S then
        log.info("chat: focus lost (no keyboard focus for %d s), closed", NOFOCUS_GIVE_UP_S)
        return close("no focus", "now", true)
    end
    if not st.focus_logged then
        st.focus_logged = true
        log.info("chat: focus lost (%s), refocus", now - st.opened_at < 0.5 and "right after opening" or "while typing")
    end
    M.stats.refocus = M.stats.refocus + 1
    take_input(pc, false)
end

local function open_frame(now)
    local pc = ue.local_pc()
    if not pc then return close("no controller", "keep", true) end
    -- whatever shows the cursor (inventory, map, F7, a death screen) holds the input now
    if cursor_on(pc) then return close("cursor", "keep", true) end
    local pawn = ue.pawn_of(pc)
    if not pawn or dead(pawn) then return close("dead", "keep", true) end
    if not ue.valid(ui.field) then return close("widget gone", "now", true) end
    if has_focus(ui.field) then
        st.nofocus_since = nil
    else
        guard(now, pc)
        if not st.open then return end
    end
    local text = field_text()
    if text:find("[\r\n]") then return on_newline(now, text) end
    local len = ulen(text)
    if len > MAX_CHARS then
        text = cut(utf8_fix(text), MAX_CHARS)
        set_field(text)
        len = MAX_CHARS
    end
    st.last_text = text
    local lines = field_lines(text)
    if lines ~= st.input_lines then
        st.input_lines = lines
        st.dirty = true   -- the input line grew or shrank: the feed's room too
    end
    update_side(now, len)
end

-- A press of the chat key the game got (see the header: a real press, not a
-- held key's auto-repeat). Fallback when that call fails: the key's down
-- edge, a key held through an Enter close let go first.
local function key_pressed(pc, now)
    local p = st.poll
    if not p.edge then
        local jp = ue.try(function() return pc:WasInputKeyJustPressed(st.key) end)
        if type(jp) == "boolean" then return jp end
        -- from now on the key's down edge: its state now is the start (a key
        -- already down is no press; review 2026-11-13: "down" assumed here
        -- ate the first press after the switch)
        p.edge, p.armed, p.saw_down = true, true, false
        p.was_down = key_down(pc, st.key)
        log.warn("chat: WasInputKeyJustPressed failed: the chat key is read by its down state")
        return false
    end
    local down = key_down(pc, st.key)
    if not p.armed then
        if down then
            p.saw_down = true
        elseif p.saw_down or now - st.closed_at >= REARM_S then
            p.armed = true
        end
        p.was_down = down
        return false
    end
    local pressed = down and not p.was_down
    p.was_down = down
    return pressed
end

local function poll_key(now)
    local pc = ue.local_pc()
    if not pc then return end
    if not key_pressed(pc, now) then return end
    if st.allowed then
        try_open(now)
    elseif st.hint_poll and now - st.last_hint >= HINT_EVERY_S and not cursor_on(pc) and not alt_down(pc) then
        -- a client of a host whose mod has no chat: say why Enter does nothing
        st.last_hint = now
        if ensure_widget() then
            add_entry({ sys = true, text = T("chat_old_host") }, now)
            render(now)
        end
    end
end

-- An Esc held after it closed the line. Its auto-repeat starts after the
-- keyboard's repeat delay (Windows: 0.25-1 s); repeats that come once the
-- game has its input back press the game's IA_PauseMenu (Enhanced Input
-- sees the key go down) -> HUD Client_PauseGame(true): PauseScreen_C on
-- screen with the keyboard, UI-only input, cursor, the character's input
-- off (BP_Ingame / HUD_Game @300-761). The menu's OnKeyDown closes it on
-- Esc, repeats too (PauseScreen EscapePressed -> Client_PauseGame(false)),
-- and the key was let go in the game when the menu took the keyboard: held
-- on, the repeats open and close it in turn until the key is let go, which
-- leaves it open or not. UE4SS reports every new Esc press (on_esc), a held
-- key never again, and the release cannot be seen while the game has no
-- input. So a pause menu that stays on screen (PAUSE_SETTLE_S) within
-- ESC_GUARD_S of the closing Esc - or within ESC_HOLD_S of the last time it
-- came back - with no new Esc press since, is the held key's: it is closed as
-- the game closes it (Client_PauseGame(false) @762-1099: RemoveFromParent,
-- game input, cursor off, the character's input on; SetGamePaused only in
-- single player, where the chat is off) - engine functions only, no
-- Blueprint call - and the guard stays on (still held: the next repeat opens
-- it again). A new press (on_esc while closed) ends the guard: that pause
-- menu stays; so does a cursor without a pause menu (inventory, map).
local function pause_screen()
    for _, w in ipairs(ue.find_all("PauseScreen_C")) do
        if in_viewport(w) then return w end
    end
    return nil
end

local function esc_guard(now)
    local g = st.esc_guard
    if g.fresh or now >= (g.limit or math.huge) or (now >= g.until_at and not g.seen_at) then
        st.esc_guard = nil
        return
    end
    local pc = ue.local_pc()
    if not pc then return end
    -- the pause menu shows the cursor: only then is it looked for (a scan of
    -- every object), once it stays
    if not cursor_on(pc) then
        g.seen_at = nil
        return
    end
    if not g.seen_at then
        g.seen_at = now
        -- (back again: the key is still held) the guard lasts while it comes back
        g.until_at = math.max(g.until_at, now + ESC_HOLD_S)
    end
    if now - g.seen_at < PAUSE_SETTLE_S then return end
    g.seen_at = nil
    local w = pause_screen()
    if not w then
        st.esc_guard = nil     -- another window showed the cursor (inventory, map): left alone
        return
    end
    pcall(function() w:RemoveFromParent() end)
    local wbl = ue.widget_lib()
    if wbl then pcall(function() wbl:SetInputMode_GameOnly(pc, false) end) end
    pcall(function() pc.bShowMouseCursor = false end)
    local pawn = ue.pawn_of(pc)
    if pawn then pcall(function() pawn:EnableInput(pc) end) end
    -- the guard stays on (until ESC_HOLD_S after this menu came): still
    -- held, the key's next repeat opens it again
    M.stats.unpaused = M.stats.unpaused + 1
    if M.stats.unpaused <= 3 or M.stats.unpaused % 20 == 0 then
        log.info("chat: the pause menu that the Esc held after closing the line opened is closed again (%d)",
            M.stats.unpaused)
    end
end

-- main.lua's frame loop (game thread), while M.frame_wanted().
function M.frame_tick()
    local now = clock()
    if st.restore_at and now >= st.restore_at then give_back(st.restore_why or "esc") end
    if st.esc_guard then esc_guard(now) end
    if st.open then
        open_frame(now)
    elseif st.allowed or st.hint_poll then
        poll_key(now)
    end
    if st.dirty or st.fading or (st.next_render_at and now >= st.next_render_at) then render(now) end
end

-- A plain field read: frame_tick has work this frame.
function M.frame_wanted()
    return st.open or st.allowed or st.hint_poll or st.dirty or st.fading or st.restore_at ~= nil
        or st.next_render_at ~= nil or st.esc_guard ~= nil
end

-- main.lua: Esc (KEYS.chat_esc from the UE4SS bind: every new press, never
-- a held key's repeat). An open line closes (without the keyboard here -
-- another copy of the game on this PC has it - it keeps its text) and the
-- held-Esc guard starts; with the line closed it is a new press: the guard
-- ends (the pause menu it opens is wanted).
function M.on_esc()
    if not st.open then
        if st.esc_guard then st.esc_guard.fresh = true end
        return
    end
    local now = clock()
    st.esc_guard = { until_at = now + ESC_GUARD_S, limit = now + ESC_GUARD_MAX_S }
    if has_focus(ui.field) then close("esc", "esc", false) else close("esc", "esc", true) end
end

-- sdc_ui: the co-op panel opens (it takes the input itself).
function M.close(why)
    close(why or "panel", "keep", true)
end

function M.is_open() return st.open end

-- sdc_widgets.game_window_open: the line holds the keyboard (open, no cursor).
function M.holds_input()
    if not st.open then return false end
    local pc = ue.local_pc()
    return pc ~= nil and not cursor_on(pc)
end

-- ---------------------------------------------------------------------------
-- 250 ms tick
-- ---------------------------------------------------------------------------

local function host_tick()
    local remote = S.remote or {}
    for key, p in pairs(peers) do
        local r = remote[key]
        if r ~= p.rec then
            peers[key] = nil
        elseif not p.ok and admitted(r) then
            -- it asked while it waited for the host's answer / its password
            p.ok = true
            net.send_to(r.pc, "CHATON", PROTO)
            log.info("chat: player id=%s has the chat", tostring(ps_id(r.pc) or "?"))
        end
    end
    for key, g in pairs(guest_rate) do
        if remote[key] ~= g.rec then guest_rate[key] = nil end
    end
end

local function client_tick(now)
    local cs = client_sync()
    if not cs or not cs.acked then return end
    local want = chat_on() and "1" or "0"
    if cl.host_ok then
        if cl.sent_want ~= want then
            cl.sent_want = want
            net.send_to_host("CHATON", PROTO, want)
        end
        return
    end
    if cs.access == "wait" then return end
    if (cl.asks or 0) < ASK_MAX and (not cl.ask_at or now - cl.ask_at >= ASK_EVERY_S) then
        cl.asks = (cl.asks or 0) + 1
        cl.ask_at = now
        cl.first_ask_at = cl.first_ask_at or now
        cl.sent_want = want
        net.send_to_host("CHATON", PROTO, want)
    end
end

local function key_setting()
    local name = tostring(cfg.get("chat_key") or "Enter"):gsub("%s+", "")
    if name == "" then name = "Enter" end
    if name ~= st.key_name then
        st.key_name = name
        st.key = { KeyName = FName(name) }
        st.poll.was_down = true
        if GAME_KEYS[name] then
            log.warn("chat: key '%s' is also a game key (IMC_General): the game's action runs too", name)
        end
    end
end

-- How the screen is: nil + why when the feed / line cannot show.
local function screen(pc)
    if not pc then return nil, "no controller" end
    if ue.in_main_menu() then return nil, "menu" end
    local pawn = ue.pawn_of(pc)
    if not pawn then return nil, "no character" end
    if dead(pawn) then return nil, "dead" end
    if cursor_on(pc) then return nil, "cursor" end
    if panel_open() then return nil, "panel" end
    if cover_on() then return nil, "join cover" end
    local hud = ue.prop(pawn, "InGameUI")
    local hidden = false
    if ue.valid(hud) then
        local ok, v = pcall(function() return hud:GetVisibility() end)
        hidden = ok and (v == VIS_COLLAPSED or v == VIS_HIDDEN)
    end
    return { pc = pc, pawn = pawn, hud_hidden = hidden }
end

function M.tick()
    if not S then return end
    local now = clock()
    key_setting()
    local role = S.role
    if role ~= "host" and role ~= "client" then
        -- single player / the menu: nothing runs, nothing is built
        if st.open then close("no session", "keep", true) end
        st.allowed, st.session_ok, st.hint_poll = false, false, false
        if st.feed_on then
            st.feed_on = false
            render(now)
        end
        return
    end
    if role == "host" then host_tick() else client_tick(now) end
    local on = chat_on()
    local partners = role == "host" and #chat_peers() > 0 or (role == "client" and client_ok())
    st.session_ok = on and partners
    st.hint_poll = on and role == "client" and old_host(now)
    -- own messages the host never copied back
    -- (oldest first: past PENDING_MAX the oldest goes, not the newest)
    local i = 1
    while i <= #st.pending do
        local p = st.pending[i]
        if now - p.at >= PENDING_S or #st.pending > PENDING_MAX then
            table.remove(st.pending, i)
            not_delivered(p, now)
        else
            i = i + 1
        end
    end
    local wanted = st.session_ok or st.hint_poll or ue.valid(ui.w)
    local sc, why = nil, "off"
    if wanted then sc, why = screen(ue.local_pc()) end
    st.allowed = st.session_ok and sc ~= nil
    if st.open then
        if not st.session_ok then
            close(on and "alone" or "chat off", "now", true)
        elseif not sc then
            -- something else holds the screen (the frame loop sees most of it first)
            close(why, "keep", true)
        elseif console_open() then
            close("console", "now", true)
        end
    end
    if st.restore_console and not console_open() then give_back("console closed") end
    if (st.session_ok or st.hint_poll) and sc then ensure_widget() end
    if ue.valid(ui.field) and ui.lang ~= i18n.language() then
        ui.lang = i18n.language()
        pcall(function() ui.field:SetHintText(FText(T("chat_hint"))) end)
        ui.side_text = false
        st.dirty = true
    end
    local feed_on = on and sc ~= nil and not sc.hud_hidden
    if feed_on ~= st.feed_on then
        st.feed_on = feed_on
        if feed_on then surface(now) end
        st.dirty = true
    end
    if st.dirty then render(now) end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

-- Level change (sdc_session.reset_world): the old world's widget and
-- controller go with it; history, draft and handshakes too.
function M.reset(why)
    if why == "loadmap" and ue.valid(ui.w) then pcall(function() ui.w:RemoveFromParent() end) end
    ui = { failed = ui.failed or 0 }
    st.open, st.owns = false, false
    st.restore_at, st.restore_why, st.restore_console = nil, nil, false
    st.esc_guard, st.input_lines = nil, 1
    st.draft, st.hist, st.pending = nil, {}, {}
    st.allowed, st.session_ok, st.feed_on, st.hint_poll = false, false, false, false
    st.dirty, st.fading, st.next_render_at = false, false, nil
    st.poll.armed, st.poll.was_down, st.poll.saw_down = true, true, false
    peers, guest_rate, cl = {}, {}, {}
end

function M.status_line()
    local np = 0
    for _ in pairs(peers) do np = np + 1 end
    local s = M.stats
    return string.format("chat: %s key=%s role=%s allowed=%s open=%s peers=%d host_ok=%s hist=%d pending=%d | "
        .. "sent=%d shown=%d relayed=%d dropped=%d undelivered=%d opened=%d refocus=%d",
        chat_on() and "on" or "off", tostring(st.key_name), tostring(S and S.role), tostring(st.allowed),
        tostring(st.open), np, tostring(cl.host_ok == true), #st.hist, #st.pending,
        s.sent, s.shown, s.relayed, s.dropped, s.undelivered, s.opened, s.refocus)
end

function M.install(state)
    S = state
    net.on("CHATON", on_chaton)
    net.on("CHAT", on_chat)
    net.on("CHATM", on_chatm)
    -- never in the network debug log (sdc_net keeps its own list too)
    net.SECRET.CHAT, net.SECRET.CHATM = true, true
    -- not behind a world snapshot in the send queue: rare and small
    net.NOW.CHAT, net.NOW.CHATM, net.NOW.CHATON = true, true, true
    key_setting()
    log.info("chat: %s (key %s, sound %s)", chat_on() and "on" or "off", tostring(st.key_name),
        cfg.get("chat_sound") == false and "off" or "on")
end

-- tests
M._t = {
    st = st, clean_text = clean_text, esc = esc, unesc = unesc, hash = hash, skeleton = skeleton,
    display_name = display_name, visible = visible, life_of = life_of, take = take, cut = cut,
    nick_shown = nick_shown, message_of = message_of, diff = diff, chat_peers = chat_peers,
    text_w = text_w, lines_of = lines_of, msg_wrap = msg_wrap, est_height = est_height, feed_cap = feed_cap,
    msg_max_h = msg_max_h,
    input_h = input_h, field_lines = field_lines,
    peers = function() return peers end, cl = function() return cl end, ui = function() return ui end,
    RATE = RATE, MAX_CHARS = MAX_CHARS, L = L, SIZE_TEXT = SIZE_TEXT, SIZE_SIDE = SIZE_SIDE, NAME_MAX = NAME_MAX,
    NICK_SHOWN = NICK_SHOWN, PENDING_MAX = PENDING_MAX, ESC_GUARD_S = ESC_GUARD_S, PAUSE_SETTLE_S = PAUSE_SETTLE_S,
    ESC_HOLD_S = ESC_HOLD_S, OPEN_GUARD_S = OPEN_GUARD_S, REPEAT_MIN_S = REPEAT_MIN_S,
}

return M
