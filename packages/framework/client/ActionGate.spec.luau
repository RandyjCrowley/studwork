local ActionGate = require(script.Parent.ActionGate)
local Resolve =
	require(game:GetService("ReplicatedStorage"):WaitForChild("Framework"):WaitForChild("Resolve"))

describe("Client.ActionGate", function()
	it("errors before Core.start", function()
		local g = ActionGate.new()
		expect(string.find(ActionGate.check(g, "funnel") :: string, "before Core.start", 1, true) ~= nil).toBe(
			true
		)
	end)

	it("module actions error with the not-enabled message when the module is off", function()
		local g = ActionGate.new()
		ActionGate.start(g, { "Economy", "Rebirth" })
		expect(ActionGate.check(g, "rebirth")).toBe(nil)
		expect(ActionGate.check(g, "triggerEvent")).toBe(nil)
		expect(ActionGate.check(g, "funnel")).toBe(nil)
		for action, owner in ActionGate.CLIENT_ACTIONS do
			if owner ~= "Rebirth" then
				expect(ActionGate.check(g, action)).toBe("[Core] " .. Resolve.notEnabledMessage(owner))
			end
		end
	end)

	it("isEnabled: foundation always, modules when listed", function()
		local g = ActionGate.new()
		ActionGate.start(g, { "Economy" })
		expect(ActionGate.isEnabled(g, "Events")).toBe(true)
		expect(ActionGate.isEnabled(g, "Economy")).toBe(true)
		expect(ActionGate.isEnabled(g, "Rebirth")).toBe(false)
	end)
end)
