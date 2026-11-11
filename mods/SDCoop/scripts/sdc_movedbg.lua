-- SDCoop debug: what moves the client's own character back (client, debug).
--
-- The client's character steps back 3-10 cm in about one frame out of five
-- while its velocity points forward, at any frame rate, with any server
-- setting (see the movement experiments). This records, for every such
-- back-step: the frame's displacement (with Z), velocity, the floor under the
-- capsule, blocking hits the capsule reported this frame and how long ago the
-- last server move response arrived. Plus a count of hits per other object.
--
-- Nothing here changes the game; it only reads and logs.

local log = require("sdc_log")
local ue = require("sdc_ue")

local M = {}
local S
function M.init(state) S = state end

local st = {
    hooked = false, prev = nil, prev_t = nil, logged = 0, window_start = nil,
    backs = 0, frames = 0, hits = 0, hit_by = {}, frame_hits = {}, last_resp = nil, resp = 0,
    backs_after_resp = 0,
}

local function now_t()
    local gps, wc = ue.gameplay_statics(), ue.world_context()
    if not gps or not wc then return nil end
    return ue.try(function() return gps:GetTimeSeconds(wc) end)
end

local function own_name()
    local me = ue.local_pawn()
    return me and ue.name(me) or nil, me
end

local function vec(v)
    if v == nil then return nil end
    local x, y, z = ue.try(function() return v.X end), ue.try(function() return v.Y end), ue.try(function() return v.Z end)
    if type(x) ~= "number" then return nil end
    return { X = x, Y = y or 0, Z = z or 0 }
end

-- Actor.ReceiveHit(MyComp, Other, OtherComp, bSelfMoved, HitLocation, HitNormal, NormalImpulse, Hit)
local function on_hit(c, _, other, other_comp, self_moved, _, hit_normal, _, hit)
    local a = c and c:get()
    if not ue.valid(a) then return end
    local me = own_name()
    if not me or ue.name(a) ~= me then return end
    local o = other and other:get()
    local oc = other_comp and other_comp:get()
    local key = (ue.valid(o) and ue.class_name(o) or "none") .. "." .. (ue.valid(oc) and ue.short(oc) or "none")
    local n = vec(hit_normal and hit_normal:get())
    local h = hit and hit:get()
    local pen = h and ue.try(function() return h.bStartPenetrating end)
    st.hits = st.hits + 1
    st.hit_by[key] = (st.hit_by[key] or 0) + 1
    st.frame_hits[#st.frame_hits + 1] = string.format("%s n=%s pen=%s moved=%s", key,
        n and string.format("%.2f,%.2f,%.2f", n.X, n.Y, n.Z) or "?", tostring(pen),
        tostring(self_moved and self_moved:get()))
end

local function on_response()
    st.last_resp = os.clock()
    st.resp = st.resp + 1
end

-- SceneComponent.OnRep_Transform: the server writing a replicated component
-- transform into this machine's copy. On the own capsule that is a position
-- from the server, i.e. from the past (the suspected back-step).
st.reps, st.last_rep = 0, nil
local own_capsule_name = nil
local function on_rep_transform(c)
    local comp = c and c:get()
    if not ue.valid(comp) or not own_capsule_name then return end
    if ue.name(comp) ~= own_capsule_name then return end
    st.reps = st.reps + 1
    st.last_rep = os.clock()
end

local function install()
    if st.hooked then return end
    st.hooked = true
    local ok1, e1 = pcall(RegisterHook, "/Script/Engine.Actor:ReceiveHit", function(...)
        local ok, err = pcall(on_hit, ...)
        if not ok then log.err_throttled("movedbg-hit", "movedbg hit: %s", tostring(err)) end
    end)
    local ok2, e2 = pcall(RegisterHook, "/Script/Engine.Character:ClientMoveResponsePacked", function()
        on_response()
    end, function() end)
    local ok3, e3 = pcall(RegisterHook, "/Script/Engine.SceneComponent:OnRep_Transform", function(c)
        local ok, err = pcall(on_rep_transform, c)
        if not ok then log.err_throttled("movedbg-rep", "movedbg rep: %s", tostring(err)) end
    end, function() end)
    log.info("movedbg: hit hook %s%s, response hook %s%s, transform rep hook %s%s",
        ok1 and "ok" or "FAILED", ok1 and "" or (" " .. tostring(e1)),
        ok2 and "ok" or "FAILED", ok2 and "" or (" " .. tostring(e2)),
        ok3 and "ok" or "FAILED", ok3 and "" or (" " .. tostring(e3)))
