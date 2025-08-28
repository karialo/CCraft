-- /kari/ui/splash.lua — cinematic boot splash (CCTweaked/CC)
-- Call:  local splash = dofile("/kari/ui/splash.lua"); splash.show{ title="K.A.R.I", subtitle="Console" }

local M = {}

local function clamp(n,a,b) if n<a then return a elseif n>b then return b else return n end end
local function center(y, s)
  local w,_ = term.getSize()
  term.setCursorPos(math.max(1, math.floor((w-#s)/2)), y); term.write(s)
end

local function drawGradientStripe(y, h, cols)
  local w,_ = term.getSize()
  for row = 0, h-1 do
    local t = #cols > 1 and (row/(h-1)) or 0
    local idx = clamp(math.floor(t*(#cols-1))+1, 1, #cols)
    term.setBackgroundColor(cols[idx]); term.setTextColor(cols[idx])
    term.setCursorPos(1, y+row); term.write(string.rep(" ", w))
  end
end

local function drawGlassPanel(y, h)
  local w,_ = term.getSize()
  local bg = colors.gray
  local hi = colors.lightGray
  local sh = colors.black
  -- body
  term.setBackgroundColor(bg); term.setTextColor(bg)
  for i=0,h-1 do term.setCursorPos(3,y+i); term.write(string.rep(" ", w-6)) end
  -- highlight & shadow edges
  term.setBackgroundColor(hi); term.setCursorPos(3,y);      term.write(string.rep(" ", w-6))
  term.setBackgroundColor(sh); term.setCursorPos(3,y+h-1);  term.write(string.rep(" ", w-6))
end

local function pulse(c1,c2,steps,ms)
  for i=1,steps do
    term.setTextColor((i%2==0) and c1 or c2)
    sleep(ms/1000)
  end
end

local function drawTitle(title, subtitle, y)
  local w,_ = term.getSize()
  -- drop shadow
  term.setTextColor(colors.black); term.setBackgroundColor(colors.transparent or colors.gray)
  center(y+1, title)
  -- main
  term.setTextColor(colors.white); center(y, title)
  if subtitle and #subtitle>0 then
    term.setTextColor(colors.lightGray); center(y+2, subtitle)
  end
end

local function drawDivider(y)
  local w,_ = term.getSize()
  term.setTextColor(colors.lightGray)
  term.setCursorPos(3,y); term.write(string.rep("-", w-6))
end

local function miniStats(y, kv)
  term.setTextColor(colors.white)
  local w,_ = term.getSize()
  local left = 6
  for i,item in ipairs(kv) do
    term.setCursorPos(left, y+i-1)
    term.write(item[1]..": ")
    term.setTextColor(colors.cyan); term.write(tostring(item[2]))
    term.setTextColor(colors.white)
  end
end

local function progress(y, pct)
  pct = clamp(pct,0,1)
  local w,_ = term.getSize()
  local x = 6
  local width = w-12
  local fill = math.floor(width*pct)
  term.setCursorPos(x,y); term.setTextColor(colors.lightGray); term.setBackgroundColor(colors.black)
  term.write("["..string.rep(" ", width).."]")
  term.setCursorPos(x+1,y); term.setBackgroundColor(colors.green); term.write(string.rep(" ", fill))
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
end

local function scanline(y, h)
  local w,_ = term.getSize()
  for i=0,h-1 do
    term.setCursorPos(3, y+i)
    term.setTextColor(colors.gray); term.write(string.rep("\127", w-6)) -- soft sheen
    sleep(0.02)
  end
end

function M.show(opts)
  opts = opts or {}
  local title    = opts.title    or "K . A . R . I"
  local subtitle = opts.subtitle or "Booting subsystem"
  local info     = opts.info     or {}
  local steps    = opts.steps    or 20

  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()

  -- top & bottom neon gradient bars
  drawGradientStripe(1, 2, {colors.black, colors.gray, colors.lightGray})
  local _,h = term.getSize()
  drawGradientStripe(h-1, 2, {colors.lightGray, colors.gray, colors.black})

  -- glass panel + title
  local panelY, panelH = 4, 10
  drawGlassPanel(panelY, panelH)
  drawTitle(title, subtitle, panelY+1)
  drawDivider(panelY+3)

  -- info block
  if #info>0 then miniStats(panelY+4, info) end

  -- progress + scan
  local barY = panelY+panelH-2
  progress(barY, 0)
  parallel.waitForAny(function() scanline(panelY+1, panelH-2) end, function()
    for i=1,steps do progress(barY, i/steps); sleep(0.03) end
  end)

  -- subtle pulse on title
  pulse(colors.white, colors.lightGray, 6, 80)

  -- clear the panel interior so caller can draw next UI
  -- (comment this out if you want the splash to remain)
  -- for r=0,panelH-1 do
  --   term.setBackgroundColor(colors.black)
  --   term.setCursorPos(1, panelY+r); term.write(string.rep(" ", 999))
  -- end
end

return M
