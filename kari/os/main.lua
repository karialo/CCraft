-- /kari/os/main.lua — role-aware splash UI (pc/tablet/hub)
local unser = textutils.unserialize or textutils.unserialise
local function has(p) return fs.exists(p) and not fs.isDir(p) end
local function readCfg()
  if not has("/kari/data/config") then return {} end
  local h=fs.open("/kari/data/config","r"); local s=h.readAll(); h.close()
  local ok,t=pcall(unser,s); return (ok and type(t)=="table") and t or {}
end
local role = readCfg().role or "pc"

local function center(y,s)
  local w,_=term.getSize()
  term.setCursorPos(math.max(1,math.floor((w-#s)/2)),y)
  term.write(s)
end

local function POST(p, body)
  return http.post("http://crawdad-close-alien.ngrok-free.app"..p,
    textutils.serializeJSON(body),
    {["Content-Type"]="application/json",["X-KARI-TOKEN"]="31qRc8S...CvKf9d1D"})
end

local function beat(role)
  local payload = {
    turtle_id = tostring(os.getComputerID()),
    label = os.getComputerLabel(),
    role = role, version = "1.0.0",
  }
  local r = POST("/api/report/status", payload); if r then r.readAll(); r.close() end
end

beat("pc")  -- or "tablet"/"hub"

term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
center(2,"K.A.R.I Console")
center(3,"Role: "..role)

if role=="tablet" and fs.exists("/kari/os/tablet_input.lua") then
  local input = dofile("/kari/os/tablet_input.lua")
  center(5,"Tap anywhere to ping HQ, Q to exit")
  local function onTap(btn,x,y)
    -- simple blink + message
    term.setCursorPos(1,7); term.clearLine(); print(("tap: btn=%s x=%d y=%d"):format(btn,x,y))
    return false
  end
  input.loop(onTap)
else
  center(5,"Press any key to continue…")
  os.pullEvent("key")
end

term.setCursorPos(1,9)
print("Goodbye from K.A.R.I UI.")