end

local function floor_text(cmc)
    local f = ue.prop(cmc, "CurrentFloor")
    if f == nil then return "?" end
    local walk = ue.try(function() return f.bWalkableFloor end)
    local dist = ue.try(function() return f.FloorDist end)
    local comp = ue.try(function() return f.HitResult.Component end)
    local cname = "?"
    if comp ~= nil then
        local cobj = ue.try(function() return comp:Get() end) or comp
        if ue.valid(cobj) then cname = ue.short(cobj) end
    end
    return string.format("walk=%s dist=%s comp=%s", tostring(walk), type(dist) == "number" and string.format("%.2f", dist) or "?", cname)
end

-- Every frame (client, debug only).
function M.frame()
    if not S or S.role ~= "client" or not log.probes_enabled then return end
    install()
    local _, me = own_name()
    if not me or ue.role(me) ~= ue.ROLE_AUTONOMOUS then
        st.prev = nil
        return
    end
    local t = now_t()
    local p = ue.location(me)
    if type(t) ~= "number" or not p then return end
    local cap = ue.prop(me, "CapsuleComponent")
    own_capsule_name = ue.valid(cap) and ue.name(cap) or nil
    local hits = st.frame_hits
    st.frame_hits = {}
    st.window_start = st.window_start or t
    if st.prev and st.prev_t and t > st.prev_t then
        local dt = t - st.prev_t
        local d = { X = p.X - st.prev.X, Y = p.Y - st.prev.Y, Z = p.Z - st.prev.Z }
        local v = vec(ue.try(function() return me:GetVelocity() end))
        local speed = v and math.sqrt(v.X * v.X + v.Y * v.Y) or 0
        local along = v and speed > 1 and (d.X * v.X + d.Y * v.Y) / speed or 0
        if speed > 150 then
            st.frames = st.frames + 1
            if along < -0.5 then
                st.backs = st.backs + 1
                local since = st.last_resp and (os.clock() - st.last_resp) or -1
                if since >= 0 and since < 0.04 then st.backs_after_resp = st.backs_after_resp + 1 end
                local since_rep = st.last_rep and (os.clock() - st.last_rep) or -1
                if since_rep >= 0 and since_rep <= dt + 0.002 then st.backs_after_rep = (st.backs_after_rep or 0) + 1 end
                if st.logged < 60 then
                    st.logged = st.logged + 1
                    local cmc = ue.prop(me, "CharacterMovement")
                    log.info("movedbg: back %.1f cm dt=%.4f d=%.2f,%.2f,%.2f v=%.0f,%.0f,%.0f mode=%s floor[%s] since_resp=%.3f since_capsule_rep=%.3f hits=%d %s",
                        -along, dt, d.X, d.Y, d.Z, v.X, v.Y, v.Z, tostring(ue.prop(cmc, "MovementMode")),
                        floor_text(cmc), since, since_rep, #hits, table.concat(hits, " | "))
                end
            end
        end
    end
    st.prev, st.prev_t = p, t
    if t - st.window_start >= 10 then
        local parts = {}
        for k, n in pairs(st.hit_by) do parts[#parts + 1] = k .. "=" .. n end
        log.info("movedbg: 10 s: moving frames=%d back-steps=%d (in the frame of a capsule transform rep: %d; within 40 ms of a server response: %d) capsule reps=%d responses=%d hits=%d [%s]",
            st.frames, st.backs, st.backs_after_rep or 0, st.backs_after_resp, st.reps, st.resp, st.hits, table.concat(parts, " "))
        st.frames, st.backs, st.backs_after_resp, st.resp, st.hits, st.hit_by = 0, 0, 0, 0, 0, {}
        st.reps, st.backs_after_rep = 0, 0
        st.window_start = t
    end
end

function M.reset()
    st.prev, st.prev_t, st.frame_hits = nil, nil, {}
end

return M
