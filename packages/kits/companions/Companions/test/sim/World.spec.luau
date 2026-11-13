--!nocheck
local F = require("packages/framework/test/sim/Fixtures.luau")
local PROJECT = "packages/kits/companions/Companions/test/studio/default.project.json"
local function api(server, name)
	for _, ref in server.runtime.order do
		if ref.name == name then
			return server.runtime.apis[ref]
		end
	end
	error("missing module " .. name)
end
describe("Companions in the real server simulation", function()
	it("loads starter copies and rejects spoofing and duplicates across owners", function()
		local world = F.world()
		local server = F.gameServer(world, PROJECT)
		local p, q = server:join(9001), server:join(9002)
		assert(
			world:advanceUntil(function()
				return server:isLoaded(p) and server:isLoaded(q)
			end, 30),
			"players loaded"
		)
		local companions = api(server, "Companions")
		expect(#companions.equipped(p)).toBe(3)
		local own = companions.equipped(p)[1].uid
		local foreign = companions.equipped(q)[1].uid
		expect(select(2, companions.equip(p, foreign))).toBe("not_owned")
		expect(select(2, companions.equip(p, own))).toBe("already_equipped")
		local inventory = api(server, "Inventory")
		expect(inventory.transfer(p, q, own)).toBe(true)
		expect(#companions.equipped(p)).toBe(2)
		world:advance(1)
		expect(#world:errors()).toBe(0)
	end)
end)
