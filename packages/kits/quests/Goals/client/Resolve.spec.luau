--!nocheck
-- Goals client target resolution (docs/framework/kits/quests.md, Goals "Target resolution and
-- StreamingEnabled"): instance / last known / fallback / none; path and picker targets; the tag
-- cache (GetTagged once, Added/Removed signals) and the nearest re-picked at most twice a second.
local Resolve = require("packages/kits/quests/Goals/client/Resolve.luau")
local GoalsClientEnv = require("packages/kits/quests/tests/GoalsClientEnv.luau")

local function setup()
	local E = GoalsClientEnv.new()
	E.env.pickers = {}
	return E, Resolve.new(E.env)
end

describe("Goals Resolve", function()
	it("a tag target: the nearest streamed-in instance", function()
		local E, r = setup()
		E:part("Far", 50, 3, 0, { "Coin" })
		E:part("Near", 5, 3, 0, { "Coin" })
		local pos, from = r:resolve("g", { tag = "Coin" }, nil, E.charPos)
		expect(from).toBe("instance")
		expect(pos.X).toBe(5)
	end)

	it("streamed out: the last known position, then fallback, then nothing", function()
		local E, r = setup()
		local coin = E:part("Coin1", 10, 3, 0, { "Coin" })
		local pos, from = r:resolve("g", { tag = "Coin" }, { 1, 2, 3 }, E.charPos)
		expect(from).toBe("instance")
		E:streamOut(coin)
		pos, from = r:resolve("g", { tag = "Coin" }, { 1, 2, 3 }, E.charPos)
		expect(from).toBe("lastKnown")
		expect(pos.X).toBe(10)

		-- never seen on this client: the fallback
		pos, from = r:resolve("other", { path = "Workspace.Tower" }, { 600, 3, 0 }, E.charPos)
		expect(from).toBe("fallback")
		expect(pos.X).toBe(600)

		-- nothing at all: pill only
		pos, from = r:resolve("none", { tag = "Nothing" }, nil, E.charPos)
		expect(pos).toBeNil()
		expect(from).toBeNil()
	end)

	it("a path target is found with FindFirstChild along the path", function()
		local E, r = setup()
		E:part("Guide", 7, 3, 1)
		local pos, from = r:resolve("p", { path = "Workspace.Guide" }, nil, E.charPos)
		expect(from).toBe("instance")
		expect(pos.X).toBe(7)
		pos, from = r:resolve("q", { path = "Workspace.Missing.Deeper" }, nil, E.charPos)
		expect(pos).toBeNil()
	end)

	it("a position target is always present", function()
		local E, r = setup()
		local pos, from = r:resolve("t", { position = { 600, 3, 0 } }, nil, E.charPos)
		expect(from).toBe("position")
		expect(pos.X).toBe(600)
	end)

	it("a position target and the fallback read both the array and the named form", function()
		local E, r = setup()
		local pos, from = r:resolve("n", { position = { x = 600, y = 3, z = -4 } }, nil, E.charPos)
		expect(from).toBe("position")
		expect(pos.X).toBe(600)
		expect(pos.Z).toBe(-4)
		pos, from = r:resolve("o", { position = { 1, 2, 3 } }, nil, E.charPos)
		expect(from).toBe("position")
		expect(pos.Y).toBe(2)
		-- the fallback goes through the same conversion
		pos, from = r:resolve("f1", { tag = "Nothing" }, { x = 7, y = 8, z = 9 }, E.charPos)
		expect(from).toBe("fallback")
		expect(pos.X).toBe(7)
		expect(pos.Z).toBe(9)
		pos, from = r:resolve("f2", { tag = "Nothing" }, { 4, 5, 6 }, E.charPos)
		expect(from).toBe("fallback")
		expect(pos.Y).toBe(5)
		-- neither form: nothing, not an error
		pos, from = r:resolve("bad", { position = { x = 1 } }, { x = "a" }, E.charPos)
		expect(pos).toBeNil()
		expect(from).toBeNil()
	end)

	it("a picker: a Vector3 or an instance, pcall'd", function()
		local E, r = setup()
		local crate = E:part("Crate", 4, 3, 4)
		E.env.pickers.vec = function()
			return Vector3.new(9, 3, 9)
		end
		E.env.pickers.inst = function()
			return crate
		end
		E.env.pickers.boom = function()
			error("picker failed")
		end
		local pos, from = r:resolve("a", { picker = "vec" }, nil, E.charPos)
		expect(from).toBe("instance")
		expect(pos.X).toBe(9)
		pos = r:resolve("b", { picker = "inst" }, nil, E.charPos)
		expect(pos.X).toBe(4)
		pos, from = r:resolve("c", { picker = "boom" }, nil, E.charPos)
		expect(pos).toBeNil()
		pos = r:resolve("d", { picker = "unknown" }, nil, E.charPos)
		expect(pos).toBeNil()
	end)

	it("tag cache: GetTagged once; Added/Removed keep the set; re-pick at most every 0.5 s", function()
		local E, r = setup()
		E:part("A", 20, 3, 0, { "Coin" })
		for _ = 1, 99 do -- 0.99 s of pointer updates at 100 Hz
			r:resolve("g", { tag = "Coin" }, nil, E.charPos)
			E.clock += 0.01
		end
		expect(E.collectionCalls.Coin).toBe(1)
		expect(r.picks <= 2).toBe(true)

		local near = E:part("B", 2, 3, 0, { "Coin" }) -- Added: in the set without another GetTagged
		E.clock += 0.5
		local pos = r:resolve("g", { tag = "Coin" }, nil, E.charPos)
		expect(pos.X).toBe(2)
		expect(E.collectionCalls.Coin).toBe(1)

		E:streamOut(near) -- the picked one left: re-picked at once, no wait
		pos = r:resolve("g", { tag = "Coin" }, nil, E.charPos)
		expect(pos.X).toBe(20)
		r:destroy()
	end)
end)
