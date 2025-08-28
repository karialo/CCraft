-- /kari/services/pcd.lua - K.A.R.I Presence/Heartbeat Daemon
-- Tailnet-friendly: token optional; low-traffic; robust backoff; GPS best-effort

-- ===== utils =====
local function ascii(s)
  s = tostring(s or "")
  s = s:gsub("\r\n","\n"):gsub("\r","\n")
       :gsub("—","-"):gsub("–","-"):gsub("…","...")
       :gsub("“","\""):gsub("”","\""):gsub("‘","'"):gsub("’","'")
  return s:gsub("[^\n\r\t\032-\126]","?")
end
local function log(...) local t={} for i=1,select("#", ...) do t[#t+1]=tostring(select(i,...)) end print(ascii(table.concat(t," "))) end

local function unser(s) return (textutils.unserialize or textutils.unserialise)(s) end
local function has(p) return fs.exists(p) and not fs.isDir(p) end

-- ===== config =====
local function read_cfg()
  -- prefer remote.cfg ({ base=..., token=..., name=?, role=? })
  if has("/kari/data/remote.cfg") then
    local h=fs.open("/kari/data/remote.cfg","r"); local s=h.readAll(); h.close()
    local t=unser(s); if type(t)=="table" and t.base then return t end
  end
  if has("/kari/data/config") then
    local h=fs.open("/kari/data/config","r"); local s=h.readAll(); h.close()
    local t=unser(s); if type(t)=="table" and t.server then
      t.base = t.server; return t
    end
  end
  return {}
end

local CFG = read_cfg()
local BASE = CFG.base or "http://127.0.0.1:13337"
local TOKEN = CFG.token or ""

-- ===== role + facts =====
local function detect_role()
  if turtle then return "turtle"
  elseif pocket then return "tablet"
  else
    -- If hub set in config, honor it
    local r = (type(CFG.role)=="string" and CFG.role:lower()) or nil
    if r=="hub" or r=="pc" then return r end
    return "pc"
  end
end

local ROLE = detect_role()
local NAME = (CFG.name or os.getComputerLabel() or ROLE)

local function fuel_level()
  if turtle and turtle.getFuelLevel then
    local f = turtle.getFuelLevel()
    if f then return f end
  end
  return -1
end

-- optional programs list if you maintain it elsewhere
local function read_programs()
  local p = "/kari/run/programs.sr"
  if has(p) then
    local h=fs.open(p,"r"); local s=h.readAll(); h.close()
    local t=unser(s); if type(t)=="table" then return t end
  end
  return nil
end

-- GPS best-effort (non-blocking-ish)
local function try_gps(timeout)
  timeout = timeout or 2.5
  if not gps or not gps.locate then return nil end
  local ok,x,y,z = pcall(function() return gps.locate(timeout) end)
  if ok and x and y and z then return {x=x,y=y,z=z} end
  return nil
end

-- ===== http helpers =====
local function to_json(tbl)
  if textutils.serializeJSON then
    local ok, s = pcall(textutils.serializeJSON, tbl)
    if ok and s then return s end
  end
  return textutils.serialize(tbl)
end

local function post_json(path, body_tbl)
  local url = BASE .. path
  local hdr = { ["Content-Type"]="application/json" }
  if TOKEN and TOKEN ~= "" then hdr["X-KARI-TOKEN"] = TOKEN end
  local ok, res = pcall(function()
    return http.post(url, to_json(body_tbl), hdr)
  end)
  if not ok or not res then return false, "http-failed" end
  local code = tonumber(res.getResponseCode and res.getResponseCode() or 0) or 0
  -- drain body to free handle
  pcall(function() res.readAll() end)
  pcall(function() res.close() end)
  if code >= 200 and code < 300 then return true
  elseif code == 401 then return false, "unauthorized"
  else return false, "status-"..code end
end

-- ===== state compare =====
local last_sent = nil
local function shallow_eq(a,b)
  if a==b then return true end
  if type(a)~="table" or type(b)~="table" then return false end
  for k,v in pairs(a) do
    local w=b[k]
    if type(v)=="table" and type(w)=="table" then
      if textutils.serialize(v) ~= textutils.serialize(w) then return false end
    else
      if v~=w then return false end
    end
  end
  for k,_ in pairs(b) do if a[k]==nil then return false end end
  return true
end

-- ===== main beat loop =====
local ID = tostring(os.getComputerID())
local VER = (_G.kari_version or "dev")

local HB_MIN   = 12      -- base seconds (randomized)
local HB_JIT   = 8       -- +/- jitter
local HB_FORCE = 60      -- send at least this often even if unchanged
local backoff  = 0       -- grows on errors, resets on success, max 60

local last_force_ts = 0

local function build_status()
  local pos = try_gps(CFG.gps_timeout or 2.5)
  local rec = {
    turtle_id = ID,
    label     = os.getComputerLabel(),
    role      = ROLE,
    version   = VER,
    fuel      = fuel_level(),
    pos       = pos,                  -- nil if unknown
    programs  = read_programs(),      -- optional
  }
  return rec
end

local function heartbeat()
  local now = os.epoch("utc")
  local rec = build_status()
  local must_send = false

  if not last_sent then must_send = true
  else
    must_send = not shallow_eq(rec, last_sent)
  end
  if (now - last_force_ts) > (HB_FORCE*1000) then must_send = true end

  if not must_send then return true end

  local ok, err = post_json("/api/report/status", rec)
  if ok then
    last_sent = rec
    last_force_ts = now
    if backoff > 0 then log("[pcd] heartbeat ok; clearing backoff") end
    backoff = 0
    return true
  else
    log("[pcd] heartbeat failed:", tostring(err))
    backoff = math.min((backoff==0 and 5 or backoff*2), 60) -- 5,10,20,40,60
    return false
  end
end

-- ===== run =====
log("K.A.R.I pcd starting | id=", ID, " role=", ROLE, " base=", BASE, " token=", (TOKEN~="" and "set" or "empty"))

math.randomseed(os.epoch("utc") % 2147483647)

while true do
  local ok = heartbeat()

  -- next sleep: normal cadence with jitter, or error backoff
  local wait
  if ok then
    wait = HB_MIN + math.random(0, HB_JIT)
    -- small random skew so a fleet doesn't sync
    wait = wait + (math.random() * 0.7)
  else
    wait = backoff
  end
  sleep(wait)
end
