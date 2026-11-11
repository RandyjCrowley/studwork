local ActionGate = require(script.Parent.ActionGate)

-- core-v1.3.1 (R19): the kit-owned actions' not-enabled check moved with the actions to the kits'
-- client parts (packages/kits/KitClients.spec.luau asserts the same message for every one).
describe("Client.ActionGate", function()
	it("errors before Core.start", function()
		local g = ActionGate.new()
		expect(string.find(ActionGate.check(g, "funnel") :: string, "before Core.start", 1, true) ~= nil).toBe(
			true
		)
	end)

	it("framework actions run once started, whatever modules are on", function()
		local g = ActionGate.new()
		ActionGate.start(g, { "Economy", "Rebirth" })
		expect(ActionGate.check(g, "triggerEvent")).toBe(nil)
		expect(ActionGate.check(g, "funnel")).toBe(nil)
		local none = ActionGate.new()
		ActionGate.start(none, {})
		expect(ActionGate.check(none, "triggerEvent")).toBe(nil)
		expect(ActionGate.check(none, "funnel")).toBe(nil)
	end)

	it("isEnabled: foundation always, modules when listed", function()
		local g = ActionGate.new()
		ActionGate.start(g, { "Economy" })
		expect(ActionGate.isEnabled(g, "Events")).toBe(true)
		expect(ActionGate.isEnabled(g, "Economy")).toBe(true)
		expect(ActionGate.isEnabled(g, "Rebirth")).toBe(false)
	end)
end)
