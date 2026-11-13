--!strict
local Save = require(game:GetService("ReplicatedStorage").Modules.Companions.shared.Save)
describe("Companions save normalization", function()
	it("creates an empty auto-mode save", function()
		expect(Save.migrate1(nil)).toEqual({ equipped = {}, manual = false })
	end)
	it("keeps ordered bounded unique ids and manual emptiness", function()
		expect(Save.sanitize({
			equipped = { "a", "a", false, "", string.rep("a", 65), "b" } :: { any },
			manual = true,
		})).toEqual({
			equipped = { "a", "b" },
			manual = true,
		})
		expect(Save.sanitize({ equipped = {}, manual = true })).toEqual({ equipped = {}, manual = true })
		local ids = {}
		for i = 1, 20 do
			table.insert(ids, tostring(i))
		end
		expect(#Save.sanitize({ equipped = ids }).equipped).toBe(12)
	end)
end)
