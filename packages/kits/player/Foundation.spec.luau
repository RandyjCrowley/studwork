--!nocheck
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Codes = require(Modules:WaitForChild("Codes"):WaitForChild("module"))
local Settings = require(Modules:WaitForChild("Settings"):WaitForChild("module"))
describe("player module definitions", function()
	it("boots each module independently with private save sections", function()
		local optional = {}
		for _, dep in Codes.optional do
			table.insert(optional, dep.name)
		end
		expect(optional).toEqual({ "Economy", "Inventory", "Rarity", "Rebirth" })
		expect(#Codes.dependsOn).toBe(0)
		expect(#Settings.dependsOn).toBe(0)
		expect(#Settings.optional).toBe(0)
		for _, ref in { Codes, Settings } do
			local h = StudWork.test.harness({ modules = { ref } })
			local p = h:addPlayer({ userId = 123 })
			expect(p.loaded).toBe(true)
			expect(ref.data.replicate).toBe(false)
		end
	end)
	it("refuses an invalid configured code at boot", function()
		local h = StudWork.test.boot({
			modules = { Codes },
			config = {
				Codes = {
					definitions = { { id = "invalid", code = "HELLO", rewards = {}, oncePerPlayer = false } },
				},
			},
		})
		expect(h).toBe(nil)
	end)
	it("refuses invalid setting defaults at boot", function()
		local h = StudWork.test.boot({
			modules = { Settings },
			config = { Settings = { builtins = { musicVolume = { default = 2 } } } },
		})
		expect(h).toBe(nil)
	end)
end)
