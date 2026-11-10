local OddsSync = require(script.Parent.OddsSync)

local SHARED: { [string]: any } = {
	Egg = { tableId = "Egg", luck = 1, luckDisclosed = true },
	Box = { tableId = "Box", luck = 1, luckDisclosed = false },
}

local function detailFor(tableId: string, luck: number): any
	return { tableId = tableId, luck = luck, luckDisclosed = true, own = true }
end

describe("OddsSync.playerOdds", function()
	it("returns nil (use the shared map) while luck is 1 on every disclosed table", function()
		local merged = OddsSync.playerOdds(SHARED, function(id)
			return if id == "Box" then 3 else 1 -- luck on a non-disclosed table never overrides
		end, function(id)
			return detailFor(id, 3)
		end)
		expect(merged).toBeNil()
	end)

	it("replaces only luckDisclosed tables with luck ~= 1, keeps the rest shared", function()
		local merged = OddsSync.playerOdds(SHARED, function(id)
			return if id == "Egg" then 1.5 else 2
		end, function(id)
			return detailFor(id, 1.5)
		end) :: any
		expect(merged).toBeTruthy()
		expect(merged.Egg.own).toBe(true)
		expect(merged.Egg.luck).toBe(1.5)
		expect(merged.Box).toBe(SHARED.Box)
		expect((SHARED.Egg :: any).own).toBeNil() -- shared map untouched
	end)

	it("skips a table whose detail cannot be built", function()
		local merged = OddsSync.playerOdds(SHARED, function()
			return 2
		end, function()
			return nil
		end)
		expect(merged).toBeNil()
	end)
end)
