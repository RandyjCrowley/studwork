--!nocheck
-- core-v1.3.1 (R19): the default HUD widgets "Economy.currency" and "Social.mailbox" moved from the
-- framework HUD into the Economy and Mail client parts, registered with UI.registerWidget under
-- the same ids at start (the framework HUD re-renders on UI.onWidgetsChanged, so a registration
-- after the HUD mounted shows up). UI's init needs React (not loadable under Lune), so this checks
-- the specs the parts register and how the HUD resolves them (UI.HudLayout, pure).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HudLayout = require("packages/ui/HudLayout.luau")
local Modules = ReplicatedStorage:WaitForChild("Modules")

local EconomyClient = require(Modules:WaitForChild("Economy"):WaitForChild("client"))
local MailClient = require(Modules:WaitForChild("Mail"):WaitForChild("client"))

local function all(_name: string): boolean
	return true
end

describe("kit HUD widgets (registered by the kits' client parts)", function()
	it("register under the v1.3.0 ids, slots, orders and module gates", function()
		expect(EconomyClient.WIDGET_ID).toBe("Economy.currency")
		expect(MailClient.WIDGET_ID).toBe("Social.mailbox")
		local currency = EconomyClient.widget
		expect(currency.slot).toBe("topCenter")
		expect(currency.order).toBe(1)
		expect(currency.module).toBe("Economy")
		local mailbox = MailClient.widget
		expect(mailbox.slot).toBe("topCenter")
		expect(mailbox.order).toBe(3)
		expect(mailbox.module).toBe("Mail")
		HudLayout.checkSpec(EconomyClient.WIDGET_ID, currency)
		HudLayout.checkSpec(MailClient.WIDGET_ID, mailbox)
	end)

	it("client.hud.widgets[id] = false and the module gate still remove them", function()
		local registered =
			{ [EconomyClient.WIDGET_ID] = EconomyClient.widget, [MailClient.WIDGET_ID] = MailClient.widget }
		local placed = HudLayout.resolve({}, registered, { ["Social.mailbox"] = false }, all)
		local ids = {}
		for _, w in placed.topCenter do
			table.insert(ids, w.id)
		end
		expect(table.find(ids, "Economy.currency") ~= nil).toBe(true)
		expect(table.find(ids, "Social.mailbox")).toBeNil()
		local gated = HudLayout.resolve({}, registered, {}, function(name)
			return name ~= "Economy"
		end)
		for _, w in gated.topCenter do
			expect(w.id).never.toBe("Economy.currency")
		end
	end)
end)
