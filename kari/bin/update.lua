-- /kari/bin/update.lua — GitHub Raw manifest updater (role-aware)
-- Usage: update.lua [--sync] [--first-boot] [--autoboot]

-- ===== config & utils =====
local CFG = "/kari/data/config"
local unser = textutils.unserialize or textutils.unserialise
local jdec  = textutils.unserialiseJSON or unser

local function has(p) return fs.exists(p) and not fs.isDir(p) end
local function mk(p) if not fs.exists(p) then fs.makeDir(p) end end
local function readTbl(path)
  if not has(path) then return {} end
  local h=fs.open(path,"r"); local s=h.readAll(); h.close()
  local ok,t=pcall(unser,s); return (ok and type(t)=="table") and t or {}
end

local function writeFile(path, data)
  mk(fs.getDir(path))
  local h=fs.open(path,"w"); h.write(data); h.close()
end

local function http_get(u, tries)
  tries=tries or 3
  for i=1,tries do
    local ok,res=pcall(http.get, u, {["User-Agent"]="KARI-Updater"})
    if ok and res then
      local b=res.readAll() or ""; res.close()
      if #b>0 then return b end
    end
    sleep(0.3)
  end
  return nil
end

local function needsUpdate(path, contents)
  if not has(path) then return true end
  local h=fs.open(path,"r"); local cur=h.readAll(); h.close()
  return cur ~= contents
end

local function header(tag, role, channel)
  local w,_=term.getSize()
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
  term.setCursorPos(1,1)
  print(("K.A.R.I Updater  [%s]"):format(tag or ""))
  print(("-"):rep(w))
  print(("role=%s  channel=%s"):format(tostring(role), tostring(channel)))
end

-- ===== manifest loader =====
local function normalize_items(origin, base, items)
  local out={}
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
  local manifest_url = "https://raw.githubusercontent.com/karialo/CCraft/main/manifest.json"
  local raw = http_get(manifest_url)
  if not raw then return nil, "cannot fetch manifest" end
  local man = jdec(raw)
  if type(man)~="table" then return nil, "bad manifest JSON" end

  local origin = man.origin or "https://raw.githubusercontent.com/karialo/CCraft/main"
  local base   = man.base or ""

  local roles_tbl
  if type(man.channels)=="table" then
    local ch = man.channels[channel or "stable"]
    if not ch then return nil, "channel "..tostring(channel).." not found" end
    roles_tbl = (type(ch.roles)=="table") and ch.roles or nil
  else
    roles_tbl = (type(man.roles)=="table") and man.roles or nil
  end
  if not roles_tbl then return nil, "manifest missing roles" end

  local items = roles_tbl[role]
  if type(items)~="table" then return nil, "no role '"..tostring(role).."' in manifest" end

  local list = normalize_items(origin, base, items)
  return list, man.version or "0.0.0", origin, base
end

-- ===== runner =====
local args={...}
local mode = (args[1]=="--first-boot" and "first boot")
          or (args[1]=="--autoboot"   and "autoboot")
          or "--sync"

-- Clearer error if HTTP API is disabled in mod config
if not http then error("[update] HTTP API is disabled in config. Enable http in ComputerCraft/CCTweaked.", 0) end

local cfg = readTbl(CFG)
local role    = cfg.role or (turtle and "turtle" or (pocket and "tablet" or "pc"))
local channel = cfg.channel or "stable"
header(mode, role, channel)

-- Ensure a root /startup directory always exists (requested)
if not fs.exists("/startup") then fs.makeDir("/startup") end

local list,ver = load_manifest(channel, role)
if not list then
  print("Update incomplete: no manifest entries for "..role.." / "..channel)
  print("Check https://github.com/karialo/CCraft for manifest.json")
  return
end

local okc,failc=0,0
for _,it in ipairs(list) do
  write("GET "..it.src.." ... ")
  local body = http_get(it.src)
  if not body then
    print("FAIL")
    failc=failc+1
  else
    if needsUpdate(it.path, body) then
      writeFile(it.path, body)
      print("updated")
    else
      print("ok")
    end
    okc=okc+1
  end
end

print(("K.A.R.I %s manifest applied. (v%s/%s) ok=%d fail=%d")
  :format(role, ver, channel, okc, failc))
