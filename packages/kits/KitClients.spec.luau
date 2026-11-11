--!nocheck
-- v1.3.1 (R19): the kit client actions moved from the framework client (ActionGate.CLIENT_ACTIONS,
-- Client.Actions.<kit action>) to each kit module's own client part
-- (packages/kits/<kit>/<Module>/client/init.luau, ReplicatedStorage.Modules.<Module>.client).
-- The not-enabled assertion of the old ActionGate.spec moved here, for every one of those actions.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Boot = require(ReplicatedStorage:WaitForChild("FrameworkClient"):WaitForChild("Boot"))
local Runtime = require(ReplicatedStorage:WaitForChild("FrameworkClient"):WaitForChild("Runtime"))
local Resolve = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Resolve"))
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

local Modules = ReplicatedStorage:WaitForChild("Modules")

-- the v1.2 action -> owner table (was ActionGate.CLIENT_ACTIONS)
local V12_ACTIONS = {
	display = "Plot",
	clearDisplay = "Plot",
	rebirth = "Rebirth",
	upgrade = "Upgrades",
	roll = "Rarity",
	gift = "Inventory",
	claimMail = "Mail",
}

local function clientPart(name: string): any
	return require(Modules:WaitForChild(name):WaitForChild("client"))
end

describe("kit client parts (R19: one folder per module)", function()
	afterEach(function()
		Boot.attach(nil)
	end)

	it("every v1.2 client action is declared by its owner module's client part", function()
		for action, owner in V12_ACTIONS do
			local part = clientPart(owner)
			expect(
				owner
					.. "."
					.. action
					.. "="
					.. tostring(part.actions[action] ~= nil or table.find(part.actions, action) ~= nil)
			).toBe(owner .. "." .. action .. "=true")
		end
	end)

	it("module actions error with the not-enabled message when the module is off", function()
		Boot.attach(nil)
		Runtime.start({ gameId = "t", modules = {} }, nil, {
			loadClient = function()
				return nil
			end,
		})
		for action, owner in V12_ACTIONS do
			local ref = require(Modules:WaitForChild(owner):WaitForChild("module"))
			local ok, err = pcall(function()
				return StudWork.use(ref).actions[action]
			end)
			expect(ok).toBe(false)
			expect(string.find(tostring(err), Resolve.notEnabledMessage(owner), 1, true) ~= nil).toBe(true)
		end
	end)
end)
