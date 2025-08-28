-- /kari/bin/update.lua — Remote-manifest updater (role-aware, token-optional, resilient)
-- Usage: update.lua [--sync] [--first-boot] [--autoboot]

-- ===== config & utils =====
local CFG = "/kari/data/config"
local REM = "/kari/data/remote.cfg"

local unser = textutils.unserialize or textutils.unserialise
local jdec  = textutils.unserializeJSON or unser

local function has(p) return fs.exists(p) and not fs.isDir(p) end
local function mk(p) if not fs.exists(p) then fs.makeDir(p) end end
local function readAll(h) local s=h.readAll(); h.close(); return s end

local function readTbl(path)
  if not has(path) then return {} end
  local h=fs.open(path,"r"); local s=h.readAll(); h.close()
  local ok,t=pcall(unser,s); return (ok and type(t)=="table") and t or {}
end

local function writeFile(path, data)
  mk(fs.getDir(path)); local h=fs.open(path,"w"); h.write(data); h.close()
end

local function trim_trailing_slash(u)
  if not u or #u==0 then return u end
  return (u:gsub("/+$",""))
end

-- Pull base+token from remote.cfg if present; fall back to config/defaults
local cfg  = readTbl(CFG)
local rcfg = readTbl(REM)

-- >>> Set your tailnet default once and forget (edit host if you like)
local DEFAULT_BASE  = "http://your-host.ts.net:13337"   -- e.g. http://100.x.y.z:13337 or http://name.ts.net:13337
local DEFAULT_TOKEN = ""                                -- token optional; leave empty to rely on headerless public/dev server

local BASE  = trim_trailing_slash(rcfg.base or cfg.base or DEFAULT_BASE)
local TOKEN = rcfg.token or cfg.token or DEFAULT_TOKEN

-- legacy: if someone left the old ngrok http URL around, upgrade it silently to https
if type(BASE)=="string" and BASE:match("ngrok%-free%.app") and BASE:match("^http://") then
  BASE = BASE:gsub("^http://","https://")
end

local UA    = "KARI-Updater"
local function build_headers()
  local h = { ["User-Agent"]=UA }
  if TOKEN and #TOKEN > 0 then h["X-KARI-TOKEN"]=TOKEN end
  return h
end

-- Build absolute API URL; only append ?t= when TOKEN is present
local function url(path)
  if not path:match("^/") then path = "/"..path end
  if TOKEN and #TOKEN > 0 then
    local sep = path:find("%?") and "&" or "?"
    return BASE .. path .. sep .. "t=" .. TOKEN
  else
    return BASE .. path
  end
end

-- ---- HTTP helpers ----------------------------------------------------------
local function http_get_once(u, hdr)
  if not http then return nil, "http disabled" end
  local r = http.get(u, hdr)
  if not r then return nil, "net" end
  return readAll(r)
end

local function http_get(u, hdr)
  hdr = hdr or build_headers()
  -- try with our header first
  local body, err = http_get_once(u, hdr)
  if body then return body end
  -- headerless fallback (some proxies block custom headers)
  body, err = http_get_once(u, {["User-Agent"]=UA})
  if body then return body end
  -- one more tiny backoff with original headers
  sleep(0.3)
  body, err = http_get_once(u, hdr)
  return body, err
end

local function needsUpdate(path, contents)
  if not has(path) then return true end
  local h=fs.open(path,"r"); local cur=h.readAll(); h.close()
  return cur ~= contents
end

local function status(x) print(x) end
local function header(tag, role, channel)
  local w,_=term.getSize()
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
  term.setCursorPos(1,1); print(("K.A.R.I Updater  [%s]"):format(tag or "")); print(("-"):rep(w))
  if role or channel then
    print(("role=%s  channel=%s  base=%s"):format(tostring(role), tostring(channel), tostring(BASE)))
  end
end

-- ===== manifest loader =====
-- Manifest schema (JSON) expected at /manifest.json:
-- {
--   "version": "1.0.0",
--   "base": "/files",           // optional; default "/files"
--   "channels": {               // optional; else "roles" used directly
--     "stable": { "roles": { "turtle":[...], "hub":[...], ... } },
--     "nightly": { "roles": { ... } }
--   },
--   "roles": { "turtle":[ ... ], "hub":[ ... ], "pc":[ ... ], "tablet":[ ... ] }
-- }
--
-- Each role entry may be:
--   "/kari/os/main.lua"                              -- src==dest (served from <base> + same path)
--   {"path":"/kari/os/main.lua","src":"/kari/os/main.lua"}                (relative)
--   {"path":"/kari/os/main.lua","src":"https://example/raw.lua"}          (absolute)
local function normalize_items(base_path, items)
  local out={}
  for _,it in ipairs(items or {}) do
    if type(it)=="string" then
      table.insert(out, { path=it, src = (base_path..it) })
    elseif type(it)=="table" then
      if it.src and it.src:match("^https?://") then
        table.insert(out, { path=it.path or it.src, src = it.src })        -- absolute URL
      else
        local p = it.src or it.path
        if not p:match("^/") then p="/"..p end
        table.insert(out, { path=it.path or p, src = (base_path..p) })     -- relative under base_path
      end
    end
  end
  return out
end

local function load_manifest(channel, role)
  -- fetch server manifest (honor token if provided)
  local raw,err = http_get(url("/manifest.json"))
  if not raw then return nil, "manifest: "..tostring(err) end
  local man = jdec(raw)
  if type(man)~="table" then return nil, "manifest parse error" end

  local base_path = man.base or "/files"   -- where files are served on your server
  if not base_path:match("^/") then base_path="/"..base_path end

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
  if type(items)~="table" then return nil, "no manifest for role "..tostring(role) end

  local list = normalize_items(base_path, items)
  return list, man.version or "0.0.0"
end

-- ===== runner =====
local args={...}
local mode = (args[1]=="--first-boot" and "first boot") or (args[1]=="--autoboot" and "autoboot") or "--sync"

local role    = cfg.role or (turtle and "turtle" or (pocket and "tablet" or "pc"))
local channel = cfg.channel or "stable"
header(mode, role, channel)

local list,ver = load_manifest(channel, role)
if not list then
  print("Update incomplete: couldn't load manifest for role="..tostring(role).." channel="..tostring(channel))
  print("Tip: set /kari/data/remote.cfg with your Tailscale base, e.g.:")
  print('{ base = "http://your-host.ts.net:13337", token = "<optional>" }')
  return
end

for _,it in ipairs(list) do
  local body,err
  if it.src:match("^https?://") then
    -- absolute: still add headers (X-KARI-TOKEN when present)
    body,err = http_get(it.src, build_headers())
  else
    -- served by our Flask /files handler
    body,err = http_get(url(it.src))
  end
  if not body then
    status(("failed: %s (%s)"):format(it.path, err or "net"))
  else
    if needsUpdate(it.path, body) then
      writeFile(it.path, body); status("updated: "..it.path)
    else
      status("ok:      "..it.path)
    end
  end
end

print(("K.A.R.I %s manifest applied. (v%s/%s)"):format(role, ver, channel))
