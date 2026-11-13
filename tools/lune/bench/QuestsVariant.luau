--[[
	tools/bench variant KITS-QUESTS (v1.8.0 quests kit): KITS-ALL plus Quests and Goals, with every
	player holding 10 active quests (6 daily + 4 weekly slots, all on the counter key "benchTick")
	progressed every tick, and a Goals chain whose one goal (currency >= 1e12) is never reached, so
	every income tick's CurrencyChanged marks the player dirty. Budget: <= 1.2 x the same run's
	KITS-ALL median (docs/pending/quests.md §9).

	replication.luau's additive hook calls:
	  QuestsVariant.boot(players, bootKits, Harness) -> sync   (bootKits(players, true) with the two
	      modules and their config added to the harness options)
	  QuestsVariant.tick(player, tick)                         one Quests.progress per player per tick

	How the modules get in without changing bootKits: bootKits calls Harness.mapGame and then the
	facade's StudWork.test.harness, a frozen forwarder that looks up the test kit's Public.harness
	(packages/framework/test/Public.luau, a plain table cached by path) at call time. For the one
	bootKits call, Harness.mapGame is wrapped so that, right after the game is mapped, Public.harness
	is wrapped to append the definitions and config to `opts`; both are restored afterwards.
]]

local QuestsVariant = {}

local DAILY = 6 -- slots (the schema's maximum), from a pool of the same size
local WEEKLY = 4
local KEY = "benchTick"
local TARGET = 1000000000 -- never completes: the hot path is pending progress, not claims

local quests: any = nil

local function questsConfig(): any
	local list = {}
	for i = 1, DAILY do
		list["benchDaily" .. i] =
			{ kind = "daily", objectives = { { kind = "counter", key = KEY, target = TARGET } } }
	end
	for i = 1, WEEKLY do
		list["benchWeekly" .. i] =
			{ kind = "weekly", objectives = { { kind = "counter", key = KEY, target = TARGET } } }
	end
	return {
		daily = { count = DAILY, rerollsPerSlot = 1 },
		weekly = { count = WEEKLY, rerollsPerSlot = 0 },
		quests = list,
	}
end

local function goalsConfig(): any
	return { chain = { { id = "benchRich", check = { source = "currency", atLeast = 1e12 } } } }
end

function QuestsVariant.boot(players: { any }, bootKits: (any, boolean) -> any, Harness: any): any
	local originalMapGame = Harness.mapGame
	local Public: any = nil
	local originalHarness: any = nil
	local seen: any = nil
	local refs: any = nil
	Harness.mapGame = function(...)
		originalMapGame(...)
		local game = Harness.game
		Public = Harness.require(game:GetService("ServerScriptService").FrameworkTest.Public)
		originalHarness = Public.harness
		local Modules = game:GetService("ReplicatedStorage").Modules
		refs = {
			Quests = Harness.require(Modules.Quests.module),
			Goals = Harness.require(Modules.Goals.module),
		}
		Public.harness = function(opts: any): any
			local o = table.clone(opts)
			o.modules = table.clone(o.modules or {})
			table.insert(o.modules, refs.Quests)
			table.insert(o.modules, refs.Goals)
			o.config = table.clone(o.config or {})
			o.config.Quests = questsConfig()
			o.config.Goals = goalsConfig()
			seen = originalHarness(o)
			return seen
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
	assert(seen ~= nil, "bench KITS-QUESTS: bootKits never built a harness (the facade wrap missed)")
	quests = seen:use(refs.Quests)
	return result
end

function QuestsVariant.tick(player: any, _tick: number)
	quests.progress(player, KEY, 1)
end

return QuestsVariant
