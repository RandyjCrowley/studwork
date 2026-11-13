--!nocheck
--[[
	tools/bench variants for the v1.8.0 kits that add modules on top of KITS-ALL without a per-tick
	workload of their own (they measure what the kit costs a game that has it on):

	  KITS-COMPANIONS  KITS-ALL + Companions: every bench item is a companion (walk/hop/fly), so each
	                   of the 50 players has 3 equipped copies (autoEquipBest, slots = 3)
	  KITS-PLAYER      KITS-ALL + Codes + Settings (packages/kits/player/bench/Config.luau: one capped
	                   test promotion, one saved custom setting)
	  KITS-MODERATION  KITS-ALL + Admin + Moderation + Reports (packages/kits/moderation/tests/bench):
	                   3 staff among the 50 (owner, moderator, helper via ServerConfig.Admin.users),
	                   the kit's engine fakes, every player in one text channel, two muted players
	                   (mute expiry checks run every tick)

	Budget for each: <= 1.2 x the same run's KITS-ALL median. KITS-ALL itself is unchanged (the
	reference). The tick work is KITS-ALL's (one Leaderboards submit per player, h:tick(1)).

	How the modules get in without changing bootKits (the same seam as QuestsVariant): for the one
	bootKits(players, true) call, Harness.mapGame is wrapped so that, right after the game is mapped,
	the test kit's Public.harness (the facade's StudWork.test.harness forwards to it at call time) is
	wrapped to let the plan edit `opts`; the harness it builds gets its addPlayer wrapped so the plan
	sees every player. Both are restored afterwards.

	KitVariant.register({ variants, tickFns, order, bootKits, Harness })
]]

local KitVariant = {}

local PlayerBench = require("../../../packages/kits/player/bench/Config")
local ModerationFakes = require("../../../packages/kits/moderation/tests/Fakes")

local MOVES = { "walk", "hop", "fly" }
local STAFF = { [1] = "owner", [2] = "moderator", [3] = "helper" }

-- plan = { modules = { name }, extend(opts, refs)?, joined(h, refs, player, index)?, ready(h, refs, players)? }
local function boot(players: { any }, bootKits: any, Harness: any, label: string, plan: any): any
	local originalMapGame = Harness.mapGame
	local Public: any = nil
	local originalHarness: any = nil
	local seen: any = nil
	local refs: any = {}
	local joined: { any } = {}
	Harness.mapGame = function(...)
		originalMapGame(...)
		local game = Harness.game
		Public = Harness.require(game:GetService("ServerScriptService").FrameworkTest.Public)
		originalHarness = Public.harness
		local Modules = game:GetService("ReplicatedStorage").Modules
		for _, name in plan.modules do
			refs[name] = Harness.require(Modules[name].module)
		end
		Public.harness = function(opts: any): any
			local o = table.clone(opts)
			o.modules = table.clone(o.modules or {})
			for _, name in plan.modules do
				table.insert(o.modules, refs[name])
			end
			o.config = table.clone(o.config or {})
			o.services = table.clone(o.services or {})
			o.strings = table.clone(o.strings or {})
			o.items = table.clone(o.items or {})
			if plan.extend then
				plan.extend(o, refs)
			end
			local h = originalHarness(o)
			local addPlayer = h.addPlayer
			h.addPlayer = function(self: any, ...: any): any
				local player = addPlayer(self, ...)
				table.insert(joined, player)
				if plan.joined then
					plan.joined(h, refs, player, #joined)
				end
				return player
			end
			seen = h
			return h
		end
	end
	local ok, result = pcall(bootKits, players, true)
	Harness.mapGame = originalMapGame
	if Public ~= nil then
		Public.harness = originalHarness
	end
	if not ok then
		error(result, 0)
	end
	assert(seen ~= nil, `bench {label}: bootKits never built a harness (the facade wrap missed)`)
	if plan.ready then
		plan.ready(seen, refs, joined)
	end
	return result
end

local PLANS: { [string]: any } = {}

PLANS["KITS-COMPANIONS"] = {
	modules = { "Companions" },
	extend = function(o: any)
		for i, item in o.items do
			local copy = table.clone(item)
			copy.companions = { movement = MOVES[1 + (i - 1) % #MOVES] }
			o.items[i] = copy
		end
		o.config.Companions = { slots = 3, incomeBonusEnabled = false }
	end,
	ready = function(h: any, refs: any, list: { any })
		local api = h:use(refs.Companions)
		for _, player in list do
			local n = #api.equipped(player)
			assert(n == 3, `bench KITS-COMPANIONS: expected 3 equipped copies, got {n}`)
		end
	end,
}

PLANS["KITS-PLAYER"] = {
	modules = PlayerBench.modules,
	extend = function(o: any)
		for name, value in PlayerBench.config do
			o.config[name] = value
		end
		for key, value in PlayerBench.strings do
			o.strings[key] = value
		end
	end,
}

local moderation: any = {}
PLANS["KITS-MODERATION"] = {
	modules = { "Admin", "Moderation", "Reports" },
	extend = function(o: any)
		moderation.players = ModerationFakes.players()
		moderation.tcs = ModerationFakes.textChatService()
		moderation.channel = moderation.tcs.addChannel("RBXGeneral")
		o.services.Players = moderation.players
		o.services.GroupService = ModerationFakes.groupService()
		o.services.TextChatService = moderation.tcs
		o.serverConfig = { Admin = { users = STAFF } }
	end,
	joined = function(_h: any, _refs: any, player: any)
		moderation.channel:AddUserAsync(player.UserId)
	end,
	ready = function(h: any, refs: any, list: { any })
		moderation.players.setOnline(list)
		local mod = h:use(refs.Moderation)
		for _, i in { 10, 11 } do
			local ok, status = mod.mute(list[i], { by = "server", seconds = 3600 })
			assert(ok, status)
		end
		h:tick(1)
		local staff = h.fake.synced[list[1]].modules.Admin
		assert(staff and staff.extra.staff.role == "owner", "bench KITS-MODERATION: the owner's staff state")
		assert(
			h.fake.synced[list[20]].modules.Admin == nil,
			"bench KITS-MODERATION: no staff state for players"
		)
	end,
}

KitVariant.ORDER = { "KITS-COMPANIONS", "KITS-PLAYER", "KITS-MODERATION" }

function KitVariant.register(r: any)
	for _, name in KitVariant.ORDER do
		r.variants[name] = function(players)
			return boot(players, r.bootKits, r.Harness, name, PLANS[name])
		end
		r.tickFns[name] = function(p: any, tick: number)
			r.tickFns["KITS-ALL"](p, tick)
		end
		table.insert(r.order, name)
	end
end

return KitVariant
