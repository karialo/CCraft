-- /kari/hub/svcd.lua - K.A.R.I Hub Supervisor with PAUSE/STOP controls + STATUS + HEART

local CFG  = "/kari/data/config"
local RUN  = "/kari/run"
local LOGD = "/kari/log"
local PAUSE_PATH = RUN.."/svcd.pause"
local STOP_PATH  = RUN.."/svcd.stop"
local HEART_PATH = RUN.."/svcd.heart"
local PROTO = "kari.bus.v2"
local unser = textutils.unserialize or textutils.unserialise

local function ascii(s)
  s = tostring(s or "")
  s = s:gsub("\r\n","\n"):gsub("\r","\n")
       :gsub("—","-"):gsub("–","-"):gsub("…","...")
       :gsub("“","\""):gsub("”","\""):gsub("‘","'"):gsub("’","'")
  return s:gsub("[^\n\r\t\032-\126]","?")
end
local _print = print
print = function(...) local t={} for i=1,select("#", ...) do t[#t+1]=tostring(select(i,...)) end _print(ascii(table.concat(t," "))) end

local function ensureRun()
  if not fs.exists(LOGD) then pcall(fs.makeDir,LOGD) end
  if not fs.exists(RUN)  then pcall(fs.makeDir,RUN)  end
end

local function readCfg()
  if not fs.exists(CFG) then return {} end
  local h=fs.open(CFG,"r"); local s=h.readAll(); h.close()
  local ok,t=pcall(unser,s); return (ok and type(t)=="table") and t or {}
end

local function gpsEnabled(cfg)
  cfg = cfg or readCfg()
  local g = cfg.gps
  return g == true or (type(g)=="table" and (g.enabled or g.host))
end

local function openWireless()
  local opened=false
  for _,s in ipairs({"left","right","top","bottom","front","back"}) do
    if peripheral.getType(s)=="modem" then
      if not rednet.isOpen(s) then pcall(rednet.open,s) end
      opened=true
    end
  end
  if rednet.host and opened then
    local c=readCfg()
    pcall(rednet.host, c.proto or PROTO, (c.name or "hub"))
  end
  return opened
end

local function paused() return fs.exists(PAUSE_PATH) end
local function stopped() return fs.exists(STOP_PATH) end

local function writeHeart()
  local ok,h=pcall(fs.open, HEART_PATH, "w"); if ok and h then h.write(tostring(os.epoch("utc"))); h.close() end
end

-- supervise a child: run, log exit/crash, backoff and restart unless paused/stop
local function supervise(path, name)
  return function()
    local backoff = 1
    while true do
      if stopped() then print("[svcd] STOP requested - supervisor exiting"); return end
      if paused() then
        print("[svcd] PAUSED - not starting", name)
        sleep(1)
      elseif not fs.exists(path) then
        print("[svcd] missing:", path, "(sleep 3)")
        sleep(3); backoff = 1
      else
        print("[svcd] start:", name, "(", path, ")")
        local ok, err = pcall(function() shell.run(path) end)
        if ok then
          print("[svcd] exit:", name, "OK")
          backoff = 1
        else
          print("[svcd] crash:", name, tostring(err))
          backoff = math.min(backoff * 2, 10)
          print("[svcd] backoff:", backoff, "s")
        end
        -- respect pause/stop before restarting
        local waited = 0
        while waited < backoff do
          if stopped() then print("[svcd] STOP requested - supervisor exiting"); return end
          if paused() then break end
          sleep(0.2); waited = waited + 0.2
        end
      end
    end
  end
end

-- control listener (rednet + terminate) + status replies
local function controlLoop()
  local proto = (readCfg().proto or PROTO)
  while true do
    local e,a,b,c = os.pullEvent()
    if e=="rednet_message" then
      local from,msg,rcvProto = a,b,c
      if rcvProto == proto and type(msg)=="table" then
        local t = tostring(msg.type or "")
        if t=="svcd-stop" then
          local f=fs.open(STOP_PATH,"w"); if f then f.close() end
          print("[svcd] STOP via rednet")
          return
        elseif t=="svcd-pause" then
          local f=fs.open(PAUSE_PATH,"w"); if f then f.close() end
          print("[svcd] PAUSE via rednet")
        elseif t=="svcd-resume" then
          if fs.exists(PAUSE_PATH) then fs.delete(PAUSE_PATH) end
          print("[svcd] RESUME via rednet")
        elseif t=="svcd-status" then
          local svc = {"hubd","pcd"}
          if gpsEnabled() and fs.exists("/kari/services/gpsd.lua") then table.insert(svc,"gpsd") end
          rednet.send(from, {proto=proto, type="svcd-status-reply", paused=paused(), services=svc}, proto)
        end
      end
    elseif e=="terminate" then
      local f=fs.open(STOP_PATH,"w"); if f then f.close() end
      print("[svcd] STOP via Ctrl+T")
      return
    end
  end
end

-- Banner
ensureRun()
-- one-shot STOP: clear stale stop file at boot so we can start normally
if fs.exists(STOP_PATH) then pcall(fs.delete, STOP_PATH) end

term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear(); term.setCursorPos(1,1)
print("K.A.R.I Hub Supervisor")
print(string.rep("-", 40))

-- Radios up
if not openWireless() then
  print("[svcd] WARNING: no wireless modem detected")
end

-- Build service set
local S = {}
table.insert(S, supervise("/kari/hub/hubd.lua", "hubd"))
table.insert(S, supervise("/kari/services/pcd.lua", "pcd"))
if gpsEnabled() and fs.exists("/kari/services/gpsd.lua") then
  print("[svcd] gpsd enabled by config")
  table.insert(S, supervise("/kari/services/gpsd.lua", "gpsd"))
else
  print("[svcd] gpsd disabled (enable in cfg.gps)")
end
print("[svcd] services:", #S)
print("[svcd] controls: PAUSE=", PAUSE_PATH, "  STOP=", STOP_PATH)

-- Heartbeat writer
local function heartLoop()
  while true do
    writeHeart()
    sleep(2)
  end
end

-- Run: control listener + services + heart
parallel.waitForAny(controlLoop, heartLoop, table.unpack(S))
print("[svcd] exiting")
