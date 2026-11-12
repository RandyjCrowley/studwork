--!nocheck
-- Every kit client folder needs the declaration used by Runtime.defaultLoadClient.
local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
local fs = luneRequire("@lune/fs")

local function checkModules(root)
	for _, kit in fs.readDir(root) do
		local kitDir = root .. "/" .. kit
		if fs.isDir(kitDir) then
			for _, name in fs.readDir(kitDir) do
				local dir = kitDir .. "/" .. name
				if fs.isDir(dir) and fs.isDir(dir .. "/client") and fs.isFile(dir .. "/module.luau") then
					local source = fs.readFile(dir .. "/module.luau")
					local declared = string.match(source, '[\n\r]%s*client%s*=%s*"([%w_]+)"')
					expect(declared).toBe(name)
					expect(fs.isFile(dir .. "/client/init.luau")).toBe(true)
				end
			end
		end
	end
end

describe("kit client declarations", function()
	it("names each kit client folder so the runtime can load it", function()
		checkModules("packages/kits")
	end)
end)
