-- SDCoop: items the host gives a client go where THAT client's screen puts
-- them; items its screen can never show are taken out of hiding.
-- Driven by sdc_consume (init / register_handlers / host_tick / host_player /
-- reset; its host hooks on SERVER_RequestDataFromSave and JigMP_OnRequestDropItem).
--
-- Why. A client's inventory lives on the host (its JigS data, the client's
-- character is the host's); the client's windows show it. The plugin's
-- server-side add (AddNewItemSomewhere) takes the first grid of the host's
-- data with room whose OWNER ITEM allows the item. The special containers
-- (wallet, med bag, lunch box, toolboxes, ammo tin, briefcase, weapons case,
-- the plate carriers' pouches...: DA_* with SpecialContainerWidget SC_*)
-- allow anything there - but their WINDOW takes only some kinds. The client
-- never shows such an item, and the next rebuild of that window (a rejoin:
-- CLIENT_ContainerDataResponse -> BuildDataToContainer @1058-1145; the bag
-- taken off and put on: SetupNewAddedItem @1532-1619) asks the host to remove
-- it (SERVER_RequestRemoveItem -> HandleLocalRequestConsumeItem): gone for
-- good. 2026-11-13: a loot box's Katana, a can and an empty bottle in a
-- client's wallet; a gun locker picked up into a med bag; at a join the
-- client's game removed Rock x31 from its med bag 0.3 s after the restore.
--
-- 1. Host grants (WHERE). Server-side game code giving a remote player an item
-- finds no window on the host and drops it at the player's feet (the water
-- well, fishing: sdc_consume.on_host_add); sdc_world's own grants without a
-- word from that screen (a picked-up buildable, salvage, a world resource)
-- leave or make such a drop too. The host asks that client WHERE|id|item|count;
-- the client asks its own windows exactly as single player does
-- (sdc_consume.client_spot: JigTryAddGetPendingRef - the slot its widgets
-- reserve, the stack it would grow, or no room), drops the reservation and
-- answers WHEREIS|id|c|grid|slot  /  s|stack  /  n  /  ?. The host adds there
-- (sdc_consume.place, the IGAIN placement) and only THEN removes the pickup.
-- Until it is in the inventory the item is only that pickup: an answer that
-- never comes loses or doubles nothing. The pickup counts as taken when the
-- engine says it is gone (M.live: UE4SS's own IsValid stays true for a
-- destroyed actor until the garbage collector - sdc_sweepguard.live asks
-- KismetSystemLibrary.IsValid; a destroyed actor also reads 0,0,0).
--   no room on that screen, no answer within WAIT_S, the pickup taken, the
--   character dead (its data is the death box's by then): the pickup stays.
--   the place the screen named full on the host (several grants in one frame
--   all name the same grid: the client gives up each reservation before the
--   next question): asked once more REASK_S later, when the earlier items
--   show on that screen; then the pickup stays. An IGAIN the host cannot put
--   where the screen said goes the same way (sdc_consume.grant: dropped, then
--   asked later, its default attachments kept).
--
-- 2. Hidden items (rescue). Each SC_ window lists its grids (AllContainers =
-- GetListOfContainers, in the order of the owner item's SubContainers:
-- SetupNewAddedItem @1230-1308); a grid's JSIContainer takes an item by
-- JSIContainer.IsSupportedType? @0-428 (AlsoSupportTheseItems; then not a
-- NotSupportedItemTypes tag; then SupportedItemTypes - HasTag exact - and
-- IsSupportedID?: OnlySupportTheseItems / DoNotSupportTheseItems). RULES is
-- that data, per window class and grid, read from the game's files (0.8.0:
-- Inventory/Widgets/Equipment/**/SC_*.uasset+uexp; an item data asset with
-- no ItemType of its own has the class default Jig.ItemType.Other). An item
-- of a remote player's data in such a grid that the window refuses is
-- dropped at the player's feet with the plugin's own drop
-- (SERVER_RequestDropItem: the pickup keeps the item and what is inside it).
-- That drop takes the item out of the data even when no pickup comes
-- (HandleServerDropRequest @1164 -> 1456; the actor is looked at only
-- @1572), so: never an item whose data asset has no PickupClass, none whose
-- drop failed lately (NODROP_S), and the player is told "at your feet" only
-- when that drop's own JigMP_OnRequestDropItem made a pickup of it
-- (sdc_consume's post-hook -> M.note_drop, inside the drop's mark); no
-- pickup: the item is reported lost; one that stays hidden (no pickup class,
-- a drop refused or failing lately): the player is told the game will remove
-- it. When:
--   sdc_persist's restore, after its count check (also its item-list
--   rebuild): its own load is marked (M.loading) - a load hook taking items
--   out before that check would make it "fail" and add the record's whole
--   list on top. The load has already queued CLIENT_ContainerDataResponse
--   with these items (ubergraph @57 -> 319); the drops' notices go after it on
--   the same reliable channel, and the remove request the client's window
--   build sends for each refused item reaches the host when that UID is gone.
--   a remote player's own game asking for its inventory (sdc_consume's host
--   post-hook on SERVER_RequestDataFromSave - Event_LoadPlayer @14017; the
--   host loads it and queues CLIENT_ContainerDataResponse @16204 in that
--   call): the same order.
--   the host's 1 s walk of the inventory (sdc_consume.host_player): an item
--   in such a grid of a kind its window refuses (window classes are learned
--   in that walk, grids once per grid).
-- Only those: an item whose kind cannot be read, a container whose window
-- class RULES does not list, the host's own inventory, a dead character: left
-- alone. Nothing is created - the item moves from the data to the ground; an
-- item used up is not in the data and never comes back. The player is told
-- (IHID, RU/EN).
-- The drops of this module, of IGLOST and of sdc_consume's GAIN.drop_at are
-- marked (M.dropping): sdc_world's grant hook on JigMP_OnRequestDropItem
-- leaves them alone (a real pickup with its contents is no fresh resource).
-- Gated by refused_items_to_feet (the rescue) and by the callers' own options
-- (host_adds_to_inventory, world_resource_to_inventory) for the grants.
--
-- Rules: no object wrapper is kept beyond the call that got it (paths,
-- addresses, numbers; a walk's plain Lua tables); hook / message callbacks
-- never throw.

local log = require("sdc_log")
local ue = require("sdc_ue")
local cfg = require("sdc_config")
local net = require("sdc_net")
local ctx = require("sdc_ctx")

local addr = ctx.addr
local clock = os.clock

local M = {
    stats = { asked = 0, answered = 0, placed = 0, left = 0, late = 0, reasked = 0, hidden = 0, rescued = 0, lost = 0 },
    WAIT_S = 5,           -- host: an answer is waited for this long (the pickup waits at the feet)
    REASK_S = 1,          -- host: the place the screen named was full here: asked again this much later
    AGAIN_S = 30,         -- host: one hidden item is tried at most once in this time
    SCAN_EVERY = 10,      -- host: a player's inventory is read for hidden items at most this often
    NODROP_S = 600,       -- host: an item whose drop gave no pickup is not dropped again for this long
    dropping = false,     -- host: inside a drop of this module / IGLOST / GAIN.drop_at (sdc_world reads it)
    drop_hook = false,    -- host: sdc_consume's post-hook on JigMP_OnRequestDropItem is in (M.note_drop)
    loading = false,      -- host: inside sdc_persist's own inventory load (M.on_load leaves it alone)
}
local S

-- BP struct members (GUID-suffixed names)
local F = {
    ITEMS = "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B",
    REP = "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332",
    INC = "InContainerUID_24_D1504ED7438699C73EA046AD734E79BF",
    USID = "UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68",
    INFO = "ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7",
    COUNT = "Count_8_DD79AF2A46126A338C8DCCB4616D91CD",
    ITEMID = "ItemID_28_01CA27D84AF7D1014D9E2E83894C1848",
    SUBS = "SubContainers_35_9B8F8C174A191BE2B5DAE19C1EB3FAAE",
    SUB_ID = "UniqueID_9_C5CA265F40546A19DEB2539CEC625BC7",
}

-- ---------------------------------------------------------------------------
-- What the special containers' windows take (game 0.8.0)
-- ---------------------------------------------------------------------------
local function set(list)
    local s = {}
    for _, v in ipairs(list or {}) do s[v] = true end
    return s
end
local function grid_rule(t)
    local types = {}
    for _, v in ipairs(t.types or {}) do types["Jig.ItemType." .. v] = true end
    return { types = next(types) and types or nil, also = set(t.also), only = t.only and set(t.only) or nil }
end
local BOOKS = {}
for _, b in ipairs({ "FirstAid", "Fishing", "Fitness", "Marksmanship", "Reloading", "Scavenging", "Sneaking", "Strength",
                     "Thief", "Toughness" }) do
    BOOKS[#BOOKS + 1] = b .. "Book"
end
for _, b in ipairs({ "FirstAid", "Fishing", "Fitness", "Marksmanship", "Reloading", "Scavenging", "Sneaking", "Strength",
                     "Thief", "Toughness" }) do
    BOOKS[#BOOKS + 1] = b .. "Magazine"
end
local TOOLBOX = { types = { "Material", "Tool" }, also = { "Battery", "Saw", "Hammer", "Can", "Can2" } }
local POUCH = { types = { "Ammunition", "WeaponAttachment" } }
-- [window class] = { [grid index in the owner's SubContainers] = { types =
-- SupportedItemTypes, also = AlsoSupportTheseItems, only =
-- OnlySupportTheseItems } } (item names: data assets without DA_); a grid
-- not listed takes anything
M.RULES = {
    SC_Wallet_C = { grid_rule({ types = { "Currency", "Keycard" } }) },
    SC_MedicalBag_C = { grid_rule({ types = { "MedicalConsumable" },
        also = { "BottleOfAntiseptic", "Cloth", "WaterPurificationTablets", "CharcoalTablets", "RadiationFilter",
                 "InfestationSample" } }) },
    SC_AmmoTin_C = { grid_rule({ types = { "Ammunition", "WeaponAttachment", "Throwable", "EquipmentAttachment" },
        also = { "MakeshiftWeaponCleaningKit", "WeaponCleaningKit", "Gunpowder", "BulletCasing", "ShellCasing", "LandMine" } }) },
    SC_Briefcase_C = { grid_rule({ types = { "Currency", "Keycard" }, also = BOOKS }) },
    SC_LargeToolbox_C = { grid_rule(TOOLBOX) },
    SC_SmallToolbox_C = { grid_rule(TOOLBOX) },
    SC_LunchBox_C = { grid_rule({ types = { "FoodConsumable", "DrinkConsumable" },
        also = { "CanOpener", "EmptyWaterBottle", "EmptyWaterCanteen", "EmptyWaterJug", "PlasticBottle",
                 "WaterPurificationTablets", "Pot" } }) },
    SC_WeaponsCase_C = { grid_rule({ types = { "WeaponAttachment", "Throwable", "Sidearm", "MainFirearm", "Melee",
                                               "Ammunition", "EquipmentAttachment" } }) },
    SC_Battery_C = { grid_rule({ only = { "Battery" } }) },
    SC_NVG_C = { grid_rule({ types = { "EquipmentAttachment" }, only = { "SpecOpsNVG", "CivilianNVG", "MilitaryNVG" } }) },
    SC_Respirator_C = { grid_rule({ only = { "RadiationFilter" } }) },
    -- (the vests' first two pouches; their third / fourth grid takes anything)
    SC_MilitaryPlateCarrier_C = { grid_rule(POUCH), grid_rule(POUCH) },
    SC_SpecOpsPlateCarrier_C = { grid_rule(POUCH), grid_rule(POUCH) },
    SC_GhillieBodyArmor_C = { grid_rule(POUCH), grid_rule(POUCH) },
}

-- Does the window grid of `rule` refuse item `name` of kind `tag`
-- (JSIContainer.IsSupportedType?)? nil: not known (its kind is needed and
-- could not be read).
function M.refuses(rule, name, tag)
    if not rule then return false end
    if rule.also[name] then return false end
    local id_ok = rule.only == nil or rule.only[name] == true
    if not rule.types then return not id_ok end
    if tag == nil or tag == "" then return nil end
    return not (rule.types[tag] and id_ok)
end

-- texts the client shows (RU / EN)
local TEXT = {
    place_hidden = { "%s was in your %s, where the game does not show it: it now lies at your feet.",
                     "Предмет «%s» лежал в «%s», где игра его не показывает: он выложен на землю у ваших ног." },
    place_hidden_load = { "%s was in your %s, where the game does not show it: it was dropped where you stood when your inventory was loaded.",
                          "Предмет «%s» лежал в «%s», где игра его не показывает: он выложен на землю там, где вы стояли при загрузке инвентаря." },
    place_hidden_lost = { "%s was in your %s, where the game does not show it; dropping it failed and it is gone.",
                          "Предмет «%s» лежал в «%s», где игра его не показывает; выложить его на землю не удалось, и он пропал." },
    place_hidden_stuck = { "%s is in your %s, where the game does not show it, and it cannot be dropped: the game will remove it when that window is rebuilt.",
                           "Предмет «%s» лежит в «%s», где игра его не показывает, а выложить его на землю не получается: игра удалит его, когда это окно перестроится." },
    place_lost = { "%s x%s could not be given to you: no room in the inventory and it could not be dropped either.",
                   "Не удалось выдать предмет «%s» x%s: в инвентаре нет места, и выложить его на землю тоже не получилось." },
}
for k, v in pairs(TEXT) do
    if type(log.TEXT) == "table" and not log.TEXT[k] then log.TEXT[k] = v end
end

local function gs(g) return string.format("%d:%d:%d:%d", g.A, g.B, g.C, g.D) end
local function gt(s)
    local a, b, c, d = tostring(s or ""):match("^(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+)$")
    if not a then return nil end
    return { A = math.tointeger(tonumber(a)), B = math.tointeger(tonumber(b)), C = math.tointeger(tonumber(c)),
             D = math.tointeger(tonumber(d)) }
end

local function name_of(da)
    if not ue.valid(da) then return "?" end
    return (ue.short(da):gsub("^DA_", ""))
end

-- An item's kind (its data asset's ItemType tag), nil when it cannot be read.
local TAGS = {}   -- [item name] = tag | false (unreadable)
local function rd_tag(da) return da.ItemType.TagName end
local function tag_of(da, name)
    if not ue.valid(da) then return nil end
    local t = TAGS[name]
    if t ~= nil then return t or nil end
    local ok, v = pcall(rd_tag, da)
    local s = ok and ue.str(v) or ""
    TAGS[name] = s ~= "" and s or false
    return s ~= "" and s or nil
end
M.tag_of = tag_of

local function is_remote_character(p)
    if not ue.valid(p) or not ue.class_name(p):find("PlayerCharacter", 1, true) then return false end
    return ue.valid(ue.prop(ue.prop(p, "Controller"), "NetConnection"))
end

-- A dead character's data is its death box's by then (sdc_deathbox).
local function is_dead(p)
    local pl = package.loaded["sdc_players"]
    local f = type(pl) == "table" and type(pl.helpers) == "table" and pl.helpers.is_dead
    if type(f) == "function" then
        local ok, v = pcall(f, p)
        if ok then return v == true end
    end
    return ue.prop(p, "PlayerDead?") == true
end

-- An actor still in the world (not destroyed): see the header.
function M.live(a)
    if not ue.valid(a) then return false end
    local sg = package.loaded["sdc_sweepguard"]
    if type(sg) == "table" and type(sg.live) == "function" then
        local ok, v = pcall(sg.live, a)
        if ok and v == false then return false end
    end
    local l = ue.location and ue.location(a)
    if type(l) == "table" and l.X == 0 and l.Y == 0 and l.Z == 0 then return false end
    return true
end

local function asset(path)
    if type(path) ~= "string" or path == "" then return nil end
    local da = ue.find_object(path)
    if not da and path:find("^/") and ue.load_asset then
        pcall(ue.load_asset, path, "place")
        da = ue.find_object(path)
    end
    if da and ue.class_name(da):find("DataAsset", 1, true) then return da end
    return nil
end

-- sdc_consume (it drives this module: init hands it over)
local CM = nil
local function consume() return CM or package.loaded["sdc_consume"] end

-- ---------------------------------------------------------------------------
-- Drops
-- ---------------------------------------------------------------------------
local R = { lost_at = {}, scanned = {}, seen_at = {}, read_at = {}, nodrop = {}, widget = {}, grid = {}, grid_n = 0,
            skip_said = {}, made = {}, stuck = {} }

-- fn() inside the mark sdc_world's grant hook reads; returns pcall's results.
-- The pickups the drop made are noted meanwhile (M.note_drop, M.came).
function M.own_drop(fn)
    local prev = M.dropping
    if not prev then R.made = {} end
    M.dropping = true
    local ok, err = pcall(fn)
    M.dropping = prev
    return ok, err
end

-- Host (sdc_consume's post-hook on JigMP_OnRequestDropItem, inside a drop of
-- ours): the pickup it made (none: ActorRef None).
function M.note_drop(a)
    if not M.dropping or not ue.valid(a) then return end
    R.made[#R.made + 1] = name_of(ue.prop(ue.prop(a, "BP_JigPickupComponent"), "ItemDataAsset"))
end

-- Can an item of `da` be dropped as a pickup at all? false, why: not tried.
function M.can_drop(da)
    if not ue.valid(da) then return false, "its item is not readable" end
    if not ue.valid(ue.prop(da, "PickupClass")) then return false, "it has no pickup class" end
    local t = R.nodrop[name_of(da)]
    if t and clock() - t < M.NODROP_S then return false, "its drop gave no pickup lately" end
    return true
end

-- An item of `da` whose drop gave no pickup: not dropped again for a while.
function M.drop_failed(da)
    if ue.valid(da) then R.nodrop[name_of(da)] = clock() end
end

-- Did the last drop of ours make a pickup? Inside one mark the game makes
-- exactly one drop, so any pickup is the proof - not its data asset: a
-- pickup class may name another one (BP_MilitaryPlateCarrier1Pickup for
-- DA_MilitaryPlateCarrier2: the item rides in its PickupInfo). nil: not known
-- (the hook is not in).
function M.came()
    if not M.drop_hook then return nil end
    return #R.made > 0
end

-- Host -> the player: an item of its inventory hidden in `owner_path`'s
-- window: mode "" dropped at its feet, "load" dropped where it stood at a
-- load, "lost" its drop made no pickup (gone), "stuck" it stays hidden there
-- and cannot be dropped (the game removes it at that window's next build).
-- "stuck" once a session per item (`uid`): it is tried again, the news stays
-- the same; the others happen once per item anyway (it leaves the data).
function M.tell(pc, item_path, n, owner_path, mode, uid)
    if not ue.valid(pc) then return end
    if mode == "stuck" then
        local key = tostring(addr(pc)) .. "|" .. tostring(uid or item_path)
        if R.stuck[key] then return end
        R.stuck[key] = true
    end
    net.send_to(pc, "IHID", item_path, math.floor(tonumber(n) or 1), owner_path or "", mode or "")
end

-- ===========================================================================
-- 1. Host grants: ask the client's screen
-- ===========================================================================
local Q = { n = 0, pend = {} }   -- pend: { id, k, pawn, drop, da, n, name, t, due, tries, atts, why, who }

local function send(p, pawn)
    local pc = ue.prop(pawn, "Controller")
    Q.n = Q.n + 1
    p.id, p.t, p.due = tostring(Q.n), clock(), nil
    p.k = addr(pc)
    return net.send_to(pc, "WHERE", p.id, p.da, p.n)
end

-- Host: `n` of `da` for remote player `pawn` lies at its feet as pickup
-- `drop` (the actor or its path): ask its screen where it goes. opts: later
-- (ask REASK_S from now: earlier items of the same moment show on that
-- screen by then), atts (its default attachments with it). true when asked
-- (or due); false: not (the pickup stays where it is).
function M.ask(pawn, da, n, drop, why, opts)
    if not S or S.role ~= "host" or not is_remote_character(pawn) or not ue.valid(da) then return false end
    n = math.floor(tonumber(n) or 0)
    local dpath = drop
    if type(drop) ~= "string" then dpath = ue.valid(drop) and ue.path(drop) or nil end
    if n < 1 or type(dpath) ~= "string" or dpath == "" then return false end
    opts = opts or {}
    local p = { pawn = ue.path(pawn), drop = dpath, da = ue.path(da), n = n, name = name_of(da), why = why,
                who = ue.short(pawn), tries = 1, atts = opts.atts == true }
    if opts.later then
        p.due = clock() + M.REASK_S
    elseif not send(p, pawn) then
        return false
    end
    M.stats.asked = M.stats.asked + 1
    Q.pend[#Q.pend + 1] = p
    log.info("place: %s x%d for %s lies at its feet (%s): %s", p.name, n, p.who, tostring(why or "the host's grant"),
        opts.later and string.format("its screen is asked where it goes in %.0f s", M.REASK_S) or "asked its screen where it goes")
    return true
end

local function left(p, who, line, warn)
    M.stats.left = M.stats.left + 1
    local s = string.format("place: %s x%d for %s stays at its feet: %s", p.name, p.n, who, line)
    if warn then log.warn("%s", s) else log.info("%s", s) end
end

-- Host: a grant whose answer came (spot) or did not (nil).
local function settle(p, spot)
    local pawn, drop, da = ue.find_object(p.pawn), ue.find_object(p.drop), ue.find_object(p.da)
    local who = ue.valid(pawn) and ue.short(pawn) or p.who
    if not M.live(drop) then
        M.stats.left = M.stats.left + 1
        log.info("place: %s x%d for %s: its pickup was taken meanwhile, nothing added", p.name, p.n, who)
        return
    end
    if not spot then return left(p, who, string.format("no answer from its screen in %d s", M.WAIT_S), true) end
    if spot.kind == "n" then return left(p, who, "its screen has no room for it (as single player)") end
    local cm = consume()
    if not is_remote_character(pawn) or not ue.valid(da) or type(cm) ~= "table" or not cm.place then
        return left(p, who, "the player or the item is gone here")
    end
    if is_dead(pawn) then return left(p, who, "the character is dead (its inventory is its death box's)") end
    local ok, done, what = pcall(cm.place, pawn, da, p.n, spot, p.atts)
    if not ok or not done then
        -- the place its screen named is full here (several grants of one
        -- moment all name the same grid): once more, when they show there
        if ok and (spot.kind == "c" or spot.kind == "s") and p.tries < 2 then
            p.tries, p.due = p.tries + 1, clock() + M.REASK_S
            Q.pend[#Q.pend + 1] = p
            M.stats.reasked = M.stats.reasked + 1
            log.info("place: %s x%d for %s: %s; its screen is asked again in %.0f s", p.name, p.n, who, tostring(what),
                M.REASK_S)
            return
        end
        return left(p, who, ok and tostring(what) or ("placing it FAILED: " .. tostring(done)), true)
    end
    -- in the inventory now: its pickup goes (only now - never both, never none)
    local gone = pcall(function() drop:K2_DestroyActor() end)
    M.stats.placed = M.stats.placed + 1
    local line = string.format("place: %s x%d for %s went where its screen put it: %s", p.name, p.n, who, tostring(what))
    if gone then log.info("%s", line) else log.err("%s - but its pickup could NOT be removed", line) end
end

-- WHEREIS|<id>|<c|s|n|?>|<grid / stack uid>|<slot>, client -> host. Only the
-- player that was asked answers its own question.
local function on_where_is(f, pc)
    if not S or S.role ~= "host" then return end
    local id, k = f[1], addr(pc)
    for i, p in ipairs(Q.pend) do
        if not p.due and p.id == id and p.k == k then
            table.remove(Q.pend, i)
            M.stats.answered = M.stats.answered + 1
            local kind = f[2]
            if kind ~= "c" and kind ~= "s" and kind ~= "n" then kind = "?" end
            settle(p, { kind = kind, uid = f[3] or "", slot = f[4] or "" })
            return
        end
    end
    M.stats.late = M.stats.late + 1
    log.debug("place: %s answered question %s, which nothing waits for", ue.short(pc), tostring(id))
end

-- WHERE|<id>|<item data asset path>|<count>, host -> client: where this
-- screen puts that item (asked and given up at once: nothing changes here).
local function on_where(f)
    if not S or S.role ~= "client" then return end
    local id, path, n = f[1] or "", f[2] or "", math.floor(tonumber(f[3]) or 0)
    local da = asset(path)
    local cm = consume()
    local kind, spot, slot, here = "?", "", "", "not asked"
    if da and n > 0 and type(cm) == "table" and cm.client_spot then
        local ok, a, b, c, d = pcall(cm.client_spot, da, n)
        if ok then kind, spot, slot, here = a, b, c, d else here = "FAILED: " .. tostring(a) end
    end
    net.send_to_host("WHEREIS", id, kind, spot, slot)
    log.info("place: the host gives %s x%d: this screen puts it %s (%s)", da and name_of(da) or path, n,
        kind == "c" and ("into grid " .. spot) or kind == "s" and ("onto stack " .. spot)
        or kind == "n" and "nowhere (no room)" or "? (not known)", tostring(here))
end

-- ===========================================================================
-- 2. Hidden items: out of the grids whose window refuses them
-- ===========================================================================

-- Host: the player's data: grids { uid, owner, items } and items [uid] =
-- { uid, da, n, grid, subs = its grids in order } (this call only).
local function read_inv(comp)
    local grids, items = {}, {}
    local ok, err = pcall(function()
        comp.MainJigContainers:ForEach(function(_, c)
            local cont = c:get()
            local g = { uid = gs(cont[F.REP]), owner = gs(cont[F.INC]), items = {} }
            grids[#grids + 1] = g
            cont[F.ITEMS]:ForEach(function(_, e)
                local item = e:get()
                local info = item[F.INFO]
                local x = { uid = gs(item[F.USID]), da = info[F.ITEMID], n = math.floor(tonumber(info[F.COUNT]) or 0),
                            grid = g.uid, subs = {} }
                pcall(function()
                    item[F.SUBS]:ForEach(function(_, s) x.subs[#x.subs + 1] = gs(s:get()[F.SUB_ID]) end)
                end)
                g.items[#g.items + 1] = x
                items[x.uid] = x
            end)
        end)
    end)
    return grids, items, ok, err
end

-- An item's window class (its data asset's SpecialContainerWidget), learned
-- per item name (also by sdc_consume's inventory walk: M.learn_widget);
-- false: none.
function M.learn_widget(name, da)
    local w = R.widget[name]
    if w == nil then
        local cls = ue.valid(da) and ue.prop(da, "SpecialContainerWidget")
        w = ue.valid(cls) and ue.short(cls) or false
        R.widget[name] = w
    end
    return w
end
local function widget_of(da) return M.learn_widget(name_of(da), da) end

-- The window rule of grid `g` (nil: takes anything / not known), learned per
-- grid for the 1 s walk; and the owner item.
local function rule_of(g, items)
    local o = items[g.owner]
    if not o then return nil end
    local w = widget_of(o.da)
    local rules = w and M.RULES[w]
    if not rules then return nil, o end
    for i, s in ipairs(o.subs) do
        if s == g.uid then
            if R.grid_n > 4096 then R.grid, R.grid_n = {}, 0 end
            if R.grid[s] == nil then R.grid_n = R.grid_n + 1 end
            R.grid[s] = rules[i] or false
            return rules[i], o
        end
    end
    return nil, o
end

-- Host (sdc_consume.place): would the window of grid `grid` of `comp` refuse
-- n of `da`? true only when it surely would.
function M.grid_refuses(comp, grid, da)
    if not ue.valid(comp) or not ue.valid(da) then return false end
    local grids, items, ok = read_inv(comp)
    if not ok then return false end
    for _, g in ipairs(grids) do
        if g.uid == grid then
            local rule = rule_of(g, items)
            local name = name_of(da)
            return M.refuses(rule, name, tag_of(da, name)) == true
        end
    end
    return false
end

-- Host: the data asset path of the item grid `grid` of `comp` belongs to
-- ("" when not known).
function M.owner_path(comp, grid)
    if not ue.valid(comp) then return "" end
    local grids, items, ok = read_inv(comp)
    if not ok then return "" end
    for _, g in ipairs(grids) do
        if g.uid == grid then
            local o = items[g.owner]
            return o and ue.valid(o.da) and ue.path(o.da) or ""
        end
    end
    return ""
end

-- Host (sdc_consume's post-hook on SERVER_RequestDataFromSave): a remote
-- player's inventory loaded for its windows - the rescue, unless sdc_persist
-- is inside its own load (it compares the counts first, then rescues).
function M.on_load(pawn)
    if M.loading then
        log.debug("place: %s's inventory loaded by the persist restore: its rescue comes after the restore's check",
            ue.short(pawn))
        return 0
    end
    return M.rescue(pawn, "load")
end

-- Host: items of remote player `pawn` that sit in a grid whose window refuses
-- them go to its feet. why "load" / "restore": a load of its inventory (the
-- pickups lie where the character stood then). Returns how many were dropped.
function M.rescue(pawn, why)
    if not S or S.role ~= "host" or cfg.get("refused_items_to_feet") == false then return 0 end
    if not is_remote_character(pawn) or is_dead(pawn) then return 0 end
    local comp = ue.prop(pawn, "BP_JigMultiplayer")
    if not ue.valid(comp) then return 0 end
    local who = ue.short(pawn)
    R.read_at[addr(comp) or who] = clock()
    local grids, items, ok, err = read_inv(comp)
    if not ok then
        log.warn("place: %s's inventory could not be read for hidden items (%s): nothing moved", who, tostring(err))
        return 0
    end
    for _, x in pairs(items) do
        if #x.subs > 0 then widget_of(x.da) end   -- (learned for the 1 s walk)
    end
    local hidden = {}
    for _, g in ipairs(grids) do
        local rule, o = rule_of(g, items)
        if rule then
            for _, x in ipairs(g.items) do
                local name = name_of(x.da)
                if M.refuses(rule, name, tag_of(x.da, name)) then
                    hidden[#hidden + 1] = { x = x, name = name, owner = name_of(o.da), opath = ue.path(o.da), path = ue.path(x.da) }
                end
            end
        end
    end
    if #hidden == 0 then return 0 end
    local now = clock()
    local pc = ue.prop(pawn, "Controller")
    local kp = tostring(addr(comp) or who)
    for k, t in pairs(R.lost_at) do
        if now - t > 2 * M.AGAIN_S then R.lost_at[k] = nil end
    end
    local tried = {}
    for _, h in ipairs(hidden) do
        local key = kp .. "|" .. h.x.uid
        if now - (R.lost_at[key] or -1000) >= M.AGAIN_S then
            R.lost_at[key] = now
            M.stats.hidden = M.stats.hidden + 1
            local can, why_not = M.can_drop(h.x.da)
            if not can then
                -- (no pickup class: never droppable - not tried, nor read for
                -- it, again; a drop failing lately: not before that ends)
                local t = R.nodrop[h.name]
                R.lost_at[key] = (t and t + M.NODROP_S - M.AGAIN_S) or math.huge
            end
            if can then
                local g = gt(h.x.uid)
                local okd, errd = M.own_drop(function() comp:SERVER_RequestDropItem(g, h.x.n, comp) end)
                h.err = not okd and tostring(errd) or nil
                h.came = M.came()
            else
                h.skip = why_not
            end
            tried[#tried + 1] = h
        end
    end
    if #tried == 0 then return 0 end
    -- what left the data (a drop's pickup has it now - or nothing has)
    local _, after = read_inv(comp)
    local n = 0
    local mode = (why == "load" or why == "restore") and "load" or ""
    for _, h in ipairs(tried) do
        local gone = after[h.x.uid] == nil
        local what
        if h.skip or not gone then
            -- (it stays hidden; the client's next build of that window
            -- removes it: the player is told, once in a while)
            M.tell(pc, h.path, h.x.n, h.opath, "stuck", h.x.uid)
            what = h.skip and ("NOT dropped: " .. h.skip)
                or ("NOT dropped" .. (h.err and (": " .. h.err) or " (still in its inventory)"))
        elseif h.came == false then
            M.stats.lost = M.stats.lost + 1
            M.drop_failed(h.x.da)
            M.tell(pc, h.path, h.x.n, h.opath, "lost", h.x.uid)
            what = "LOST: out of its inventory, but no pickup of it came"
        else
            n = n + 1
            M.stats.rescued = M.stats.rescued + 1
            if h.came then M.tell(pc, h.path, h.x.n, h.opath, mode, h.x.uid) end
            what = h.came and (mode == "load" and "dropped where it stood at the load" or "dropped at its feet")
                or "out of its inventory (its pickup not confirmed: the player is not told)"
        end
        local line = string.format("place: %s's %s x%d (uid %s) sat in its %s, whose window does not show it (%s): %s", who,
            h.name, h.x.n, h.x.uid, h.owner, tostring(why), what)
        local sk = h.skip and (kp .. "|" .. h.x.uid)
        if sk and now - (R.skip_said[sk] or -1e9) < M.NODROP_S then
            log.debug("%s", line)   -- (said already: tried again every AGAIN_S, told once in NODROP_S)
        elseif h.came == false and gone then
            log.err("%s", line)
        else
            log.warn("%s", line)
        end
        if sk then R.skip_said[sk] = now end
    end
    local cm = consume()
    if type(cm) == "table" and cm.renew_ledger then pcall(cm.renew_ledger, comp) end
    return n
end

-- Host, after the 1 s walk of a remote player's inventory (sdc_consume.
-- host_player; entries { uid, id = item name, cuid = its grid, sub = its
-- first grid }): an item in a grid whose window refuses its kind (or kind /
-- window / grid not learned yet) -> M.rescue reads the data and decides.
function M.scan(pawn, jig, inv)
    -- (a walk with a read error still lists what it read; M.rescue reads again)
    if not S or S.role ~= "host" or type(inv) ~= "table" or cfg.get("refused_items_to_feet") == false then return end
    local k = addr(jig)
    if not k or R.scanned[k] == inv then return end
    R.scanned[k], R.seen_at[k] = inv, clock()
    local now = clock()
    local want = false
    for _, e in ipairs(inv.list or {}) do
        if e.sub then   -- an item with grids of its own: its window known? its grids?
            local w = R.widget[e.id]
            if w == nil or (w and M.RULES[w] and R.grid[e.sub] == nil) then want = true break end
        end
        local r = e.cuid and R.grid[e.cuid]
        if r and now - (R.lost_at[tostring(k) .. "|" .. tostring(e.uid)] or -1000) >= M.AGAIN_S then
            local t = TAGS[e.id]
            local v = M.refuses(r, e.id, t or nil)
            if v == true or (v == nil and t == nil) then want = true break end
        end
    end
    if want and now - (R.read_at[k] or -1000) >= M.SCAN_EVERY then M.rescue(pawn, "inventory check") end
end

-- Host: n of `da` could not be given to `pc`'s player at all (no room, no
-- drop): the player is told.
function M.tell_lost(pc, da, n)
    if ue.valid(pc) and ue.valid(da) then net.send_to(pc, "IFAIL", ue.path(da), math.floor(tonumber(n) or 1)) end
end

local function label(path)
    local da = asset(path)
    if not da then return (tostring(path):match("DA_([%w_]+)$")) or "?" end
    local s = ue.str(ue.prop(da, "name"))
    if s == "" then s = name_of(da) end
    return s
end

-- IHID|<item path>|<count>|<container item path>|<"" | load | lost | stuck>, host -> client.
local function on_hidden(f)
    if not S or S.role ~= "client" then return end
    local item, owner, mode = label(f[1]), label(f[3]), f[4] or ""
    local key = mode == "load" and "place_hidden_load" or mode == "lost" and "place_hidden_lost"
        or mode == "stuck" and "place_hidden_stuck" or "place_hidden"
    log.say(key, (mode == "lost" or mode == "stuck") and "err" or "warn", 10, item, owner)
    log.warn("place: the host found %s x%s in this inventory's %s (its window does not show it): %s", item, tostring(f[2]),
        owner, mode == "lost" and "its drop failed, it is gone" or mode == "load" and "dropped where this player stood at the load"
        or mode == "stuck" and "it cannot be dropped, it stays hidden there" or "dropped at this player's feet")
end

-- IFAIL|<item path>|<count>, host -> client.
local function on_failed(f)
    if not S or S.role ~= "client" then return end
    local item = label(f[1])
    log.say("place_lost", "err", 10, item, tostring(f[2] or "1"))
    log.err("place: the host could not give %s x%s to this player (no room, no drop)", item, tostring(f[2]))
end

-- ===========================================================================
-- Driven by sdc_consume
-- ===========================================================================
function M.init(state, consume_mod)
    S = state
    if type(consume_mod) == "table" then CM = consume_mod end
end

function M.host_tick(now)
    now = now or clock()
    if #Q.pend > 0 then
        local keep, due, ask = {}, {}, {}
        for _, p in ipairs(Q.pend) do
            if p.due then
                if now >= p.due then ask[#ask + 1] = p else keep[#keep + 1] = p end
            elseif now - p.t >= M.WAIT_S then
                due[#due + 1] = p
            else
                keep[#keep + 1] = p
            end
        end
        Q.pend = keep
        for _, p in ipairs(ask) do
            local pawn = ue.find_object(p.pawn)
            if is_remote_character(pawn) and send(p, pawn) then
                Q.pend[#Q.pend + 1] = p
            else
                left(p, p.who, "its screen could not be asked again (the player is gone here)")
            end
        end
        for _, p in ipairs(due) do settle(p, nil) end
    end
    for k, t in pairs(R.read_at) do
        if now - t > 120 then R.read_at[k] = nil end
    end
    for k, t in pairs(R.seen_at) do   -- (players who left: their last walk goes)
        if now - t > 120 then R.seen_at[k], R.scanned[k] = nil, nil end
    end
end

function M.reset()
    Q.pend = {}
    R.lost_at, R.scanned, R.seen_at, R.read_at, R.nodrop, R.skip_said, R.stuck = {}, {}, {}, {}, {}, {}, {}
    R.grid, R.grid_n = {}, 0
end

function M.register_handlers()
    -- host -> client: WHERE|<id>|<item path>|<count>     (where does your screen put it?)
    net.on("WHERE", on_where)
    -- client -> host: WHEREIS|<id>|<c|s|n|?>|<grid / stack uid>|<slot>
    net.on("WHEREIS", on_where_is)
    -- host -> client: IHID|<item path>|<count>|<container item path>|<""|load|lost|stuck>   (a hidden item)
    net.on("IHID", on_hidden)
    -- host -> client: IFAIL|<item path>|<count>   (an item that could not be given at all)
    net.on("IFAIL", on_failed)
    -- (an answer to the player's own action: past the send queue, as WSPOT)
    if type(net.NOW) == "table" then
        net.NOW.WHERE, net.NOW.WHEREIS = true, true
    end
end

M.widget = R.widget   -- (read by sdc_consume's walk: learned yet?)

-- (tests)
M._t = { Q = Q, R = R, TAGS = TAGS }

return M
