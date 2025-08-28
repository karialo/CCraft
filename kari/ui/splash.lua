-- Cinematic splash (this *is* the boot banner)
if fs.exists("/kari/ui/splash.lua") then
  local splash = dofile("/kari/ui/splash.lua")   -- <- use dofile, not require
  local id = tostring(os.getComputerID() or "?")
  splash.show{
    role     = role,
    title    = "K . A . R . I",
    subtitle = "Boot sequence",
    info     = {
      {"ID", id},
      {"Role", role},
      {"Target", TARGET},
      {"Server", serverStr},
      {"Proto", protoStr},
    },
    steps    = 40,   -- slow the bar a bit (bigger = longer)
  }
  -- Let the splash linger on screen before any further output:
  sleep(3)
end

-- (Do NOT print Role/Server/Proto again here; let splash be the banner.)
-- Continue with radios/GPS/label, then directly handoff.
openWireless()

if rednet.host and type(rednet.host)=="function" then
  pcall(rednet.host, protoStr, (cfg.name or role or "kari"))
end

local wantGPS = (cfg.gps == true) or (type(cfg.gps)=="table" and (cfg.gps.enabled or cfg.gps.host)) or (role=="hub")
if wantGPS and fs.exists("/kari/services/gpsd.lua") then
  if shell.openTab then shell.openTab("/kari/services/gpsd.lua")
  else parallel.waitForAny(function() shell.run("/kari/services/gpsd.lua") end, function() sleep(0) end) end
end

setDefaultLabel(role)

-- Ensure target exists (one more sync if missing)
if not fs.exists(TARGET) then
  print("Attempting one more sync...")
  spinnerRun("Sync:", "/kari/bin/update.lua", "--sync")
  if not fs.exists(TARGET) then
    warn("Still missing: " .. TARGET)
    return
  end
end

-- Hand off to role program (no extra clear/prints needed; the role can clear)
shell.run(TARGET)
