-- /kari/ui/splash.lua — cinematic boot splash (CCTweaked/CC)
-- Usage:
--   local splash = dofile("/kari/ui/splash.lua")
--   splash.show{
--     title="K . A . R . I",
--     subtitle="Boot sequence",
--     info={{"ID","9001"},{"Role","pc"},{"Target","/kari/pc/agent.lua"},{"Server","unset"},{"Proto","kari.bus.v2"}},
--     steps=24
--   }

local M = {}

local function clamp(n,a,b) if n<a then return a elseif n>b then return b else return n end end
local function w_h() local w,h = term.getSize(); return w,h end
local function center(y, s)
  local w,_ = w_h()
  term.setCursorPos(math.max(1, math.floor((w-#s)/2)), y); term.write(s)
end

local function fill_row(y, bg)
  local w,_ = w_h()
  term.setBackgroundColor(bg); term.setTextColor(bg)
  term.setCursorPos(1,y); term.write(string.rep(" ", w))
end

local function drawGradientStripe(y, h, cols)
  for i=0,h-1 do
    local t = (#cols>1) and (i/(h-1)) or 0
    local idx = clamp(math.floor(t*(#cols-1))+1,1,#cols)
    fill_row(y+i, cols[idx])
  end
end

local function drawGlassPanel(y, h)
  local w,_ = w_h()
  -- body
  term.setBackgroundColor(colors.gray); term.setTextColor(colors.gray)
  for i=0,h-1 do term.setCursorPos(3,y+i); term.write(string.rep(" ", w-6)) end
  -- highlight top & shadow bottom
  term.setBackgroundColor(colors.lightGray); term.setCursorPos(3,y);     term.write(string.rep(" ", w-6))
  term.setBackgroundColor(colors.black);     term.setCursorPos(3,y+h-1); term.write(string.rep(" ", w-6))
end

local function drawTitle(title, subtitle, y)
  -- shadow
  term.setTextColor(colors.black); center(y+1, title)
  -- main
  term.setTextColor(colors.white); center(y, title)
  if subtitle and #subtitle>0 then
    term.setTextColor(colors.lightGray); center(y+2, subtitle)
  end
end

local function drawDivider(y)
  local w,_ = w_h()
  term.setTextColor(colors.lightGray); term.setCursorPos(4,y); term.write(string.rep("-", math.max(0, w-8)))
end

local function kvBlock(y, kv)
  term.setTextColor(colors.white)
  local w,_ = w_h()
  local x = 6
  for i,item in ipairs(kv) do
    term.setCursorPos(x, y+i-1)
    term.write(tostring(item[1])..": ")
    term.setTextColor(colors.cyan); term.write(tostring(item[2]))
    term.setTextColor(colors.white)
  end
end

local function progress(y, pct)
  pct = clamp(pct,0,1)
  local w,_ = w_h()
  local x = 6
  local width = w-12
  local fill = math.floor(width*pct)
  term.setCursorPos(x,y); term.setTextColor(colors.lightGray); term.setBackgroundColor(colors.black)
  term.write("["..string.rep(" ", width).."]")
  term.setCursorPos(x+1,y); term.setBackgroundColor(colors.green); term.write(string.rep(" ", fill))
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
end

local function scanline(y, h)
  local w,_ = w_h()
  for i=0,h-1 do
    term.setCursorPos(3, y+i)
    term.setTextColor(colors.gray)
    term.write(string.rep("\127", math.max(0, w-6))) -- soft sheen
    sleep(0.02)
  end
end

local function pulse(times, ms)
  for i=1,times do
    term.setTextColor((i%2==0) and colors.white or colors.lightGray)
    sleep((ms or 80)/1000)
  end
end

function M.show(opts)
  opts = opts or {}
  local title    = opts.title    or "K . A . R . I"
  local subtitle = opts.subtitle or "Boot sequence"
  local info     = opts.info     or {}
  local steps    = clamp(opts.steps or 20, 1, 60)

  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()

  -- neon rails
  local w,h = w_h()
  drawGradientStripe(1, 2, {colors.black, colors.gray, colors.lightGray})
  drawGradientStripe(h-1, 2, {colors.lightGray, colors.gray, colors.black})

  -- glass panel
  local panelY, panelH = 4, 11
  drawGlassPanel(panelY, panelH)

  -- title & info
  drawTitle(title, subtitle, panelY+1)
  drawDivider(panelY+3)
  if #info>0 then kvBlock(panelY+4, info) end

  -- animation: scanline + progress
  local barY = panelY+panelH-2
  progress(barY, 0)
  parallel.waitForAny(
    function() scanline(panelY+1, panelH-2) end,
    function() for i=1,steps do progress(barY, i/steps); sleep(0.03) end end
  )
  pulse(6, 80)
end

return M
