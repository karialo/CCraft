-- /kari/os/tablet_input.lua — minimal touch/mouse input shim for pocket/tablet
-- Usage: local input = require or dofile("/kari/os/tablet_input.lua"); input.loop(onTap)
-- onTap(btn, x, y) called on mouse/touch; return true to exit loop.

local M = {}

function M.loop(onTap)
  assert(type(onTap)=="function","onTap(btn,x,y) required")
  term.setCursorBlink(false)
  while true do
    local e,a,b,c = os.pullEvent()
    if e == "mouse_click" then
      if onTap(a,b,c) then return end
    elseif e == "terminate" then
      return
    end
  end
end

return M
