--!nocheck
-- (v1.7.0) h:addPlayer returns what a live Player looks like to the Luau type checks that code
-- writes: type() is "userdata", typeof() is "Instance", :IsA("Player") is true. A check written
-- `type(player) == "table"` then fails in a spec, as it does in a server (the one that refused every
-- real player in Notifications.suggestOptIn passed every spec while the players were tables).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Harness = StudWork.test

local function boot(opts: any?): any
	local o = opts or {}
	o.modules = o.modules or {}
	return Harness.harness(o)
end

describe("instance players (harness)", function()
	it("are userdata Instances by default", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1, name = "Ada" })
		expect(type(p)).toBe("userdata")
		expect(typeof(p)).toBe("Instance")
		expect(p:IsA("Player")).toBe(true)
		expect(p.UserId).toBe(1)
		expect(p.Name).toBe("Ada")
		expect(tostring(p)).toBe("Ada")
		expect(h.players[1]).toBe(p)
	end)

	it("still work as keys, kick targets and replication owners", function()
		local h = boot()
		local p = h:addPlayer({ userId = 2 })
		expect(h:addPlayer({ userId = 2 })).toBe(p)
		p:Kick("bye")
		expect(p.kicked).toBe("bye")
		expect(game:GetService("Players"):GetPlayerByUserId(2)).toBe(p)
	end)

	it("instancePlayers = false gives the old plain table", function()
		local h = boot({ instancePlayers = false })
		local p = h:addPlayer({ userId = 3 })
		expect(type(p)).toBe("table")
	end)

	it('a type() == "table" gate refuses them, so a spec using one fails', function()
		local h = boot()
		local p = h:addPlayer({ userId = 4 })
		local function naive(player: any): boolean
			return type(player) == "table"
		end
		expect(naive(p)).toBe(false)
	end)
end)
