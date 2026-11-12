--!nocheck
-- (v1.6.1) a LIVE server that still runs legacy code says so once: ServerConfig.legacyList (the
-- decoded studwork-legacy.json) and every ctx.shop.onLegacyProduct bridge, with the
-- writesLegacyData flag each author declared. One warning at boot, one analytics event per server
-- (carried by the first loaded player). Studio: nothing new. A malformed list is no list.
local StudWork = require(script.Parent.Parent.shared)
local Harness = require(script.Parent.harness)
local Server = require(script.Parent.Parent.server)

local Store = StudWork.defineModule({
	name = "Store",
	version = "1.0.0",
	framework = "^1.3.0",
	data = { key = "store", version = 1, default = { coins = 0 } },
})

local PRODUCTS = { passes = {}, devProducts = { OldPack = 202, OldGems = 203 } }

local LIST = {
	files = {
		{ path = "src/server/OldShop.server.luau", checks = { "ProcessReceipt" } },
		{ path = "src/server/OldData.server.luau", checks = { "DataStore" } },
	},
}

local function boot(o)
	o = o or {}
	return Harness.boot({
		modules = { Store },
		products = PRODUCTS,
		isStudio = o.isStudio,
		serverConfig = o.serverConfig,
		servers = {
			Store = {
				init = function(ctx)
					for _, b in o.bridges or {} do
						ctx.shop.onLegacyProduct(b[1], function()
							return "PurchaseGranted"
						end, { writesLegacyData = b[2] })
					end
				end,
			},
		},
	})
end

local function liveWarnings(h)
	local out = {}
	for _, w in h:warnings() do
		if string.find(w, "LIVE server still runs legacy code", 1, true) then
			table.insert(out, w)
		end
	end
	return out
end

local function events(h)
	local out = {}
	for _, a in h.fake.analytics do
		if a.kind == "custom" and a.name == "LegacyCodeLive" then
			table.insert(out, a)
		end
	end
	return out
end

describe("live boot warning for legacy code (v1.6.1)", function()
	it("a live server with a non-empty legacyList: one warning, one event, once per server", function()
		local h, err = boot({ serverConfig = { legacyList = LIST } })
		expect(err).toBe(nil)
		local w = liveWarnings(h)
		expect(#w).toBe(1)
		expect(w[1]).toContain("[StudWork]")
		expect(w[1]).toContain("tools/adopt --verify")
		expect(w[1]).toContain("2 legacy file(s)")
		expect(w[1]).toContain("src/server/OldShop.server.luau")
		expect(#events(h)).toBe(0) -- AnalyticsService needs a player
		h:addPlayer({ userId = 1 })
		h:addPlayer({ userId = 2 })
		local e = events(h)
		expect(#e).toBe(1)
		expect(e[1].fields.entries).toBe("2")
		expect(e[1].fields.bridges).toBe("0")
		expect(#liveWarnings(h)).toBe(1)
	end)

	it("lists every bridge with its declared writesLegacyData flag (item 2)", function()
		local h, err = boot({ bridges = { { "OldPack", false }, { "OldGems", true } } })
		expect(err).toBe(nil)
		local w = liveWarnings(h)
		expect(#w).toBe(1)
		expect(w[1]).toContain("2 ctx.shop.onLegacyProduct bridge(s)")
		expect(w[1]).toContain("OldPack (Store, writesLegacyData = false)")
		expect(w[1]).toContain("OldGems (Store, writesLegacyData = true)")
		expect(w[1]).toContain("declaration")
		h:addPlayer({ userId = 1 })
		local e = events(h)
		expect(#e).toBe(1)
		expect(e[1].fields.bridges).toBe("2")
		expect(e[1].fields.products).toBe("OldPack,OldGems")
		expect(e[1].fields.writesLegacyData).toBe("OldGems:Store")
		local copy = h.runtime.shop.legacyBridges()
		expect(#copy).toBe(2)
		expect(copy[1].product).toBe("OldPack")
		expect(copy[1].owner).toBe("Store")
		expect(copy[1].writesLegacyData).toBe(false)
		copy[1].product = "changed"
		expect(h.runtime.shop.legacyBridges()[1].product).toBe("OldPack")
	end)

	it("in Studio: no live warning and no event (the per-product boot warning stays)", function()
		local h = boot({
			isStudio = true,
			serverConfig = { legacyList = LIST },
			bridges = { { "OldPack", false } },
		})
		h:addPlayer({ userId = 1 })
		expect(#liveWarnings(h)).toBe(0)
		expect(#events(h)).toBe(0)
		local perProduct = false
		for _, w in h:warnings() do
			if string.find(w, "legacy product OldPack", 1, true) then
				perProduct = true
			end
		end
		expect(perProduct).toBe(true)
	end)

	it("a malformed or empty legacyList is no list (never a boot error)", function()
		for _, bad in
			{ "x", 5, {}, { files = "x" }, { files = { 1, { path = 3 }, { checks = {} } } }, { files = {} } }
		do
			local h, err = boot({ serverConfig = { legacyList = bad } })
			expect(err).toBe(nil)
			h:addPlayer({ userId = 1 })
			expect(#liveWarnings(h)).toBe(0)
			expect(#events(h)).toBe(0)
		end
	end)

	it("names the first few paths and counts the rest", function()
		local files = {}
		for i = 1, 8 do
			table.insert(files, { path = `src/old/File{i}.luau`, checks = {} })
		end
		local report = Server.legacyLiveReport({ files = files }, {})
		expect(report.message).toContain("8 legacy file(s)")
		expect(report.message).toContain("src/old/File5.luau")
		expect(report.message).never.toContain("src/old/File6.luau")
		expect(report.message).toContain("+3 more")
		expect(Server.legacyLiveReport(nil, {})).toBe(nil)
	end)
end)
