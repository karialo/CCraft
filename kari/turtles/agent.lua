-- /kari/turtles/agent.lua — K.A.R.I Turtle Agent (Tailnet-ready, low-traffic, resilient)

-- ===== ascii-safe logging =====
local function ascii(s)
  s = tostring(s or "")
  s = s:gsub("\r\n","\n"):gsub("\r","\n")
       :gsub("—","-"):gsub("–","-"):gsub("…","...")
       :gsub("“","\""):gsub("”","\""):gsub("‘","'"):gsub("’","'")
  return s:gsub("[^\n\r\t\032-\126]","?")
end
local function log(...) local t={} for i=1,select("#", ...) do t[#t+1]=tostring(select(i,...)) end print(ascii(table.concat(t," "))) end

-- ===== guards =====
if not http then error("http disabled") end

-- ===== helpers =====
local unser = textutils.unserialize or textutils.unserialise
local encJSON = textutils.serializeJSON or function(x) return textutils.serialize(x) end
local decJSON = textutils.unserializeJSON or unser
local function has(p) return fs.exists(p) and not fs.isDir(p) end

-- ===== config (remote.cfg preferred, fall back to config) =====
local function read_any_cfg()
  -- /kari/data/remote.cfg expected: { base="http://IP:13337", token="", name=?, turtle_id=? }
  if has("/kari/data/remote.cfg") then
    local h=fs.open("/kari/data/remote.cfg","r"); local s=h.readAll(); h.close()
    local t=unser(s); if type(t)=="table" and t.base then return t end
  end
  -- /kari/data/config legacy: { server="http://IP:13337", token="", name=?, role=? }
  if has("/kari/data/config") then
    local h=fs.open("/kari/data/config","r"); local s=h.readAll(); h.close()
    local t=unser(s); if type(t)=="table" and t.server then t.base=t.server; return t end
  end
  return {}
end

local RC     = read_any_cfg()
local BASE   = assert(RC.base,  "config missing 'base' (e.g., http://100.x.y.z:13337)")
local TOKEN  = (RC.token or "") -- optional on Tailnet
local MYID   = tostring(RC.turtle_id or os.getComputerID())
local NAME   = RC.name or os.getComputerLabel() or ("turtle-"..MYID)
local ROLE   = "turtle"

-- ===== HTTP wrappers (token optional) =====
local USER_AGENT = "KARI-Turtle-Agent/1"
local function _headers(extra)
  local h = { ["Content-Type"]="application/json", ["User-Agent"]=USER_AGENT }
  if TOKEN ~= "" then h["X-KARI-TOKEN"] = TOKEN end
  if extra then for k,v in pairs(extra) do h[k]=v end end
  return h
end

local function http_get(path, tries)
  tries = tries or 1
  local url = BASE..path
  local last
  for i=1,tries do
    local r = http.get(url, _headers{["Content-Type"]=nil})
    if r then return r end
    last = "net"; sleep(0.5 * i)
  end
  return nil, last
end

local function http_post(path, body_tbl, tries)
  tries = tries or 1
  local url = BASE..path
  local body = encJSON(body_tbl)
  local last
  for i=1,tries do
    local r = http.post(url, body, _headers())
    if r then return r end
    last = "net"; sleep(0.5 * i)
  end
  return nil, last
end

local function drain_close(r)
  if not r then return end
  pcall(function() r.readAll() end)
  pcall(function() r.close() end)
end

-- ===== telemetry =====
local function gps_pos(timeout)
  if not gps or not gps.locate then return nil end
  local ok,x,y,z = pcall(function() return gps.locate(timeout or 2.0) end)
  if ok and x and y and z then return {x=x,y=y,z=z} end
  return nil
end

local function fuel_level()
  if turtle and turtle.getFuelLevel then
    local f = turtle.getFuelLevel()
    if f ~= nil then return f end
  end
  return -1
end

local function programs_list()
  local ok, list = pcall(fs.list, "/kari/turtles")
  if not ok or not list then return nil end
  local out = {}
  for _,f in ipairs(list) do if f:match("%.lua$") then out[#out+1]=f end end
  table.sort(out); return out
end

-- ===== state compare =====
local function tables_eq(a,b)
  if a==b then return true end
  if type(a)~="table" or type(b)~="table" then return false end
  -- fast-ish compare via serialize (small payload)
  return textutils.serialize(a) == textutils.serialize(b)
end

-- ===== heartbeat =====
local last_sent, last_force_ts = nil, 0
local VER = (_G.kari_version or "dev")

local function build_status(currentJob)
  return {
    turtle_id = MYID,
    label     = NAME,
    role      = ROLE,
    version   = VER,
    fuel      = fuel_level(),
    pos       = gps_pos(2.2),         -- nil if unknown
    programs  = programs_list(),      -- optional
    task      = currentJob and (currentJob.cmd or currentJob.id) or nil,
  }
end

local function post_status(currentJob)
  local now = os.epoch("utc")
  local rec = build_status(currentJob)
  local must_send = (last_sent == nil) or (not tables_eq(rec, last_sent)) or ((now - last_force_ts) > 60000)
  if not must_send then return true end

  local r, err = http_post("/api/report/status", rec, 1)
  if not r then
    log("[agent] heartbeat failed:", tostring(err))
    return false
  end
  drain_close(r)
  last_sent = rec
  last_force_ts = now
  return true
end

-- ===== jobs =====
local function fetch_next_job()
  local r = http_get("/api/jobs/next?turtle_id="..MYID, 1)
  if not r then return nil, "net" end
  local s = r.readAll(); r.close()
  local ok, obj = pcall(decJSON, s)
  if not ok or type(obj) ~= "table" then return nil, "parse" end
  return obj.job
end

local function report(jid, tbl)
  local r = http_post("/api/jobs/"..jid.."/report", tbl, 1)
  drain_close(r)
end

local function run_program(cmd, args)
  local path = "/kari/turtles/"..cmd..".lua"
  if not has(path) then return false, "missing program: "..cmd end

  -- argv rules: args._order (keys), else ipairs array, else k/v pairs
  local argv = { path }
  if type(args) == "table" then
    if type(args._order) == "table" then
      for _,k in ipairs(args._order) do argv[#argv+1] = tostring(args[k]) end
    elseif args[1] ~= nil then
      for _,v in ipairs(args) do argv[#argv+1] = tostring(v) end
    else
      for k,v in pairs(args) do if k ~= "_order" then argv[#argv+1] = tostring(v) end end
    end
  end

  local ok, err = pcall(function() shell.run(table.unpack(argv)) end)
  return ok, err
end

-- ===== main loop =====
log("K.A.R.I turtle agent starting | id=", MYID, " base=", BASE, " token=", (TOKEN~="" and "set" or "empty"))

-- seed rand so multiple turtles don't sync-ping
math.randomseed(os.epoch("utc") % 2147483647)

-- initial heartbeat
post_status(nil)

local idlePoll = 10   -- seconds when idle
local busyPoll = 2    -- seconds while a job is active
local errBack  = 5    -- initial backoff on network error (doubles to 60)

while true do
  -- steady heartbeat (only on change, or every 60s)
  post_status(nil)

  -- poll jobs (low traffic)
  local job, jerr = fetch_next_job()
  if job then
    log("[agent] job claimed:", job.id, job.cmd or "?")
    post_status({id=job.id, cmd=job.cmd})
    report(job.id, {stage="start", ts=os.epoch("utc")})

    local ok, err
    if job.cmd == "update_self" then
      ok, err = pcall(function() shell.run("/kari/bin/update.lua","--sync") end)
    else
      ok, err = run_program(job.cmd, job.args or {})
    end

    if ok then
      report(job.id, {stage="done", final=true, status="done", ts=os.epoch("utc")})
      log("[agent] job done:", job.id)
    else
      report(job.id, {stage="error", error=tostring(err), final=true, status="error", ts=os.epoch("utc")})
      log("[agent] job error:", job.id, tostring(err))
    end

    -- heartbeat snapshot after job
    post_status(nil)
    sleep(busyPoll)

  else
    if jerr == "net" then
      log("[agent] jobs poll: network error; backoff ", errBack, "s")
      sleep(errBack); errBack = math.min(errBack * 2, 60)
    else
      -- no job; reset backoff and idle-snooze
      errBack = 5
      sleep(idlePoll + math.random()) -- tiny jitter
    end
  end
end
