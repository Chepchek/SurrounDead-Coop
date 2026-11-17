-- SDCoop: compact text forms for the mod channel (sdc_net). No engine calls.
--
--   wire.uid_enc("A:B:C:D")  -> 22 characters (A-Za-z0-9-_), or "" for a text that is no GUID
--   wire.uid_dec(text)       -> "A:B:C:D" (signed 32-bit parts, as the game prints them), or nil
--   wire.num(x, decimals)    -> the shortest text of x rounded to `decimals` places
--                               ("86", "86.5"; no trailing zeros, no "-0")
--
-- An item / container UID (FGuid, four int32) was sent as "-399008991:1216681327:-1278485583:-941303400"
-- (43 characters); now as 16 bytes in URL-safe base64 without padding (22 characters).
-- The text form "A:B:C:D" stays the form every module keeps and logs; only the
-- messages carry the short one. The alphabet has none of the separators the
-- messages use: | , ; = / @ : %
--
-- Every message that carries a UID encodes it here and decodes it here:
--   JMC (op args + container key), JADD, UIDS, ITEMS, IGLOST, RESEND, SETDUR,
--   GHOSTQ, WSTAT, GWEAR, WSPOT, WTOOLDUR, WBMODE.

local M = {}

local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local ENC, DEC = {}, {}
for i = 1, #ALPHA do
    local c = ALPHA:sub(i, i)
    ENC[i - 1] = c
    DEC[c] = i - 1
end

local cache_e, cache_d, cache_n = {}, {}, 0
local CACHE_MAX = 4096

local function remember(a, b)
    if cache_n >= CACHE_MAX then cache_e, cache_d, cache_n = {}, {}, 0 end
    cache_e[a], cache_d[b] = b, a
    cache_n = cache_n + 1
end

local function int32(s)
    local n = math.tointeger(tonumber(s))
    if not n or n < -2147483648 or n > 2147483647 then return nil end
    return n
end

-- (tests: encode and decode are two machines in the game, a cache hit would hide the decoder)
function M.clear_cache() cache_e, cache_d, cache_n = {}, {}, 0 end

function M.uid_enc(s)
    s = tostring(s or "")
    local hit = cache_e[s]
    if hit then return hit end
    local a, b, c, d = s:match("^(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+)$")
    if not a then return "" end
    local w = { int32(a), int32(b), int32(c), int32(d) }
    if not (w[1] and w[2] and w[3] and w[4]) then return "" end
    local bytes = {}
    for i = 1, 4 do
        local u = w[i] & 0xFFFFFFFF
        bytes[#bytes + 1] = (u >> 24) & 0xFF
        bytes[#bytes + 1] = (u >> 16) & 0xFF
        bytes[#bytes + 1] = (u >> 8) & 0xFF
        bytes[#bytes + 1] = u & 0xFF
    end
    local out = {}
    for i = 1, 15, 3 do
        local n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]
        out[#out + 1] = ENC[(n >> 18) & 63] .. ENC[(n >> 12) & 63] .. ENC[(n >> 6) & 63] .. ENC[n & 63]
    end
    local n = bytes[16] << 16   -- the last byte: two characters
    out[#out + 1] = ENC[(n >> 18) & 63] .. ENC[(n >> 12) & 63]
    local text = table.concat(out)
    remember(s, text)
    return text
end

function M.uid_dec(t)
    if type(t) ~= "string" or #t ~= 22 then return nil end
    local hit = cache_d[t]
    if hit then return hit end
    local v = {}
    for i = 1, 22 do
        local x = DEC[t:sub(i, i)]
        if not x then return nil end
        v[i] = x
    end
    local bytes = {}
    for i = 1, 20, 4 do
        local n = (v[i] << 18) | (v[i + 1] << 12) | (v[i + 2] << 6) | v[i + 3]
        bytes[#bytes + 1] = (n >> 16) & 0xFF
        bytes[#bytes + 1] = (n >> 8) & 0xFF
        bytes[#bytes + 1] = n & 0xFF
    end
    if #bytes ~= 15 then return nil end
    -- (the 22nd character carries the last byte's top 4 bits only after the 21st's low 4)
    local last = (v[21] << 6) | v[22]
    if last & 0xF ~= 0 then return nil end   -- not a text this encoder makes
    bytes[16] = (last >> 4) & 0xFF
    local parts = {}
    for i = 1, 16, 4 do
        local u = (bytes[i] << 24) | (bytes[i + 1] << 16) | (bytes[i + 2] << 8) | bytes[i + 3]
        if u >= 0x80000000 then u = u - 0x100000000 end
        parts[#parts + 1] = string.format("%d", u)
    end
    local text = table.concat(parts, ":")
    remember(text, t)
    return text
end

-- x rounded to `dec` places, shortest text
function M.num(x, dec)
    x = tonumber(x) or 0
    local s = string.format("%." .. (dec or 0) .. "f", x)
    if s:find(".", 1, true) then
        s = s:gsub("0+$", ""):gsub("%.$", "")
    end
    if s == "-0" or s == "" then s = "0" end
    return s
end

return M
