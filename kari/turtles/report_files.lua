local function walk(dir, base, out)
  base=base or ""; out=out or {}
  for _,name in ipairs(fs.list(dir)) do
    local p=fs.combine(dir,name); local rel=fs.combine(base,name)
    if fs.isDir(p) then walk(p, rel, out)
    else local h=fs.open(p,"r"); local s=h.readAll(); h.close(); table.insert(out,{path=rel,bytes=#(s or "")}) end
  end
  return out
end
local h=fs.open("/kari/data/remote.cfg","r"); local cfg=textutils.unserialize(h.readAll()); h.close()
local payload = { turtle_id=tostring(os.getComputerID()), files=walk("/kari") }
local json = textutils.serializeJSON and textutils.serializeJSON(payload) or textutils.serialize(payload)
http.post(cfg.base.."/api/report/files?t="..(cfg.token or ""), json, {["Content-Type"]="application/json"})
print("Reported file list.")
