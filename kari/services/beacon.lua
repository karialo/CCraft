-- /kari/services/beacon.lua — periodic status beats for non-turtles (PC/hub/tablet)

local unser     = textutils.unserialize or textutils.unserialise
local encJSON   = textutils.serializeJSON or function(x) return textutils.serialize(x) end
local decJSON   = textutils.unserializeJSON or unser
local function has(p) return fs.exists(p) and not fs.isDir(p) end
local function readTbl(p)
  if not has(p) then return {} end
  local h=fs.open(p,"r"); local s=h.readAll(); h.close()
  local ok,t=pcall(unser,s); return (ok and type(t)=="table") and t or {}
end

local CFG = "/kari/data/config"
local REM = "/kari/data/remote.cfg"
local cfg = readTbl(CFG)
local rc  = readTbl(REM)

-- prefer remote.cfg.base, fallback to config.server, default to local
local BASE  = rc.base or cfg.server or "http://127.0.0.1:13337"
-- token optional (Tailnet = none)
local TOKEN = rc.token or cfg.token or ""
local HEAD  = {["Content-Type"]="application/json", ["User-Agent"]="KARI-Beacon"}
if TOKEN ~= "" then HEAD["X-KARI-TOKEN"] = TOKEN end

local MYID  = tostring(os.getComputerID())
local role  = cfg.role or (turtle and "turtle" or (pocket and "tablet" or "pc"))

local function safe_gps(t)
  if not gps or not gps.locate then return nil,nil,nil end
  local x,y,z = gps.locate(t or 1.0)
  return x,y,z
end

local function POST(p, body, tries)
  if not http then return end
  local url = BASE..p
  local data = encJSON(body)
  local lastErr
  tries = tries or 2
  for i=1,tries do
    local r = http.post(url, data, HEAD)
    if r then r.readAll(); r.close(); return true end
    lastErr = "net"; sleep(0.5 * i)
  end
  return false, lastErr
end

print("K.A.R.I beacon: online (role="..role..")")

local last=0
while true do
  local now = os.epoch("utc")
  if now-last >= 8000 then
    local x,y,z = safe_gps(1.2)
    local payload = {
      turtle_id = MYID,
      label     = os.getComputerLabel(),
      role      = role,
      version   = "1.0.0",
      fuel      = -1,  -- non-turtles
      pos       = (x and {x=x,y=y,z=z} or nil),
      programs  = {},
      gps_host  = (cfg.gps and cfg.gps.host) or false,
    }
    local ok,err = POST("/api/report/status", payload, 2)
    if not ok then print("beacon: post failed ("..tostring(err)..")") end
    last = now
  end
  sleep(0.5)
end
