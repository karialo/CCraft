-- /kari/hub/hubctl.lua - tiny supervisor controller
local PROTO = (function()
  local unser = textutils.unserialize or textutils.unserialise
  if fs.exists("/kari/data/config") then
    local h=fs.open("/kari/data/config","r"); local s=h.readAll(); h.close()
    local t=unser(s); if type(t)=="table" and t.proto then return t.proto end
  end
  return "kari.bus.v2"
end)()

local action = ({...})[1]
if not action or not ({pause=true,resume=true,stop=true,status=true})[action] then
  print("Usage: hubctl <pause|resume|stop|status>")
  return
end

-- Open any modem
local opened=false
for _,s in ipairs({"left","right","top","bottom","front","back"}) do
  if peripheral.getType(s)=="modem" then
    if not rednet.isOpen(s) then pcall(rednet.open,s) end
    opened=true
  end
end
if not opened then print("No modem") return end

local function send(t)
  rednet.broadcast({proto=PROTO, type=t}, PROTO)
  if t=="svcd-status" then
    local id,msg,_ = rednet.receive(PROTO, 1.5)
    if id and type(msg)=="table" and msg.type=="svcd-status-reply" then
      print(("paused=%s  services=[%s]"):format(tostring(msg.paused), table.concat(msg.services or {},",")))
    else
      print("no reply")
    end
  else
    print("sent", t)
  end
end

if action=="pause"  then send("svcd-pause")
elseif action=="resume" then send("svcd-resume")
elseif action=="stop"   then send("svcd-stop")
elseif action=="status" then send("svcd-status")
end
