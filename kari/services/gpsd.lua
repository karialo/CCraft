-- /kari/services/gpsd.lua — simple GPS beacon host (self-contained)

local CFG = "/kari/data/config"

local unser = textutils.unserialize or textutils.unserialise
local function has(p) return fs.exists(p) and not fs.isDir(p) end

local function readCfg()
  if not has(CFG) then return {} end
  local h=fs.open(CFG,"r"); local s=h.readAll(); h.close()
  local ok,t=pcall(unser,s); return (ok and type(t)=="table") and t or {}
end

local function openWireless()
  for _,s in ipairs({"left","right","top","bottom","front","back"}) do
    if peripheral.getType(s)=="modem" and not rednet.isOpen(s) then pcall(rednet.open,s) end
  end
end

local function log(msg)
  local p="/kari/log/gpsd.log"
  fs.makeDir("/kari/log")
  local h=fs.open(p,"a")
  local ts = (textutils.formatTime and textutils.formatTime(os.time(), true)) or tostring(os.time())
  h.writeLine(("[%s] %s"):format(ts, tostring(msg)))
  h.close()
end

openWireless()

local cfg = readCfg() or {}
local g   = cfg.gps or {}

if not g.host then
  print("gpsd: disabled (cfg.gps.host=false)")
  log("disabled via config")
  return
end

local x,y,z
if type(g.pos)=="table" then x,y,z = tonumber(g.pos.x), tonumber(g.pos.y), tonumber(g.pos.z) end
if not (x and y and z) then
  print("gpsd: missing coords (cfg.gps.pos.x/y/z)")
  log("missing coords")
  return
end

-- Start hosting — blocks until shutdown; run in its own tab from startup.lua
local ok, err = pcall(function() gps.host(x,y,z) end)
if not ok then
  print("gpsd: error: "..tostring(err))
  log("error: "..tostring(err))
  return
end

print(("gpsd: hosting at %d,%d,%d"):format(x,y,z))
log(("hosting at %d,%d,%d"):format(x,y,z))

-- keep the process alive for logging/visibility
while true do sleep(5) end
