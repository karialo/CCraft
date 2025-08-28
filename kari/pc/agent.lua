-- /kari/pc/agent.lua — K.A.R.I PC Agent with TUI dashboard
-- Launches pcd.lua, registers with hub, and gives you a handy control panel.

local PROTO = "kari.bus.v2"
local TITLE = "K.A.R.I Console"

-- ---------- utils ----------
local function ascii(s)
  s = tostring(s or "")
  s = s:gsub("\r\n","\n"):gsub("\r","\n")
  s = s:gsub("—","-"):gsub("–","-"):gsub("…","...")
  s = s:gsub("“","\""):gsub("”","\""):gsub("‘","'"):gsub("’","'")
  return s:gsub("[^\n\r\t\032-\126]","?")
end

local function center(y, txt)
  local w,h = term.getSize()
  local s = ascii(tostring(txt))
  local x = math.max(1, math.floor((w - #s)/2)+1)
  term.setCursorPos(x, y); term.clearLine(); write(s)
end

local function banner()
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
  term.clear()
  center(1, TITLE)
  local w,h = term.getSize()
  term.setCursorPos(1,2); term.clearLine(); term.write(string.rep("-", w))
end

local function openWireless()
  local opened = {}
  for _,s in ipairs({"left","right","top","bottom","front","back"}) do
    if peripheral.getType(s) == "modem" and not rednet.isOpen(s) then
      pcall(rednet.open, s)
    end
    if rednet.isOpen(s) then opened[#opened+1] = s end
  end
  if rednet.host and #opened > 0 then
    pcall(rednet.host, PROTO, (os.getComputerLabel() or "pc"))
  end
  return opened
end

local function spawn_pcd()
  local path = "/kari/services/pcd.lua"
  if fs.exists(path) and not fs.isDir(path) then
    if shell.openTab then
      shell.openTab(path)
    else
      -- Fire-and-forget in this tab if needed
      parallel.waitForAny(function() shell.run(path) end, function() sleep(0) end)
    end
  end
end

local function register_with_hub()
  local payload = { proto=PROTO, type="register", role="pc", label=os.getComputerLabel() }
  pcall(rednet.broadcast, payload, PROTO)
end

-- ---------- hub helpers ----------
local function ping_hub()
  pcall(rednet.broadcast, {proto=PROTO,type="ping"}, PROTO)
end

local function ask_registry(timeout)
  timeout = timeout or 2.0
  local timer = os.startTimer(timeout)
  pcall(rednet.broadcast, {proto=PROTO,type="get-registry"}, PROTO)
  local out = nil
  while true do
    local e,a,b,c = os.pullEvent()
    if e=="timer" and a==timer then
      return nil, "timeout"
    elseif e=="rednet_message" then
      local _,msg,proto = a,b,c
      if proto==PROTO and type(msg)=="table" and (msg.type=="registry" or msg.type=="registry-reply") then
        out = msg
        break
      end
    end
  end
  return out
end

-- ---------- viewers ----------
local function list_view(title, lines)
  banner()
  center(3, title)
  local w,h = term.getSize()
  local top = 5
  local view_h = h - top - 1
  local off = 0

  local function redraw()
    for i=0,view_h-1 do
      term.setCursorPos(1, top+i)
      term.clearLine()
      local idx = off + i + 1
      if lines[idx] then
        write(ascii(lines[idx]))
      end
    end
    term.setCursorPos(1, h)
    term.clearLine()
    write("[Up/Down to scroll]  [Q to return]")
  end

  redraw()
  while true do
    local e,k = os.pullEvent("key")
    if k==keys.q then break
    elseif k==keys.up   then off = math.max(0, off-1); redraw()
    elseif k==keys.down then off = math.min(math.max(0,#lines-view_h), off+1); redraw()
    end
  end
end

local function show_registry()
  banner()
  center(3, "Querying hub registry…")
  local rep, err = ask_registry(3.0)
  if not rep or type(rep.list) ~= "table" then
    list_view("Registry (no reply: "..(err or "error")..")", {
      "No registry reply from any hub.",
      "",
      "Make sure a hub is online and in radio range.",
    })
    return
  end
  table.sort(rep.list, function(a,b) return (a.last or 0) > (b.last or 0) end)
  local lines = {}
  lines[#lines+1] = ("Hub ID: %s"):format(tostring(rep.hub_id or "?"))
  lines[#lines+1] = string.rep("-", 40)
  for _,e in ipairs(rep.list) do
    local last = math.floor(((os.epoch("utc") - (e.last or 0)))/1000)
    lines[#lines+1] = ("%s  id=%s  role=%s  last=%ss"):format(
      tostring(e.label or "-"), tostring(e.id or "?"), tostring(e.role or "?"), last
    )
    if e.status or e.task then
      lines[#lines+1] = ("   status=%s  task=%s"):format(tostring(e.status or "-"), tostring(e.task or "-"))
    end
  end
  if #rep.list==0 then
    lines[#lines+1] = "(empty)"
  end
  list_view("Registry", lines)
end

-- ---------- actions ----------
local function do_update()
  banner()
  center(3, "Updating…")
  term.setCursorPos(1,5)
  local ok,err = pcall(function() shell.run("/kari/bin/update.lua","--sync") end)
  print(ok and "Update complete." or ("Update failed: "..tostring(err)))
  print("")
  print("Press any key to return.")
  os.pullEvent("key")
end

local function show_modems(opened)
  opened = opened or {}
  local lines = { "Wireless modem sides:", string.rep("-", 24) }
  if #opened == 0 then
    lines[#lines+1] = "(none open)"
  else
    lines[#lines+1] = table.concat(opened, ", ")
  end
  list_view("Modems", lines)
end

-- ---------- menu ----------
local MENU = {
  { key="P", label="Ping hub",      run=function() ping_hub() end },
  { key="R", label="Show registry", run=show_registry },
  { key="U", label="Self-update",   run=do_update },
  { key="M", label="Show modem sides", run=function() show_modems(openWireless()) end },
  { key="Q", label="Quit to shell", run=function() error("quit", 0) end },
}

local function draw_menu()
  banner()
  local y = 4
  center(y, ("ID: %s   Label: %s"):format(os.getComputerID(), tostring(os.getComputerLabel() or "-"))); y=y+1
  center(y, "Press a key:"); y=y+1
  y=y+1
  for _,item in ipairs(MENU) do
    center(y, ("[%s] %s"):format(item.key, item.label))
    y = y + 1
  end
end

-- ---------- main ----------
local function main()
  -- radios + daemon + hello
  local opened = openWireless()
  spawn_pcd()
  register_with_hub()

  while true do
    draw_menu()
    local e,k = os.pullEvent("key")
    if e=="key" then
      local ch = keys.getName(k) or ""
      ch = ch:upper()
      for _,item in ipairs(MENU) do
        if ch == item.key then
          local ok,err = pcall(item.run)
          if not ok and tostring(err) ~= "quit" then
            banner()
            center(3, "Error: "..tostring(err))
            term.setCursorPos(1,5); print("Press any key to return.")
            os.pullEvent("key")
          elseif tostring(err) == "quit" then
            return
          end
          break
        end
      end
    end
  end
end

-- protect main so Ctrl+T etc. don’t spam
local ok,err = pcall(main)
if not ok and tostring(err) ~= "quit" then
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear(); term.setCursorPos(1,1)
  print("pc.agent crashed: "..tostring(err))
end
