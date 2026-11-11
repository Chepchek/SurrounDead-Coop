-- Every message kind has one handler in the whole mod (sdc_net keeps one
-- handler per kind: a second net.on("X") silently replaces the first - 0.6.57
-- had sdc_dialogue's trader money and sdc_quests' markers both on "QM").
local dir = arg[1]
local files = {}
local p = io.popen('dir /b "' .. dir:gsub("/", "\\") .. '\\*.lua" 2>nul')
if p then
  for line in p:lines() do files[#files + 1] = line end
  p:close()
end
if #files == 0 then
  p = io.popen('ls "' .. dir .. '"/*.lua 2>/dev/null')
  for line in p:lines() do files[#files + 1] = line:match("([^/\\]+)$") end
  p:close()
end
assert(#files > 10, "no scripts found in " .. tostring(dir))
local seen, dup = {}, {}
for _, f in ipairs(files) do
  local h = assert(io.open(dir .. "/" .. f, "r"))
  local src = h:read("a")
  h:close()
  for kind in src:gmatch('net%.on%("([%w_]+)"') do
    if seen[kind] and seen[kind] ~= f then dup[#dup + 1] = kind .. " (" .. seen[kind] .. ", " .. f .. ")" end
    if seen[kind] == f then dup[#dup + 1] = kind .. " (twice in " .. f .. ")" end
    seen[kind] = f
  end
end
local n = 0
for _ in pairs(seen) do n = n + 1 end
if #dup > 0 then
  print("duplicate message handlers: " .. table.concat(dup, "; "))
  os.exit(1)
end
assert(seen.QTM == "sdc_dialogue.lua" and seen.QM == "sdc_quests.lua", "QTM / QM owners")
print(string.format("%d files, %d message kinds, each with one handler", #files, n))
print("ALL OK")
