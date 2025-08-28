-- /kari/hub/hubd.lua - K.A.R.I Hub Daemon (Tailnet-safe, resilient, ASCII logging)

-- ===== Protocols ============================================================
local PROTO_MAIN = "kari.bus.v2"
local PROTOS     = { PROTO_MAIN, "kari.bus", "kari", "kari.install", "kari.setup", "kari.discover" }
local DISCOVER   = "kari.discover"

-- ===== Paths ================================================================
local LOG     = "/kari/log/hubd.log"
local RUN_DIR = "/kari/run"
local BEAT    = RUN_DIR.."/hubd.heart"
local REGFILE = RUN_DIR.."/registry.sr"

-- ===== Logging ==============================================================
local function ascii(s)
  s = tostring(s or "")
  return s:gsub("[^\n\r\t\032-\126]", "?")
end
local function ts()  return textutils.formatTime(os.time(), true) end
local function now() return os.epoch("utc") end
local function logln(...)
  local msg=""
  for i=1,select("#", ...) do msg = msg.." "..tostring(select(i,...)) end
  local line = ("[%s] %s"):format(ts(), ascii(msg))
  local ok,h=pcall(fs.open,LOG,"a"); if ok and h then h.writeLine(line); h.close() end
end

-- ===== Prep dirs ============================================================
local function ensureRun()
  if not fs.exists("/kari/log") then pcall(fs.makeDir,"/kari/log") end
  if not fs.exists(RUN_DIR) then pcall(fs.makeDir,RUN_DIR) end
end

-- ===== Config (remote.cfg preferred) ========================================
local unser = textutils.unserialize or textutils.unserialise
local function loadCfg()
  if fs.exists("/kari/data/remote.cfg") then
    local h=fs.open("/kari/data/remote.cfg","r"); local s=h.readAll(); h.close()
    local t=unser(s); if type(t)=="table" and t.base then return {base=t.base, token=t.token or ""} end
  end
  if fs.exists("/kari/data/config") then
    local h=fs.open("/kari/data/config","r"); local s=h.readAll(); h.close()
    local t=unser(s); if type(t)=="table" and t.server then return {base=t.server, token=t.token or ""} end
  end
end
local CFG = loadCfg()
local HTTP_ENABLED = http ~= nil
if not CFG then logln("WARN: no remote.cfg/config; server mirror disabled") end
if not HTTP_ENABLED then logln("WARN: HTTP disabled") end

-- ===== HTTP Bridge ==========================================================
local function jenc(x)
  return (textutils.serializeJSON and textutils.serializeJSON(x)) or textutils.serialize(x)
end
local function POST(path, body)
  if not (CFG and HTTP_ENABLED) then return false, "no-http-or-config" end
  local url = CFG.base .. path
  local hdr = {["Content-Type"]="application/json"}
  if (CFG.token or "") ~= "" then hdr["X-KARI-TOKEN"]=CFG.token end
  local r = http.post(url, jenc(body), hdr)
  if not r then return false,"post-failed" end
  r.readAll(); r.close()
  return true
end

