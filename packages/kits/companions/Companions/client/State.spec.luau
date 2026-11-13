--!strict
local State = require(game:GetService("ReplicatedStorage").Modules.Companions.client.State)
describe("Companions client selectors", function()
	it("handles absent module state safely", function()
		expect(State.equipped(nil)).toEqual({})
		expect(State.manual({ modules = {} })).toBe(false)
		expect(State.enabled({})).toBe(false)
		expect(State.bonus({})).toBe(1)
		expect(State.roster({})).toEqual({})
	end)
	it("reads only the module data and extra fields", function()
		local roster = { ["1"] = { userId = 1, equipped = { { uid = "a", itemId = "pebble" } } } }
		local full = {
			modules = {
				Companions = {
					data = { equipped = { "a" }, manual = true },
					extra = { bonus = 2, enabled = true, roster = roster },
				},
			},
		}
		expect(State.equipped(full)).toEqual({ "a" })
		expect(State.manual(full)).toBe(true)
		expect(State.bonus(full)).toBe(2)
		expect(State.enabled(full)).toBe(true)
		expect(State.roster(full)).toEqual(roster)
	end)
end)
