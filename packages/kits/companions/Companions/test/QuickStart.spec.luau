--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Companions = require(ReplicatedStorage.Modules.Companions.module)
local Config = require(ReplicatedStorage.Modules.Companions.shared.Config)
local StudWork = require(ReplicatedStorage.Framework)
local Items = require(ReplicatedStorage.Modules.Items.module)
local Inventory = require(ReplicatedStorage.Modules.Inventory.module)
describe("Companions quick start definition", function()
	it("declares the documented opt-in item and own replicated save", function()
		Config.validate(
			Config.defaults,
			{ items = { { id = "pebble", name = "Pebble", companions = { movement = "hop" } } } }
		)
		expect(Companions.data.key).toBe("companions")
		expect(Companions.data.default).toEqual({ equipped = {}, manual = false })
		expect(Companions.data.replicate).toEqual({ "equipped", "manual" })
		expect(Companions.config.defaults.slots).toBe(3)
	end)
end)

describe("Companions quick start behavior", function()
	it("equips the owned copy uid from the documented item namespace", function()
		local h = StudWork.test.harness({
			modules = { Items, Inventory, Companions },
			items = { { id = "pebble", name = "Pebble", companions = { movement = "hop" } } },
			config = { Companions = { autoEquipBest = false } },
		})
		local player = h:addPlayer({ userId = 101 })
		local copy = h:use(Inventory).add(player, "pebble")
		expect(copy ~= nil).toBe(true)
		expect(h:use(Companions).equip(player, copy.uid)).toBe(true)
		expect(h:use(Companions).equipped(player)[1].uid).toBe(copy.uid)
	end)
end)
