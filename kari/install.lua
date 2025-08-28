-- /install.lua — single-file bootstrapper (gets updater+boot from server)
-- Tailnet-friendly: token is optional; only add ?t= when provided

-- --------- DEFAULTS (edit these or override during install) ----------
local DEFAULT_BASE  = "http://your-host.ts.net:13337"   -- e.g. http://100.x.y.z:13337 or http://name.ts.net:13337
local DEFAULT_TOKEN = ""                                -- leave blank if your server doesn’t require auth

-- --------- UTILS ----------
local CFG = "/kari/data/config"
local REM = "/kari/data/remote.cfg"

local function has(p) return fs.exists(p) and not fs.isDir(p) end
local function mk(p) if not fs.exists(p) then fs.makeDir(p) end end
local function writeFile(path, data) mk(fs.getDir(path)); local h=fs.open(path,"w"); h.write(data); h.close() end
local function slowln(s,dt) dt=dt or 0.01 for i=1,#s do write(s:sub(i,i)); sleep(dt) end print() end
local function center(y,s) local w,_=term.getSize(); term.setCursorPos(math.max(1,math.floor((w-#s)/2)),y); term.write(s) end
local function trim(s) return (s or ""):gsub("^%s+",""):gsub("%s+$","") end

local function build_url(base, path, token)
  if not path:match("^/") then path="/"..path end
  local u = (base:gsub("/+$",""))..path
  if token and #token>0 then
    local sep = path:find("%?") and "&" or "?"
    u = u..sep.."t="..token
  end
  return u
end

local function fetch(base, token, path) -- path like "/kari/bin/update.lua" served by /files/
  if not http then return nil,"http disabled" end
  local url = build_url(base, "/files"..path, token)
  local headers = { ["User-Agent"]="KARI-Installer" }
  if token and #token>0 then headers["X-KARI-TOKEN"]=token end
  local r,err=http.get(url, headers); if not r then return nil,err or "net" end
  local s=r.readAll(); r.close(); return s
end

local function prompt_line(q, def)
  term.write(q)
  if def and #def>0 then term.write(" ["..def.."]") end
  term.write(": ")
  local v = read()
  v = trim(v)
  if v=="" then return def or "" end
  return v
end

-- --------- MENU ----------
local ROLES = {"turtle","tablet","hub","pc"}
local function drawMenu(title, items, idx)
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
  center(1,"K.A.R.I Installer"); center(2,title)
  local w,_=term.getSize(); local bx=3; local bw=w-6; local y=4
  local function line(t) term.setCursorPos(bx,y); term.write(t); y=y+1 end
  line("+"..string.rep("-",bw-2).."+")
  line("| Select device role"..string.rep(" ",bw-2-19).."|")
  line("+"..string.rep("-",bw-2).."+")
  for i,opt in ipairs(items) do
    local txt=(i==idx) and ("> "..opt.." <") or ("  "..opt.."  ")
    line("| "..txt..string.rep(" ",bw-4-#txt).." |")
  end
  line("+"..string.rep("-",bw-2).."+")
  line("| Up/Down to move, Enter select, Q |")
  line("+"..string.rep("-",bw-2).."+")
end

local function pickRole()
  local def = pocket and "tablet" or (turtle and "turtle" or "pc")
  local idx=1; for i,r in ipairs(ROLES) do if r==def then idx=i end end
  drawMenu("Detected: "..def, ROLES, idx)
  while true do
    local e,k=os.pullEvent("key")
    if k==keys.up   then idx=(idx<=1) and #ROLES or (idx-1); drawMenu("Detected: "..def, ROLES, idx)
    elseif k==keys.down then idx=(idx>=#ROLES) and 1 or (idx+1); drawMenu("Detected: "..def, ROLES, idx)
    elseif k==keys.enter then return ROLES[idx]
    elseif k==keys.q then return nil end
  end
end

-- --------- MAIN ----------
term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear(); term.setCursorPos(1,1)
local role = pickRole(); if not role then print("Installation cancelled."); return end

print()
slowln("Server settings (press Enter to accept defaults)")

-- let user override server base / token once; persists to /kari/data/remote.cfg
local base  = prompt_line("Base URL", DEFAULT_BASE)
local token = prompt_line("Auth token (optional)", DEFAULT_TOKEN)

-- build config EARLY so cfg exists before we add gps
local cfg = { role = role, channel = "stable" }

-- GPS host option
print()
slowln("Enable this device as a GPS beacon? [y/N]")
term.write("> ")
local ans = trim((read() or "")):lower()
if ans == "y" or ans == "yes" then
  slowln("Enter absolute world coords for this computer (X Y Z)")
  term.write("X: "); local gx = tonumber(read())
  term.write("Y: "); local gy = tonumber(read())
  term.write("Z: "); local gz = tonumber(read())
  if gx and gy and gz then
    cfg.gps = { host=true, x=gx, y=gy, z=gz }
  else
    slowln("Invalid coords; skipping GPS host")
    cfg.gps = { host=false }
  end
else
  cfg.gps = { host=false }
end

term.clear(); term.setCursorPos(1,1)
slowln("K.A.R.I Installer — Preparing…")
slowln("Device: "..role); print()

-- ensure dirs
mk("/kari"); mk("/kari/bin"); mk("/kari/boot"); mk("/kari/data")

-- write config & remote endpoint
writeFile(CFG, textutils.serialize(cfg))
writeFile(REM, textutils.serialize({ base = base, token = token, turtle_id = tostring(os.getComputerID()) }))

-- drop root bootstrap so CraftOS hands off to K.A.R.I
local BOOTSTRAP = [[
if fs.exists("/kari/boot/startup.lua") then
  shell.run("/kari/boot/startup.lua")
else
  term.setTextColor(colors.red); print("K.A.R.I boot missing. Run installer/sync."); term.setTextColor(colors.white)
end
]]
slowln("Writing: /startup.lua ..."); writeFile("/startup.lua", BOOTSTRAP); slowln("  DONE")

-- fetch REAL boot + updater from server (token optional)
local MUSTS = {
  { path="/kari/boot/startup.lua",  src="/kari/boot/startup.lua" },
  { path="/kari/bin/update.lua",    src="/kari/bin/update.lua"   },
}
for _,it in ipairs(MUSTS) do
  slowln("Downloading: "..it.path.." ...")
  local body,err=fetch(base, token, it.src)
  if body then writeFile(it.path, body); slowln("  DONE") else slowln("  FAILED ("..tostring(err or "net")..")") end
end

-- vibes-only preview
local PREVIEW = {
  turtle={"/kari/os/kari_lib.lua","/kari/turtles/agent.lua","/kari/turtles/report_files.lua","/kari/services/gpsd.lua"},
  tablet={"/kari/os/kari_lib.lua","/kari/os/main.lua","/kari/os/tablet_input.lua","/kari/services/pcd.lua","/kari/services/gpsd.lua"},
  hub   ={"/kari/os/kari_lib.lua","/kari/hub/hubd.lua","/kari/hub/svcd.lua","/kari/services/pcd.lua","/kari/services/gpsd.lua","/kari/os/main.lua"},
  pc    ={"/kari/os/kari_lib.lua","/kari/pc/agent.lua","/kari/pc/cfgfiles.lua","/kari/pc/report_files.lua","/kari/services/pcd.lua","/kari/services/gpsd.lua"},
}
print(); slowln("Preparing role manifest for ["..role.."]")
for _,p in ipairs(PREVIEW[role] or {}) do slowln("Downloading: "..p.." ... DONE", 0.004) end

-- first sync for real (so reboot is clean)
print(); slowln("Running first update for role '"..role.."'…")
shell.run("/kari/bin/update.lua","--sync")

print(); slowln("Installation complete. Reboot to enter role ["..role.."].")
