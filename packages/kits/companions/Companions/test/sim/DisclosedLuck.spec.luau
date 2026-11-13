--!nocheck
local RS = game:GetService("ReplicatedStorage")
local StudWork = require(RS.Framework)
local Items = require(RS.Modules.Items.module)
local Inventory = require(RS.Modules.Inventory.module)
local Rarity = require(RS.Modules.Rarity.module)
local Companions = require(RS.Modules.Companions.module)
describe("Game-owned companion luck integration", function()
	it("uses capped equipped signal through public disclosed luck", function()
		local GameBonus = StudWork.defineModule({
			name = "FixtureLuck",
			version = "1.0.0",
			framework = "^1.7.0",
			dependsOn = { Companions, Rarity },
		})
		local h = StudWork.test.harness({
			modules = { Items, Inventory, Rarity, Companions, GameBonus },
			items = {
				{ id = "common", name = "Common", rarity = "Common", companions = { incomeBonus = 100 } },
				{ id = "rare", name = "Rare", rarity = "Rare", companions = {} },
			},
			config = {
				Companions = { autoEquipBest = false, bonusCap = 3 },
				Rarity = {
					rarityTables = {
						Fixture = {
							entries = { { itemId = "common", weight = 1 }, { itemId = "rare", weight = 1 } },
							luckDisclosed = true,
						},
					},
				},
			},
			servers = {
				FixtureLuck = {
					start = function(ctx)
						ctx.deps[Companions].signals.EquippedChanged:Connect(function(player, _copies, factor)
							ctx.deps[Rarity].setLuck(player, factor, "Fixture")
						end)
					end,
				},
			},
		})
		local p = h:addPlayer({ userId = 975 })
		local rarity = h:use(Rarity)
		local before = rarity.getOddsDetail("Fixture", p)
		local copy = h:use(Inventory).add(p, "common")
		assert(h:use(Companions).equip(p, copy.uid))
		expect(h:use(Companions).bonus(p)).toBe(3)
		expect(rarity.getLuck(p, "Fixture")).toBe(3)
		local after = rarity.getOddsDetail("Fixture", p)
		expect(after.luck).toBe(3)
		expect(before.luck).toBe(1)
		expect(before.items.rare).toBeNear(0.5, 1e-12)
		expect(after.items.rare).toBeNear(0.75, 1e-12)
		local shown = h:state(p).modules.Rarity.extra.odds.Fixture
		expect(shown.luck).toBe(3)
		expect(shown.items.rare).toBeNear(after.items.rare, 1e-12)
	end)
end)
