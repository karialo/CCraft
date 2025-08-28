-- /kari/ui/splash.lua — cinematic boot splash with role-specific palettes
-- Usage:
--   local splash = dofile("/kari/ui/splash.lua")
--   splash.show{
--     role="pc",                          -- "pc" | "turtle" | "tablet" | "hub"
--     title="K . A . R . I",
--     subtitle="Boot sequence",
--     info={{"ID","9001"},{"Role","pc"},{"Target","/kari/pc/agent.lua"},{"Server","unset"},{"Proto","kari.bus.v2"}},
--     steps=24
--   }

local M = {}

-- ===== helpers =====
local function clamp(n,a,b) if n<a then return a elseif n>b then return n>b and b or n end end
local function w_h() local w,h=term.getSize(); return w,h end
local function center(y, s)
  local w,_=w_h()
  term.setCursorPos(math.max(1, math.floor((w-#s)/2)), y); term.write(s)
end
local function fill_row(y, bg)
  local w,_=w_h()
  term.setBackgroundColor(bg); term.setTextColor(bg)
  term.setCursorPos(1,y); term.write(string.rep(" ", w))
end
local function drawGradientStripe(y, h, cols)
  for i=0,h-1 do
    local t=(#cols>1) and (i/(h-1)) or 0
    local idx=math.max(1, math.min(#cols, math.floor(t*(#cols-1))+1))
    fill_row(y+i, cols[idx])
  end
end

-- ===== palettes =====
local P = {
  default = {
    rail_top   = {colors.black, colors.gray, colors.lightGray},
    rail_bot   = {colors.lightGray, colors.gray, colors.black},
    panel_main = colors.gray,
    panel_hi   = colors.lightGray,
    panel_sh   = colors.black,
    text_main  = colors.white,
    text_dim   = colors.lightGray,
    accent     = colors.green,   -- progress fill
  },
  pc = { -- steel blue vibes
    rail_top   = {colors.black, colors.blue, colors.lightBlue},
    rail_bot   = {colors.lightBlue, colors.blue, colors.black},
    panel_main = colors.gray,
    panel_hi   = colors.lightGray,
    panel_sh   = colors.black,
    text_main  = colors.white,
    text_dim   = colors.lightGray,
    accent     = colors.cyan,
  },
  turtle = { -- biohazard green
    rail_top   = {colors.black, colors.green, colors.lime},
    rail_bot   = {colors.lime, colors.green, colors.black},
    panel_main = colors.green,
    panel_hi   = colors.lime,
    panel_sh   = colors.black,
    text_main  = colors.white,
    text_dim   = colors.lightGray,
    accent     = colors.lime,
  },
  tablet = { -- amber glow
    rail_top   = {colors.black, colors.orange, colors.yellow},
    rail_bot   = {colors.yellow, colors.orange, colors.black},
    panel_main = colors.yellow,
    panel_hi   = colors.orange,
    panel_sh   = colors.brown,
    text_main  = colors.black,
    text_dim   = colors.gray,
    accent     = colors.red,
  },
  hub = { -- royal purple
    rail_top   = {colors.black, colors.purple, colors.magenta},
    rail_bot   = {colors.magenta, colors.purple, colors.black},
    panel_main = colors.purple,
    panel_hi   = colors.magenta,
    panel_sh   = colors.black,
    text_main  = colors.white,
    text_dim   = colors.lightGray,
    accent     = colors.lightGray,
  },
}

local function pick(role)
  role = tostring(role or ""):lower()
  return P[role] or P.default
end

-- ===== drawing =====
local function drawGlassPanel(y, h, pal)
  local w,_=w_h()
  -- body
  term.setBackgroundColor(pal.panel_main); term.setTextColor(pal.panel_main)
  for i=0,h-1 do term.setCursorPos(3,y+i); term.write(string.rep(" ", w-6)) end
  -- highlight & shadow
  term.setBackgroundColor(pal.panel_hi); term.setCursorPos(3,y);     term.write(string.rep(" ", w-6))
  term.setBackgroundColor(pal.panel_sh); term.setCursorPos(3,y+h-1); term.write(string.rep(" ", w-6))
end

local function drawTitle(title, subtitle, y, pal)
  term.setTextColor(colors.black); center(y+1, title)
  term.setTextColor(pal.text_main); center(y, title)
  if subtitle and #subtitle>0 then
    term.setTextColor(pal.text_dim); center(y+2, subtitle)
  end
end

local function drawDivider(y, pal)
  local w,_=w_h()
  term.setTextColor(pal.text_dim); term.setCursorPos(4,y); term.write(string.rep("-", math.max(0, w-8)))
end

local function kvBlock(y, kv, pal)
  term.setTextColor(pal.text_main)
  local x=6
  for i,item in ipairs(kv) do
    term.setCursorPos(x, y+i-1)
    term.write(tostring(item[1])..": ")
    term.setTextColor(pal.accent); term.write(tostring(item[2]))
    term.setTextColor(pal.text_main)
  end
end

local function progress(y, pct, pal)
  pct = clamp(pct,0,1)
  local w,_=w_h()
  local x=6
  local width=w-12
  local fill=math.floor(width*pct)
  term.setCursorPos(x,y); term.setTextColor(pal.text_dim); term.setBackgroundColor(colors.black)
  term.write("["..string.rep(" ", width).."]")
  term.setCursorPos(x+1,y); term.setBackgroundColor(pal.accent); term.write(string.rep(" ", fill))
  term.setBackgroundColor(colors.black); term.setTextColor(pal.text_main)
end

local function scanline(y, h, pal)
  local w,_=w_h()
  for i=0,h-1 do
    term.setCursorPos(3, y+i)
    term.setTextColor(pal.panel_sh)
    term.write(string.rep("\127", math.max(0, w-6)))
    sleep(0.02)
  end
end

local function pulse(times, ms, pal)
  for i=1,times do
    term.setTextColor((i%2==0) and pal.text_main or pal.text_dim)
    sleep((ms or 80)/1000)
  end
end

-- ===== API =====
function M.show(opts)
  opts = opts or {}
  local role     = opts.role     -- affects palette
  local pal      = pick(role)
  local title    = opts.title    or "K . A . R . I"
  local subtitle = opts.subtitle or "Boot sequence"
  local info     = opts.info     or {}
  local steps    = clamp(opts.steps or 20, 1, 60)

  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()

  local w,h = w_h()
  drawGradientStripe(1, 2, pal.rail_top)
  drawGradientStripe(h-1, 2, pal.rail_bot)

  local panelY, panelH = 4, 11
  drawGlassPanel(panelY, panelH, pal)
  drawTitle(title, subtitle, panelY+1, pal)
  drawDivider(panelY+3, pal)
  if #info>0 then kvBlock(panelY+4, info, pal) end

  local barY = panelY+panelH-2
  progress(barY, 0, pal)
  parallel.waitForAny(
    function() scanline(panelY+1, panelH-2, pal) end,
    function() for i=1,steps do progress(barY, i/steps, pal); sleep(0.03) end end
  )
  pulse(6, 80, pal)
end

return M
