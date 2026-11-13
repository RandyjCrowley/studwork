--!nocheck
--!nolint DeprecatedApi
--[[
	The carry kit's shared helper copies must stay byte-identical: Carry/shared/CF.luau and
	Movement/shared/CF.luau (the tiny CFrame math), and Carry/shared/CastCache.luau and
	Movement/shared/CastCache.luau (cached RaycastParams). The modules never share Lua state, so each has
	its own copy. Change both or neither.
]]
local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
local fs = luneRequire("@lune/fs")

local CARRY = "packages/kits/carry/Carry/shared/CF.luau"
local MOVEMENT = "packages/kits/carry/Movement/shared/CF.luau"

describe("carry kit shared copies", function()
	it("CF.luau is identical in Carry and Movement", function()
		local carry, movement = fs.readFile(CARRY), fs.readFile(MOVEMENT)
		expect(#carry > 0).toBe(true)
		expect(carry == movement).toBe(true)
	end)
	it("CastCache.luau is identical in Carry and Movement", function()
		local carry = fs.readFile("packages/kits/carry/Carry/shared/CastCache.luau")
		local movement = fs.readFile("packages/kits/carry/Movement/shared/CastCache.luau")
		expect(#carry > 0).toBe(true)
		expect(carry == movement).toBe(true)
	end)
end)
