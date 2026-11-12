--!nocheck
--[[
	v1.6.1 (adopting.md §4.3, final review M1) in the multi-server sim: an onLegacyProduct handler
	that declared writesLegacyData = false and writes the World's old store through the server's
	own DataStoreService fails loudly (NotProcessedYet, nothing recorded); the framework's own
	ProfileStore saves to the same mock World are not old-store writes.
]]

local F = require(script.Parent.Fixtures)
local Legacy = require("packages/framework/server/Legacy.luau")

local function bridgePart(holder, writes: boolean, doWrite: boolean)
	return {
		init = function(ctx)
			ctx.data.importLegacy({
				id = "v1-save",
				version = 1,
				source = { kind = "datastore", name = "OldData", key = "Player_{userId}" },
				import = function(tx, old)
					ctx.section(tx).coins = old.coins
				end,
			})
			ctx.shop.onLegacyProduct("Coins100", function(receiptInfo, _player)
				holder.runs += 1
				if doWrite then
					local ds = holder.world:dataStoreService(holder.server)
					ds:GetDataStore("OldData"):SetAsync(`Player_{receiptInfo.PlayerId}`, { coins = 1 })
				end
				return "PurchaseGranted"
			end, { writesLegacyData = writes })
		end,
	}
end

local function run(doWrite: boolean)
	local world = F.world()
	world:seed("OldData", "Player_71", { coins = 40 })
	world:advance(Legacy.QUIET_SECONDS + 5)
	local holder = { runs = 0, world = world }
	local s =
		F.server(world, { legacy = "world", serverParts = { SimGame = bridgePart(holder, false, doWrite) } })
	holder.server = s
	local p = s:join(71)
	assert(
		world:advanceUntil(function()
			return s:isLoaded(p)
		end, 30, 0.25),
		"loaded"
	)
	local h = s:purchase(F.receipt(71, "sim-1", 1001))
	world:advanceUntil(function()
		return h.done
	end, 30)
	return world, s, p, h, holder
end

local function loud(s): string?
	for _, w in s.warnings do
		if string.find(w, "UNDECLARED LEGACY WRITE", 1, true) then
			return w
		end
	end
	return nil
end

describe("legacy bridge writes (multi-server sim)", function()
	it(
		"writesLegacyData = false + a SetAsync to the old store -> NotProcessedYet, not recorded, loud",
		function()
			local _world, s, p, h, holder = run(true)
			expect(holder.runs).toBe(1)
			expect(h.result).toBe("NotProcessedYet")
			local purchases = s.runtime.data.frameworkField(p, "purchases")
			expect(purchases == nil or purchases["sim-1"] == nil).toBe(true)
			local msg = loud(s)
			expect(msg).never.toBeNil()
			expect(string.find(msg, "store OldData key Player_71", 1, true)).never.toBeNil()
		end
	)

	it("a handler that doesn't write -> granted (the framework's own saves don't count)", function()
		local _world, s, p, h = run(false)
		expect(h.result).toBe("PurchaseGranted")
		expect(s.runtime.data.frameworkField(p, "purchases")["sim-1"]).never.toBeNil()
		expect(loud(s)).toBeNil()
	end)
end)
