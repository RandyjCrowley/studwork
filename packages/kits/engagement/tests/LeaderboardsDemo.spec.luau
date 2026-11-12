--!nocheck
--[[
	The sandbox's Leaderboards wiring (examples/sandbox/modules/sandbox/server/DemoLeaderboards.luau):
	the real sandbox game on a sim server, block touches feed the daily board. (The currency board
	reads the Economy balance by itself.)
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local F = StudWork.test.sim

local SANDBOX = "examples/sandbox/default.project.json"

local function api(server)
	local ref
	for _, r in server.runtime.order do
		if r.name == "Leaderboards" then
			ref = r
		end
	end
	return server.runtime.apis[ref]
end

describe("sandbox DemoLeaderboards", function()
	it("block touches add up on the daily board and the coins board follows the balance", function()
		local world = F.world({ epoch = 19000 * 86400 + 12 * 3600 })
		local server = F.gameServer(world, SANDBOX)
		local p = server:join(701)
		assert(
			world:advanceUntil(function()
				return server:isLoaded(p)
			end, 30),
			"load"
		)
		world:advance(2)
		local lb = api(server)
		expect(select(2, lb.rank(p, "dailyTouches"))).toBe(0)
		server:update(p, function(sections)
			sections.sandbox.blockTouches += 3
		end)
		world:advance(130)
		local top = lb.top("dailyTouches")
		expect(#top.rows).toBe(1)
		expect(top.rows[1].userId).toBe(701)
		expect(top.rows[1].value).toBe(3)
		server:update(p, function(sections)
			sections.sandbox.blockTouches += 2
		end)
		world:advance(130)
		expect(lb.top("dailyTouches").rows[1].value).toBe(5)
	end)
end)
