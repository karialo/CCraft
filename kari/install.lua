-- /kari/bin/update.lua — GitHub Raw updater for K.A.R.I
-- Pulls role/channel from /kari/data/config and syncs files listed in manifest.json

local JSON = textutils.unserialiseJSON or textutils.unserializeJSON
local function die(m) error("[update] "..tostring(m), 0) end

local CFG = "/kari/data/config"
local function read_cfg()
  if not fs.exists(CFG) then return {} end
  local h=fs.open(CFG,"r"); if not h then return {} end
  local s=h.readAll() or ""; h.close()
  local ok,t=pcall(function() return (JSON and JSON(s)) or {} end)
  return (ok and type(t)=="table") and t or {}
end

local function mkdirs(p)
  local parts={}; for s in p:gmatch("[^/]+") do parts[#parts+1]=s end
  local cur=""; for i=1,#parts-1 do
    cur=cur.."/"..parts[i]
    if cur~="" and not fs.exists(cur) then fs.makeDir(cur) end
  end
end

local function write_file(path,data)
  mkdirs(path)
  local h=fs.open(path,"w"); if not h then die("cannot write "..path) end
  h.write(data); h.close()
end

local function http_get(u,tries)
  tries=tries or 3
  for i=1,tries do
    local ok,res=pcall(http.get,u,{["User-Agent"]="KARI-Update/1.0"})
    if ok and res then
      local b=res.readAll() or ""; res.close()
      if #b>0 then return b end
    end
    sleep(0.3)
  end
  return nil
end

-- ---------- main ----------
local cfg=read_cfg()
local manifest_url = "https://raw.githubusercontent.com/karialo/CCraft/main/manifest.json"

local raw=http_get(manifest_url)
if not raw then die("Failed to fetch manifest") end
local m=JSON(raw); if type(m)~="table" then die("Invalid manifest JSON") end

local origin = m.origin or "https://raw.githubusercontent.com/karialo/CCraft/main"
local base   = m.base or ""
local channel= cfg.channel or "stable"
local role   = cfg.role or (turtle and "turtle" or "pc")

local roles_tbl = (((m.channels or {})[channel] or {}).roles) or {}
local files = roles_tbl[role]
if type(files)~="table" or #files==0 then die("No files for "..channel.."/"..role) end

-- NEW: ensure root /startup dir always exists
if not fs.exists("/startup") then fs.makeDir("/startup") end

print("[K.A.R.I] Updating "..channel.."/"..role.." ("..#files.." files)")
local okc,failc=0,0
for _,path in ipairs(files) do
  local url=(origin..(base or "")..path):gsub("([^:])//+","%1/")
  write("GET "..url.." ... ")
  local data=http_get(url)
  if data then
    write_file(path,data)
    print("ok")
    okc=okc+1
  else
    print("FAIL")
    failc=failc+1
  end
end
print("[K.A.R.I] Update done. ok="..okc.." fail="..failc)
