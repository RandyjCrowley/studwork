--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Model = require(ReplicatedStorage.Modules.Companions.client.ScreenModel)
local items: { any } = {
	{ id = "rock", rarity = "Common", companions = { score = 1 } },
	{ id = "bird", rarity = "Rare", companions = { score = 2 } },
	{ id = "plain", rarity = "Rare" },
}
local ranks = { Common = 1, Rare = 2 }
local function build(inv: any, equipped: any?, page: number?, enabled: boolean?, loaded: boolean?): any
	return Model.build(inv, items, equipped or {}, ranks, 1, enabled ~= false, loaded ~= false, page or 1)
end

describe("Companions screen presentation", function()
	it("shows only owned enabled definitions in stable rarity score uid order", function()
		local inv = {
			{ uid = "z", itemId = "rock" },
			{ uid = "b", itemId = "bird" },
			{ uid = "a", itemId = "bird", mutation = "Gold" },
			{ uid = "x", itemId = "plain" },
			{ uid = "y", itemId = "missing" },
		}
		local view = build(inv)
		expect(view.owned).toBe(3)
		expect(view.rows[1].uid).toBe("a")
		expect(view.rows[1].mutation).toBe("Gold")
		expect(view.rows[2].uid).toBe("b")
		expect(view.rows[3].uid).toBe("z")
		expect(inv[1].uid).toBe("z")
	end)
	it("pages twenty copies and clamps after removals", function()
		local inv = {}
		for i = 1, 43 do
			table.insert(inv, { uid = string.format("%03d", i), itemId = "rock" })
		end
		local view = build(inv, {}, 2)
		expect(#view.rows).toBe(20)
		expect(view.rows[1].uid).toBe("021")
		expect(view.pages).toBe(3)
		expect(#build(inv, {}, 3).rows).toBe(3)
		expect(build({}, {}, 3).page).toBe(1)
	end)
	it("routes authoritative uid requests without optimistic writes", function()
		local inv = { { uid = "a", itemId = "bird" }, { uid = "z", itemId = "rock" } }
		local selected = { "a" }
		local view = build(inv, selected)
		local calls = {}
		local actions = {
			equip = function(uid)
				table.insert(calls, "equip:" .. uid)
			end,
			unequip = function(uid)
				table.insert(calls, "unequip:" .. uid)
			end,
			equipBest = function()
				table.insert(calls, "best")
			end,
		}
		expect(view.rows[1].key).toBe("Companions.unequip")
		expect(view.rows[2].key).toBe("Companions.equip")
		Model.activate(view.rows[1], actions)
		Model.activate(view.rows[2], actions)
		Model.equipBest(view, actions)
		expect(calls).toEqual({ "unequip:a", "best" })
		expect(selected).toEqual({ "a" })
		local empty = build(inv)
		Model.activate(empty.rows[2], actions)
		expect(calls[3]).toBe("equip:z")
	end)
	it("blocks actions while disabled or waiting for load", function()
		for _, view in
			{
				build({ { uid = "a", itemId = "bird" } }, {}, 1, false),
				build({ { uid = "a", itemId = "bird" } }, {}, 1, true, false),
			}
		do
			local actions = setmetatable({}, {
				__index = function()
					error("must not dispatch")
				end,
			})
			Model.activate(view.rows[1], actions)
			Model.equipBest(view, actions)
		end
	end)
end)
