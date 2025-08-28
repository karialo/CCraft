-- /kari/bin/update.lua — hardened GitHub Raw manifest updater (role-aware, Lua 5.1-safe)

-- ===== tiny utils =====
local CFG = "/kari/data/config"
local unser = textutils.unserialize or textutils.unserialise
local jdec  = textutils.unserialiseJSON or textutils.unserializeJSON or unser

local function log(...)  -- zero fanciness, zero recursion risk
  local t = {}
  for i=1,select("#", ...) do t[#t+1] = tostring(select(i, ...)) end
  print(table.concat(t, " "))
end
local function has(p) return fs.exists(p) and not fs.isDir(p) end
local function mkdir(path)
  local d = fs.getDir(path)
  if d ~= "" and not fs.exists(d) then fs.makeDir(d) end
end

local function readTbl(path)
  if not has(path) then return {} end
  local ok, res = pcall(function()
    local h=fs.open(path,"r"); local s=h.readAll(); h.close()
    local t = unser(s); return (type(t)=="table") and t or {}
  end)
  return (ok and res) or {}
end

local function http_get(u, tries)
  if not http then return nil end               -- never throw if HTTP disabled
  tries = tries or 3
  for i=1,tries do
    local ok,res = pcall(http.get, u, {["User-Agent"]="KARI-Updater"})
    if ok and res then
      local b = res.readAll() or ""; res.close()
      if #b > 0 then return b end
    end
    sleep(0.25)
  end
  return nil
end

local function needsUpdate(path, contents)
  if not has(path) then return true end
  local h=fs.open(path,"r"); local cur=h.readAll(); h.close()
  return cur ~= contents
end

-- ===== manifest loader =====
local function normalize_items(origin, base, items)
  local out = {}
  local function join(u) return (u:gsub("([^:])//+","%1/")) end
  for _,it in ipairs(items or {}) do
    if type(it)=="string" then
      table.insert(out, { path=it, src = join(origin..(base or "")..it) })
    elseif type(it)=="table" then
      if it.src and it.src:match("^https?://") then
        table.insert(out, { path=it.path or it.src, src=it.src })
      else
        local p = it.src or it.path
        if not p:match("^/") then p="/"..p end
        table.insert(out, { path=it.path or p, src = join(origin..(base or "")..p) })
      end
    end
  end
  return out
end

local function load_manifest(channel, role)
  local raw = http_get("https://raw.githubusercontent.com/karialo/CCraft/main/manifest.json")
  if not raw then return nil, "no-manifest" end
  local ok, man = pcall(jdec, raw)
  if not ok or type(man)~="table" then return nil, "bad-json" end

  local origin = man.origin or "https://raw.githubusercontent.com/karialo/CCraft/main"
  local base   = man.base or ""

  local roles_tbl
  if type(man.channels)=="table" then
    local ch = man.channels[channel or "stable"]
    roles_tbl = ch and type(ch.roles)=="table" and ch.roles or nil
  elseif type(man.roles)=="table" then
    roles_tbl = man.roles
  end
  if type(roles_tbl)~="table" then return nil, "no-roles" end

  local items = roles_tbl[role]
  if type(items)~="table" then return nil, "no-role" end

  return normalize_items(origin, base, items), (man.version or "0.0.0")
end

-- ===== runner (fully guarded) =====
local ok, err = pcall(function()
  -- Always ensure /startup exists (requested)
  if not fs.exists("/startup") then fs.makeDir("/startup") end

  local cfg = readTbl(CFG)
  local role    = cfg.role or (turtle and "turtle" or (pocket and "tablet" or "pc"))
  local channel = cfg.channel or "stable"

  local list, ver = load_manifest(channel, role)
  if not list then
    log("[K.A.R.I] updater: manifest missing for ", role, "/", channel)
    return
  end

  log("[K.A.R.I] Updating ", channel, "/", role, " (", #list, " files)")
  local okc, failc = 0, 0

  for _,it in ipairs(list) do
    log("GET ", it.src, " ...")
    local body = http_get(it.src)
    if body then
      if needsUpdate(it.path, body) then
        mkdir(it.path)
        local h=fs.open(it.path,"w"); h.write(body); h.close()
        log("  updated: ", it.path)
      else
        log("  ok:      ", it.path)
      end
      okc = okc + 1
    else
      log("  failed:  ", it.path)
      failc = failc + 1
    end
  end

  log(string.format("[K.A.R.I] %s manifest applied. (v%s/%s) ok=%d fail=%d",
    role, ver, channel, okc, failc))
end)

if not ok then
  -- Never rethrow; just print once.
  print("[K.A.R.I] updater error: "..tostring(err))
end
