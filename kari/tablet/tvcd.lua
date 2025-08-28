-- /kari/pocket/tvcd.lua - tablet supervisor (pcd + main)
local function supervise(path, name)
  return function()
    local back=1
    while true do
      if not fs.exists(path) then print("[tvcd] missing:",path); sleep(3); back=1
      else
        print("[tvcd] start:",name,"(",path,")")
        local ok,err=pcall(function() shell.run(path) end)
        if ok then print("[tvcd] exit:",name,"OK; restart 1s"); back=1
        else print("[tvcd] crash:",name,tostring(err)); back=math.min(back*2,10) end
        sleep(back)
      end
    end
  end
end
local S={}
table.insert(S, supervise("/kari/services/pcd.lua","pcd"))
table.insert(S, supervise("/kari/os/main.lua","ui"))
parallel.waitForAll(table.unpack(S))
