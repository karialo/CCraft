-- ascii-safe logger
local function ascii(s)
  s = tostring(s or "")
  -- normalize Windows CRLF to LF
  s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
  -- replace common Unicode punctuation with ASCII
  s = s
    :gsub("—", "-"):gsub("–", "-"):gsub("…", "...")
    :gsub("“", "\""):gsub("”", "\""):gsub("‘", "'"):gsub("’", "'")
    :gsub("•", "*"):gsub("×", "x"):gsub("✓", "OK")
  -- drop any remaining non-ASCII
  s = s:gsub("[^\n\r\t\032-\126]", "?")
  return s
end

function loga(...)
  local parts = {}
  for i=1,select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  print(ascii(line))
end
