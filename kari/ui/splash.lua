-- after showing splash
local splash = require("/kari/ui/splash")
splash.show({
  role = role,
  title = "K . A . R . I",
  subtitle = "Boot sequence",
  info = {
    {"ID", os.getComputerID()},
    {"Role", role},
    {"Target", TARGET},
    {"Server", serverStr},
    {"Proto", cfg.proto or "kari.bus.v2"}
  },
  steps = 25
})

-- NEW: pause so the splash hangs around
sleep(3)

-- then clear + continue to main
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1,1)

-- hand off
shell.run(TARGET)
