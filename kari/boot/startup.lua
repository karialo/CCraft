-- /kari/boot/startup.lua - robust boot (ASCII safe) + updater self-heal + splash + radios + GPSD + role launch

-- ---------- config / utils ----------
local CFG = "/kari/data/config"
local REM = "/kari/data/remote.cfg"

local unser = textutils.unserialize or textutils.unserialise
local function has(p) return fs.exists(p) and not fs.isDir(p) end
local function mk(p) if not fs.exists(p) then fs.makeDir(p) end end

-- ascii-safe string + print
local function ascii(s)
  s = tostring(s or "")
  s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
  s = s
    :gsub("—","-"):gsub("–","-"):gsub("…","..."):gsub("•","*")
    :gsub("“","\""):gsub("”","\""):gsub("‘","'"):gsub("’","'")
  s = s:gsub("[^\n\r\t\032-\126]","?")
  return s
end
local _print = print
print = function(...)
  local t = {}
  for i=1,select("#", ...) do t[#t+1] = tostring(select(i, ...)) end
  _print(ascii(table.concat(t," ")))
end

local function safe_unser_file(path)
  if not fs.exists(path) then return {} end
  local h=fs.open(path,"r"); local s=h.readAll(); h.close()
  local ok,t=pcall(unser,s); return (ok and type(t)=="table") and t or {}
end

local function safe_read_cfg() return safe_unser_file(CFG) end
local function safe_read_remote() return safe_unser_file(REM) end

local function setfg(bg,fg) term.setBackgroundColor(bg); term.setTextColor(fg) end
local function cls() setfg(colors.black,colors.white); term.clear(); term.setCursorPos(1,1) end
local function slow(s,dt) dt=dt or 0.01 for i=1,#s do write(s:sub(i,i)); sleep(dt) end print() end
local function warn(msg) term.setTextColor(colors.red); print(msg); term.setTextColor(colors.white) end

local function openWireless()
  local opened=false
  for _,s in ipairs({"left","right","top","bottom","front","back"}) do
    if peripheral.getType(s)=="modem" then
      if not rednet.isOpen(s) then pcall(rednet.open,s) end
      opened=true
    end
  end
  if not opened then warn("No wireless modem detected.") end
  return opened
end

local function spinnerRun(label, cmd, ...)
  local args={...}
  local w,_=term.getSize()
  term.setCursorPos(1,2); print(string.rep("-", w))
  term.setCursorPos(1,3); write(label .. " ")
  local phases={"|","/","-","\\"}; local i=1; local done=false; local ok=false
  local function spin()
    while not done do
      term.setCursorPos(#label+2,3); write(phases[i]); i=(i%#phases)+1
      sleep(0.1)
    end
  end
  local function runit() ok=shell.run(cmd, table.unpack(args)); done=true end
  parallel.waitForAny(spin, runit)
  term.setCursorPos(#label+2,3); write(ok and "[OK]" or "[ERR]"); print()
  return ok
end

local function setDefaultLabel(role)
  if not os.getComputerLabel() then
    local base = (role or "kari") .. "-" .. tostring(os.getComputerID())
    pcall(os.setComputerLabel, base)
  end
end

-- Helpful wget hints
local function show_wget_hints()
  local base = "https://raw.githubusercontent.com/karialo/CCraft/main"
  print()
  print("Tip: fetch the installer or updater with wget:")
  print("  wget \""..base.."/install.lua\" install.lua")
  print("  wget \""..base.."/kari/bin/update.lua\" /kari/bin/update.lua")
  print()
  print("Then run:  install   OR   /kari/bin/update.lua --sync")
end

local function fetch(url)
  if not http then return nil,"http disabled" end
  local ok,res=pcall(http.get,url,{["User-Agent"]="KARI-Boot"})
  if ok and res then local b=res.readAll() or ""; res.close(); if #b>0 then return b end end
  return nil,"net"
end

-- ---------- boot ----------
cls(); slow("K.A.R.I OS - initializing...")

-- Ensure /startup dir exists (used for root scripts if any)
if not fs.exists("/startup") then fs.makeDir("/startup") end

-- Must have updater (self-heal if missing)
if not has("/kari/bin/update.lua") then
  warn("Missing /kari/bin/update.lua (updater). Attempting to fetch from GitHub...")
  local url="https://raw.githubusercontent.com/karialo/CCraft/main/kari/bin/update.lua"
  local body,err = fetch(url)
  if body then
    mk("/kari/bin")
    local h=fs.open("/kari/bin/update.lua","w"); h.write(body); h.close()
    print("Updater installed from GitHub.")
  else
    warn("Failed to fetch updater ("..tostring(err)..").")
    show_wget_hints()
    return
  end
end

-- First sync (allows installer to drop just startup + updater)
spinnerRun("Running updater:", "/kari/bin/update.lua", "--first-boot")

-- Resolve role/target
local cfg  = safe_read_cfg()
local role = cfg.role or (turtle and "turtle" or (pocket and "tablet" or "pc"))

-- >>> Cinematic splash (after we know role/ID/label)
if fs.exists("/kari/ui/splash.lua") then
  local splash = dofile("/kari/ui/splash.lua")
  local id = tostring(os.getComputerID() or "?")
  splash.show{
    title    = "K . A . R . I",
    subtitle = "Booting "..role,
    info     = {
      {"ID", id},
      {"Role", role},
      {"Label", os.getComputerLabel() or "unset"},
    },
    steps    = 20,
  }
end

-- Prefer supervisor for hub so daemons auto-restart
local TARGET = ({
  turtle = "/kari/turtles/agent.lua",
  tablet = "/kari/tablet/tvcd.lua",
  pc     = "/kari/pc/agent.lua",
  hub    = "/kari/hub/svcd.lua",
})[role] or "/kari/os/main.lua"

-- Radios first
openWireless()

-- Optional: register hostname for discovery (CCTweaked has rednet.host)
if rednet.host and type(rednet.host)=="function" then
  pcall(rednet.host, cfg.proto or "kari.bus.v2", (cfg.name or role or "kari"))
end

-- Launch GPS daemon if config says so (or always for hub)
local wantGPS = (cfg.gps == true) or (type(cfg.gps)=="table" and (cfg.gps.enabled or cfg.gps.host)) or (role=="hub")
if wantGPS and has("/kari/services/gpsd.lua") then
  if shell.openTab then shell.openTab("/kari/services/gpsd.lua")
  else parallel.waitForAny(function() shell.run("/kari/services/gpsd.lua") end, function() sleep(0) end) end
end

-- Set a sensible default label
setDefaultLabel(role)

-- Ensure target exists, try one more sync if not
if not has(TARGET) then
  warn("Role program missing: " .. TARGET)
  print("Attempting one more sync...")
  spinnerRun("Sync:", "/kari/bin/update.lua", "--sync")
  if not has(TARGET) then
    warn("Still missing: " .. TARGET)
    show_wget_hints()
    return
  end
end

-- Banner
local rc = safe_read_remote()
local serverStr = rc.base or cfg.server or "unset"
print(("Role: %s   Target: %s"):format(role, TARGET))
print(("Server: %s"):format(tostring(serverStr)))
print(("Proto: %s"):format(tostring(cfg.proto or "kari.bus.v2")))
print(string.rep("-", 40))

-- Handoff
shell.run(TARGET)