-- ===== Wireless =============================================================
local function openWireless()
  local sides={"left","right","top","bottom","front","back"}; local opened={}
  for _,s in ipairs(sides) do
    local t=peripheral.getType(s)
    if t and t:find("modem") and not rednet.isOpen(s) then pcall(rednet.open,s) end
    if rednet.isOpen(s) then opened[#opened+1]=s end
  end
  if #opened==0 then logln("WARN: no modem") else logln("Radios:", table.concat(opened,",")) end
  return #opened>0
end
local function hostAll(name)
  for _,p in ipairs(PROTOS) do if rednet.host then pcall(rednet.host, p, name) end end
end
local function writeBeat()
  local ok,h=pcall(fs.open,BEAT,"w"); if ok and h then h.write(tostring(now())); h.close() end
end

-- ===== Files to turtles =====================================================
local function startsWith(s,p) return type(s)=="string" and s:sub(1,#p)==p end
local DENY={ "/kari/log", "/kari/run" }
local function canServe(path)
  if not startsWith(path,"/kari/") then return false end
  for _,d in ipairs(DENY) do if startsWith(path,d) then return false end end
  return fs.exists(path) and not fs.isDir(path)
end
local function sendFile(id,path,proto)
  if not canServe(path) then
    rednet.send(id,{proto=PROTO_MAIN,type="file",path=path,err="not found"},proto); return
  end
  local h=fs.open(path,"r"); if not h then return end
  local data=h.readAll() or ""; h.close()
  local CH=24*1024; local sz=#data; local sent=0; local part=1
  while sent<sz do
    local n=math.min(CH,sz-sent); local chunk=data:sub(sent+1,sent+n); sent=sent+n
    rednet.send(id,{proto=PROTO_MAIN,type="file",path=path,part=part,last=(sent>=sz),data=chunk,size=sz},proto)
    part=part+1; sleep(0)
  end
end

-- ===== Manifest =============================================================
local function present(p) if fs.exists(p) then return {path=p,file=p} end end
local function compact(t) local o={} for _,v in ipairs(t) do if v then o[#o+1]=v end end return o end
local function manifestForRole(role)
  local r=(role or "pc"):lower()
  if r=="turtle" then
    return { profile="turtle", programs=compact{present("/kari/turtles/agent.lua")}}
  elseif r=="tablet" or r=="pc" then
    return { profile=r, programs=compact{present("/kari/os/main.lua"), present("/kari/services/pcd.lua")}}
  else
    return { profile="hub", programs=compact{
      present("/kari/hub/hubd.lua"), present("/kari/hub/svcd.lua"),
      present("/kari/services/pcd.lua"), present("/kari/services/gpsd.lua"),
      present("/kari/os/main.lua")}}
  end
end

-- ===== Registry & Mirror ====================================================
local function saveRegistry(REG)
  local ok,h=pcall(fs.open,REGFILE,"w"); if ok and h then
    h.write(textutils.serialize(REG)); h.close()
  end
  if CFG and HTTP_ENABLED then
    for id,info in pairs(REG) do
      local payload = {
        turtle_id = tostring(id),
        label     = info.label, role=info.role, status=info.status, task=info.task,
        hub_id    = os.getComputerID(), source="hubd"
      }
      POST("/api/report/status", payload)
    end
  end
end

-- ===== Main Loop ============================================================
local function main()
  ensureRun()
  print("HubD starting…")
  while not openWireless() do sleep(1) end
  hostAll(os.getComputerLabel() or "hub")
  logln("HubD ONLINE id="..os.getComputerID())

  local REG={} ; local RUN=true
  local tBeat=os.startTimer(5); local tBeacon=os.startTimer(5)
  local tClean=os.startTimer(60); local tRehost=os.startTimer(30)

  local function touch(id,role,label,status,task)
    local r=REG[id] or {}
    if role then r.role=role end
    if label then r.label=label end
    if status then r.status=status end
    if task then r.task=task end
    r.last=now(); REG[id]=r; saveRegistry(REG)
  end

  while RUN do
    local e,a,b,c=os.pullEvent()
    if e=="rednet_message" then
      local from,msg,proto=a,b,c
      if type(msg)=="table" then
        local t=msg.type
        if t=="register" then touch(from,msg.role,msg.label)
        elseif t=="heartbeat" then touch(from,msg.role,msg.label,msg.status,msg.task)
        elseif t=="manifest-request" then rednet.send(from,{proto=PROTO_MAIN,type="manifest-reply",manifest=manifestForRole(msg.role)},proto)
        elseif t=="get-file" and msg.path then sendFile(from,msg.path,proto)
        elseif t=="hubd-stop" then RUN=false; logln("STOP requested by",from)
        end
      elseif isDiscoverMsg(msg) then sendHubHello(from,proto) end
    elseif e=="timer" then
      if a==tBeat then writeBeat(); tBeat=os.startTimer(5)
      elseif a==tBeacon then for _,p in ipairs(PROTOS) do sendHubHello(nil,p) end; tBeacon=os.startTimer(5)
      elseif a==tClean then local cut=now()-600000; for id,info in pairs(REG) do if (info.last or 0)<cut then REG[id]=nil end end; saveRegistry(REG); tClean=os.startTimer(60)
      elseif a==tRehost then hostAll(os.getComputerLabel() or "hub"); tRehost=os.startTimer(30) end
    end
  end
  logln("HubD OFFLINE (loop exit)")
end

local ok,err=pcall(main)
if not ok then logln("HubD CRASH: "..tostring(err)); printError(err) end
