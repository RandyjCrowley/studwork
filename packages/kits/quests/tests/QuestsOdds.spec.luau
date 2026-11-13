--!nocheck
--!nolint DeprecatedApi
--[[
	The Quests client's Odds screen item list (Quests/client/init.luau `openOdds`). `GameConfig.items`
	is a list of defs in a game that follows the Items kit (`{ { id = "sword", ... } }`), and a map
	in another (`{ sword = { ... } }`): the id handed to the Odds screen must be the def's own `id`,
	not the list index (which showed "1", "2", ... for every item). The UI kit and React don't load
	under Lune, so the function is cut out of the source and run against a fake UI that records
	what `UI.open("Odds", props)` receives.
]]
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")
local luau = (getmetatable(getfenv(1)) :: any).__index.require("@lune/luau")

local SOURCE = fs.readFile("packages/kits/quests/Quests/client/init.luau")

-- the text of `local function openOdds(...) ... end` (the first `end` at column 0 after it)
local function cutOpenOdds(): string
	local first = string.find(SOURCE, "local function openOdds(", 1, true)
	assert(first ~= nil, "openOdds not found in Quests/client/init.luau")
	local _, last = string.find(SOURCE, "\nend\n", first, true)
	assert(last ~= nil, "end of openOdds not found")
	return string.sub(SOURCE, first, last)
end

-- runs the real openOdds with `items` as GameConfig.items; returns what UI.open("Odds", props) got
local function openWith(items: any, odds: any, tableId: string): any
	local opened: any = nil
	local fakeUI = {
		text = function(key: string)
			return key
		end,
		open = function(screen: string, props: any)
			opened = { screen = screen, props = props }
		end,
	}
	local chunk = table.concat({
		"local fakeUI, fakeItems = ...",
		"local function ui() return fakeUI end",
		"local function gameItems() return fakeItems end",
		cutOpenOdds(),
		"return openOdds",
	}, "\n")
	local run = luau.load(chunk, { debugName = "openOdds" })
	local openOdds = run(fakeUI, items)
	openOdds(tableId, odds)
	return opened
end

local function byId(list: { any }, id: string): any
	for _, item in list do
		if item.id == id then
			return item
		end
	end
	return nil
end

describe("Quests Odds screen items", function()
	it("a list catalog (defs with their own id) gives the def id, not the list index", function()
		local opened = openWith({
			{ id = "sword", name = "Iron Sword", rarity = "Rare" },
			{ id = "shield", rarity = "Epic" },
		}, { crate = { { id = "sword", chance = 0.5 } } }, "crate")
		expect(opened.screen).toBe("Odds")
		local items = opened.props.items
		expect(#items).toBe(2)
		expect(byId(items, "sword") ~= nil).toBe(true)
		expect(byId(items, "sword").name).toBe("Iron Sword")
		expect(byId(items, "sword").rarity).toBe("Rare")
		expect(byId(items, "shield").name).toBe("shield") -- no name: the id
		expect(byId(items, "1")).toBe(nil)
		expect(byId(items, 1)).toBe(nil)
	end)

	it("a map catalog keeps its key as the id", function()
		local opened = openWith({
			sword = { name = "Iron Sword" },
			shield = { name = "Wooden Shield", rarity = "Uncommon" },
		}, {}, "crate")
		local items = opened.props.items
		expect(#items).toBe(2)
		expect(byId(items, "sword").name).toBe("Iron Sword")
		expect(byId(items, "sword").rarity).toBe("Common")
		expect(byId(items, "shield").rarity).toBe("Uncommon")
	end)

	it("the detail is the replicated table's odds, and absent odds open an empty list", function()
		local detail = { { id = "sword", chance = 0.5 } }
		local opened = openWith({}, { crate = detail }, "crate")
		expect(opened.props.detail).toBe(detail)
		expect(opened.props.odds).toBe(nil)
		opened = openWith({}, {}, "missing")
		expect(opened.props.detail).toBe(nil)
		expect(opened.props.odds).toEqual({})
	end)
end)
