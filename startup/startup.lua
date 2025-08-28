-- /startup.lua — K.A.R.I root shim
if fs.exists("/kari/boot/startup.lua") then
  shell.run("/kari/boot/startup.lua")
elseif fs.exists("/kari/os/boot.lua") then
  shell.run("/kari/os/boot.lua")
elseif fs.exists("/kari/os/main.lua") then
  shell.run("/kari/os/main.lua")
else
  print("K.A.R.I: no boot file found.")
end
