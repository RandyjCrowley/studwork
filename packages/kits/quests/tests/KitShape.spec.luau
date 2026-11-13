--!nocheck
--[[
	Quests kit shape (foundation): both definitions (framework range, optional deps, config defaults
	= the kit page, save sections, client parts, strings, theme), both boot with no config (alone,
	together, next to every other kit module at its defaults: the `tools/adopt --init` shape), a game
	without them boots, the api / extensions / signals / actions exist with their final shapes, the
	documented refusals that hold whatever the state (flag off, player not loaded), and `sanitize`
	repairs garbage without erroring. Behaviour specs belong to the Quests and Goals builders.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local F = require("packages/kits/quests/tests/Fixtures.luau")

local function kit(name)
	return require(Modules:WaitForChild(name):WaitForChild("module"))
end
local Quests = kit("Quests")
local Goals = kit("Goals")
local QuestsClient = require(Modules:WaitForChild("Quests"):WaitForChild("client"))
local GoalsClient = require(Modules:WaitForChild("Goals"):WaitForChild("client"))

-- every kit module of v1.7.x plus this kit (what tools/adopt --init and tools/new-game list)
local ALL_KITS = {
	"Items",
	"Rarity",
	"Inventory",
	"Economy",
	"Upgrades",
	"Rebirth",
	"Offline",
	"Plot",
	"Friends",
	"Mail",
	"TextFilter",
	"Streak",
	"Leaderboards",
	"Badges",
	"Notifications",
	"Quests",
	"Goals",
}

local function names(refs)
	local out = {}
	for _, ref in refs or {} do
		table.insert(out, ref.name)
	end
	table.sort(out)
	return out
end

local function sorted(t)
	local out = table.clone(t)
	table.sort(out)
	return out
end

describe("quests kit definitions", function()
	it("are normal modules on framework ^1.7.0 with their save sections and client parts", function()
		for _, ref in { Quests, Goals } do
			expect(StudWork.isModuleRef(ref)).toBe(true)
			expect(ref.version).toBe("1.0.0")
			expect(ref.framework).toBe("^1.7.0")
			expect(ref.data.version).toBe(1)
			expect(ref.data.replicate).toBe(false)
			expect(type(ref.data.sanitize)).toBe("function")
			expect(#(ref.dependsOn or {})).toBe(0)
		end
		expect(Quests.data.key).toBe("quests")
		expect(Goals.data.key).toBe("goals")
		expect(Quests.client).toBe("Quests")
		expect(Goals.client).toBe("Goals")
	end)

	it("declare exactly the page's optional dependencies", function()
		expect(names(Quests.optional)).toEqual(
			sorted({ "Economy", "Items", "Inventory", "Rarity", "Rebirth", "Streak", "Leaderboards" })
		)
		expect(names(Goals.optional)).toEqual(
			sorted({ "Quests", "Economy", "Inventory", "Rebirth", "Streak" })
		)
	end)

	it("carry the page's config defaults", function()
		local q = Quests.config.defaults
		expect(q.flag).toBe(nil)
		expect(q.quests).toEqual({})
		expect(q.chains).toEqual({})
		expect(q.daily).toEqual({ count = 3, rerollsPerSlot = 1 })
		expect(q.weekly).toEqual({ count = 2, rerollsPerSlot = 0 })
		expect(q.poolVersion).toBe(1)
		expect(q.utcOffsetHours).toBe(0)
		expect(q.weekStartsOn).toBe("monday")
		expect(q.autoClaim).toBe(false)
		expect(q.waitingMax).toBe(6)
		expect(q.pinMax).toBe(3)
		expect(q.foldSeconds).toBe(30)
		expect(q.replicateSeconds).toBe(1)
		expect(q.sourcePollSeconds).toBe(5)
		expect(q.rotatePerTick).toBe(10)
		expect(q.maxAmount).toBe(1000000)
		local schemaKeys = {}
		for k in Quests.config.schema do
			table.insert(schemaKeys, k)
		end
		expect(sorted(schemaKeys)).toEqual(sorted({
			"flag",
			"quests",
			"chains",
			"daily",
			"weekly",
			"poolVersion",
			"utcOffsetHours",
			"weekStartsOn",
			"autoClaim",
			"waitingMax",
			"pinMax",
			"foldSeconds",
			"replicateSeconds",
			"sourcePollSeconds",
			"rotatePerTick",
			"maxAmount",
		}))
		local g = Goals.config.defaults
		expect(g.flag).toBe(nil)
		expect(g.chain).toEqual({})
		expect(g.chainVersion).toBe(1)
		expect(g.skippable).toBe(true)
		expect(g.nextSeconds).toBe(5)
		expect(g.sourcePollSeconds).toBe(5)
		expect(g.pointer).toEqual({
			beam = true,
			edgeArrow = true,
			updateSeconds = 0.1,
			nearStuds = 8,
			maxStuds = 2000,
		})
	end)

	it("have the page's save section defaults", function()
		expect(Quests.data.default).toEqual({
			day = { id = -1, slots = {}, seen = {} },
			week = { id = -1, slots = {}, seen = {} },
			prog = {},
			done = {},
			waiting = {},
			pins = {},
			granted = {},
		})
		expect(Goals.data.default).toEqual({ done = {}, fin = false, hide = false, v = 0 })
	end)

	it("contribute the goalPointer theme colour", function()
		expect(Goals.theme.colors.goalPointer).toBe("#FFB547")
	end)
end)

describe("quests kit strings", function()
	it("register every static key and the per-quest / per-goal defaults", function()
		local captured
		local probe = StudWork.defineModule({ name = "Probe", version = "1.0.0", framework = "^1.7.0" })
		StudWork.test.harness({
			modules = { Quests, Goals, probe },
			config = {
				Quests = { daily = { count = 1 }, quests = { collectCoins = F.daily() } },
				Goals = { chain = { { id = "firstCoins", check = { call = true } } } },
			},
			servers = { Probe = {
				init = function(ctx)
					captured = ctx
				end,
			} },
		})
		local en = captured.text.english
		local expected = {
			["Quests.title"] = "Quests",
			["Quests.button"] = "Quests",
			["Quests.tab.daily"] = "Daily",
			["Quests.tab.weekly"] = "Weekly",
			["Quests.tab.chain"] = "Story",
			["Quests.tab.event"] = "Event",
			["Quests.tab.waiting"] = "Rewards waiting",
			["Quests.claim"] = "Claim",
			["Quests.claimed"] = "Claimed",
			["Quests.reroll"] = "Reroll",
			["Quests.pin"] = "Track",
			["Quests.unpin"] = "Untrack",
			["Quests.locked"] = "Locked",
			["Quests.capReached"] = "Come back later",
			["Quests.odds"] = "Odds",
			["Quests.empty"] = "No quests right now",
			["Quests.reward.custom"] = "Reward",
			["Quests.quest.collectCoins"] = "collectCoins",
			["Goals.hide"] = "Hide goals",
			["Goals.show"] = "Show goals",
			["Goals.goal.firstCoins"] = "firstCoins",
		}
		for key, text in expected do
			expect(key .. "=" .. en(key)).toBe(key .. "=" .. text)
		end
		expect(en("Quests.rerollsLeft", { n = 1 })).toBe("1 free")
		expect(en("Quests.resetsIn", { time = "2:05" })).toBe("Resets in 2:05")
		expect(en("Quests.resetsInDays", { days = 2, hours = 16 })).toBe("Resets in 2d 16h")
		expect(en("Quests.progress", { value = 2, target = 5 })).toBe("2/5")
		expect(en("Quests.toast.completed", { title = "X" })).toBe("Quest complete: X")
		expect(en("Quests.toast.claimed", { title = "X" })).toBe("Reward claimed: X")
		expect(en("Quests.reward.currency", { amount = 5, currency = "Coins" })).toBe("5 Coins")
		expect(en("Quests.reward.item", { item = "Gem" })).toBe("Gem")
		expect(en("Quests.reward.roll", { table = "Crate" })).toBe("Roll: Crate")
		expect(en("Quests.objective.counter", { key = "k" })).toBe("k")
		expect(en("Quests.objective.source", { source = "s" })).toBe("s")
		expect(en("Quests.objective.threshold", { target = 3, source = "s" })).toBe("Reach 3 s")
		expect(en("Quests.objective.ack", { key = "k" })).toBe("k")
	end)
end)

describe("quests kit boots with no config", function()
	it("each alone, and both together, with no warnings and both sections in the save", function()
		for _, modules in { { Quests }, { Goals }, { Quests, Goals } } do
			local h = StudWork.test.harness({ modules = modules })
			local p = h:addPlayer({ userId = 1 })
			expect(p.loaded).toBe(true)
			h:tick(2)
			expect(h:warnings()).toEqual({})
			h:removePlayer(p)
			local saved = h:saved(p)
			for _, ref in modules do
				expect(saved[ref.data.key]).toEqual(ref.data.default)
			end
		end
	end)

	it("next to every other kit module at its defaults (the tools/adopt --init shape)", function()
		-- the multi-server sim (module names): Plot needs CollectionService, which only the sim provides
		local world = StudWork.test.sim.world()
		local server = StudWork.test.sim.server(world, {
			config = {
				gameId = "adopted",
				modules = ALL_KITS,
				config = {},
				items = {},
				events = {},
				products = { passes = {}, devProducts = {} },
				data = { default = {}, version = 1 },
			},
		})
		expect(server.runtime.state).toBe("running")
		local p = server:join(7)
		expect(world:advanceUntil(function()
			return server:isLoaded(p)
		end, 30)).toBe(true)
		world:advance(5)
		expect(server:section(p, "quests")).never.toBe(nil)
		expect(server:section(p, "goals")).never.toBe(nil)
		server:leave(p)
		world:advance(5)
		expect(world:errors()).toEqual({})
		for _, w in server.warnings do
			expect(string.find(w, "Quests", 1, true) == nil and string.find(w, "Goals", 1, true) == nil).toBe(
				true
			)
		end
	end)

	it("with a flag that isn't declared, fails the boot (closed)", function()
		local _, errQ = StudWork.test.boot({ modules = { Quests }, config = { Quests = { flag = "nope" } } })
		expect(errQ).never.toBe(nil)
		local _, errG = StudWork.test.boot({ modules = { Goals }, config = { Goals = { flag = "nope" } } })
		expect(errG).never.toBe(nil)
	end)
end)

describe("a game that leaves the kit out", function()
	it("boots without it, and its API errors clearly", function()
		local h = StudWork.test.harness({ modules = {} })
		expect(h:warnings()).toEqual({})
		expect(pcall(function()
			return h:use(Quests).def("x")
		end)).toBe(false)
		expect(pcall(function()
			return h:use(Goals).current({ UserId = 1 })
		end)).toBe(false)
	end)
end)

describe("Quests server shape", function()
	it("has every api function on the page and the four signals", function()
		local h = StudWork.test.harness({ modules = { Quests } })
		local q = h:use(Quests)
		for _, fn in { "progress", "claim", "reroll", "active", "state", "def", "grant", "pin" } do
			expect(fn .. ":" .. type(q[fn])).toBe(fn .. ":function")
		end
		for _, s in { "Progressed", "Completed", "Claimed", "Rotated" } do
			expect(s .. ":" .. type(q.signals[s])).toBe(s .. ":table")
			expect(type(q.signals[s].Connect)).toBe("function")
		end
	end)

	it("def returns the frozen config entry with defaults filled in, nil for an unknown id", function()
		local h = StudWork.test.harness({
			modules = { Quests },
			config = { Quests = { daily = { count = 1 }, quests = { a = F.daily() } } },
		})
		local def = h:use(Quests).def("a")
		expect(def.id).toBe("a")
		expect(def.kind).toBe("daily")
		expect(def.title).toBe("Quests.quest.a")
		expect(def.weight).toBe(1)
		expect(def.cap).toBe(1)
		expect(def.period).toBe("daily")
		expect(def.offer).toBe("auto")
		expect(def.autoClaim).toBe(false)
		expect(def.retired).toBe(false)
		expect(def.reward).toEqual({})
		expect(table.isfrozen(def)).toBe(true)
		expect(table.isfrozen(def.objectives)).toBe(true)
		expect(h:use(Quests).def("missing")).toBe(nil)
	end)

	it("errors with the function name on programming errors", function()
		local h = StudWork.test.harness({ modules = { Quests } })
		local q = h:use(Quests)
		local p = h:addPlayer({ userId = 1 })
		local cases = {
			function()
				q.progress("notAPlayer", "k")
			end,
			function()
				q.progress(p, 5)
			end,
			function()
				q.claim(p, 5)
			end,
			function()
				q.claim(nil, "a")
			end,
			function()
				q.state(p, nil)
			end,
			function()
				q.def(5)
			end,
			function()
				q.grant(p, {})
			end,
			function()
				q.pin(p, 3, true)
			end,
		}
		for i, fn in cases do
			local ok, err = pcall(fn)
			expect(i .. ":" .. tostring(ok)).toBe(i .. ":false")
			expect(string.find(tostring(err), "Quests.", 1, true) ~= nil).toBe(true)
		end
	end)

	it("refuses a player that isn't loaded, and an unloaded player sees nothing", function()
		local h = StudWork.test.harness({
			modules = { Quests },
			config = { Quests = F.questsConfig() },
			events = F.events(),
		})
		local q = h:use(Quests)
		local stranger = StudWork.test.player(404)
		expect(q.progress(stranger, "oneTimeKey")).toBe(false)
		expect(select(2, q.claim(stranger, "once"))).toBe("not_loaded")
		expect(select(2, q.reroll(stranger, "daily", 1))).toBe("not_loaded")
		expect(select(2, q.grant(stranger, "gift"))).toBe("not_loaded")
		expect(select(2, q.pin(stranger, "once", true))).toBe("not_loaded")
		expect(#q.active(stranger)).toBe(0)
		expect(table.isfrozen(q.active(stranger))).toBe(true)
	end)

	it('refuses everything with "disabled" while its flag is off', function()
		local h = StudWork.test.harness({
			modules = { Quests },
			flags = { questsOn = { default = false } },
			config = { Quests = { flag = "questsOn", quests = { once = F.oneTime() } } },
		})
		local q = h:use(Quests)
		local p = h:addPlayer({ userId = 1 })
		expect(q.progress(p, "oneTimeKey")).toBe(false)
		expect(select(2, q.claim(p, "once"))).toBe("disabled")
		expect(select(2, q.reroll(p, "daily", 1))).toBe("disabled")
		expect(select(2, q.grant(p, "once"))).toBe("disabled")
		expect(select(2, q.pin(p, "once", true))).toBe("disabled")
		expect(h:warnings()).toEqual({})
	end)

	it(
		"offers registerSource / registerReward during init, refusing built-in names and duplicates",
		function()
			local results = {}
			local probe = StudWork.defineModule({
				name = "ExtProbe",
				version = "1.0.0",
				framework = "^1.7.0",
				optional = { Quests },
			})
			local saved
			F.harness({
				modules = { Quests, probe },
				servers = {
					ExtProbe = {
						init = function(ctx)
							local ext = ctx.depsExt[Quests]
							saved = ext
							local spec = {
								read = function()
									return 1
								end,
							}
							results.first = pcall(ext.registerSource, "mine", spec)
							results.dup = pcall(ext.registerSource, "mine", spec)
							results.builtin = pcall(ext.registerSource, "currency", spec)
							results.badSpec = pcall(ext.registerSource, "other", {})
							results.reward = pcall(ext.registerReward, "gift", function() end)
							results.rewardDup = pcall(ext.registerReward, "gift", function() end)
							results.rewardBad = pcall(ext.registerReward, "nofn", 5)
						end,
					},
				},
			})
			expect(results).toEqual({
				first = true,
				dup = false,
				builtin = false,
				badSpec = false,
				reward = true,
				rewardDup = false,
				rewardBad = false,
			})
			-- after init (boot validation already ran in start): refused
			expect(pcall(saved.registerSource, "late", {
				read = function()
					return 1
				end,
			})).toBe(false)
			expect(pcall(saved.registerReward, "late", function() end)).toBe(false)
		end
	)

	it("lets a registered source and reward satisfy validation (the fixtures' probes)", function()
		local source = F.valueSource({ name = "power" })
		local rewards = F.rewardModule({ handler = "badge" })
		local h = F.harness({
			modules = { Quests },
			probes = { source, rewards },
			config = {
				Quests = {
					quests = {
						strong = F.quest(
							"oneTime",
							{ F.threshold("power", 5) },
							{ reward = { F.custom("badge") } }
						),
					},
				},
			},
		})
		expect(h:use(Quests).def("strong").reward[1].handler).toBe("badge")
	end)

	it("declares the four actions with the page's limits", function()
		local Server =
			require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("Quests"))
		local part = Server.new()
		local limits = {
			claimQuest = { rate = 2, burst = 4 },
			rerollQuest = { rate = 1, burst = 2 },
			pinQuest = { rate = 2, burst = 4 },
			ackQuest = { rate = 1, burst = 3 },
		}
		local declared = {}
		for name, action in part.actions do
			table.insert(declared, name)
			expect(name .. ":" .. type(action.handler)).toBe(name .. ":function")
			expect(action.limit).toEqual(limits[name])
		end
		expect(sorted(declared)).toEqual(sorted({ "claimQuest", "rerollQuest", "pinQuest", "ackQuest" }))
		-- no action adds progress, completes or grants
		for name in part.actions do
			expect(string.find(string.lower(name), "progress", 1, true)).toBe(nil)
			expect(string.find(string.lower(name), "grant", 1, true)).toBe(nil)
			expect(string.find(string.lower(name), "complete", 1, true)).toBe(nil)
		end
	end)

	it("routes every action through the framework without erroring, unknown ids included", function()
		local h = StudWork.test.harness({
			modules = { Quests },
			config = { Quests = F.questsConfig() },
			events = F.events(),
		})
		local p = h:addPlayer({ userId = 1 })
		local calls = {
			{ "claimQuest", "nope" },
			{ "claimQuest", "d1" },
			{ "rerollQuest", "daily", 1 },
			{ "rerollQuest", "monthly", 9 },
			{ "pinQuest", "d1", true },
			{ "ackQuest", "nokey" },
		}
		for _, c in calls do
			local ok = pcall(h.action, h, p, Quests, table.unpack(c))
			expect(c[1] .. ":" .. tostring(ok)).toBe(c[1] .. ":true")
		end
	end)

	it("registers its console commands", function()
		local h = StudWork.test.harness({ modules = { Quests }, isStudio = false })
		local help = h:console("help")
		for _, cmd in { "quests state", "quests progress", "quests complete", "quests timeshift" } do
			expect(cmd .. ":" .. tostring(string.find(help, cmd, 1, true) ~= nil)).toBe(cmd .. ":true")
		end
	end)
end)

describe("Goals server shape", function()
	it("has every api function on the page and the two signals", function()
		local h = StudWork.test.harness({ modules = { Goals } })
		local g = h:use(Goals)
		for _, fn in { "current", "complete", "setChain", "setNext", "skip" } do
			expect(fn .. ":" .. type(g[fn])).toBe(fn .. ":function")
		end
		for _, s in { "GoalChanged", "ChainDone" } do
			expect(type(g.signals[s].Connect)).toBe("function")
		end
	end)

	it("refuses a player that isn't loaded and everything while its flag is off", function()
		local h = StudWork.test.harness({
			modules = { kit("Economy"), Goals },
			config = { Economy = F.economy(), Goals = { chain = F.goalsChain() } },
		})
		local g = h:use(Goals)
		local stranger = StudWork.test.player(404)
		expect(g.current(stranger)).toBe(nil)
		expect(select(2, g.complete(stranger, "first"))).toBe("not_loaded")
		local off = StudWork.test.harness({
			modules = { kit("Economy"), Goals },
			flags = { goalsOn = { default = false } },
			config = { Economy = F.economy(), Goals = { flag = "goalsOn", chain = F.goalsChain() } },
		})
		local p = off:addPlayer({ userId = 1 })
		expect(off:use(Goals).current(p)).toBe(nil)
		expect(select(2, off:use(Goals).complete(p, "first"))).toBe("disabled")
		expect(pcall(off:use(Goals).complete, "notAPlayer", "first")).toBe(false)
	end)

	it("skip answers false when goals aren't skippable", function()
		local h = StudWork.test.harness({ modules = { Goals }, config = { Goals = { skippable = false } } })
		local p = h:addPlayer({ userId = 1 })
		expect(h:use(Goals).skip(p, true)).toBe(false)
	end)

	it("setChain validates like the config chain and refuses once a player loaded", function()
		local results = {}
		local probe = StudWork.defineModule({
			name = "ChainProbe",
			version = "1.0.0",
			framework = "^1.7.0",
			dependsOn = { Goals },
		})
		local h = StudWork.test.harness({
			modules = { Goals, probe },
			servers = {
				ChainProbe = {
					start = function(ctx)
						local g = ctx.deps[Goals]
						results.bad = pcall(g.setChain, { { id = "x", check = { call = true, ack = true } } })
						results.good = pcall(g.setChain, { { id = "x", check = { call = true } } }, 2)
						results.next = pcall(g.setNext, function()
							return nil
						end)
						results.badNext = pcall(g.setNext, 5)
					end,
				},
			},
		})
		expect(results).toEqual({ bad = false, good = true, next = true, badNext = false })
		h:addPlayer({ userId = 1 })
		expect(pcall(h:use(Goals).setChain, { { id = "y", check = { call = true } } })).toBe(false)
	end)

	it("offers registerSource during init, refusing built-in names and duplicates", function()
		local results = {}
		local probe = StudWork.defineModule({
			name = "GExtProbe",
			version = "1.0.0",
			framework = "^1.7.0",
			optional = { Goals },
		})
		StudWork.test.harness({
			modules = { Goals, probe },
			servers = {
				GExtProbe = {
					init = function(ctx)
						local ext = ctx.depsExt[Goals]
						local spec = {
							read = function()
								return 1
							end,
						}
						results.first = pcall(ext.registerSource, "mine", spec)
						results.dup = pcall(ext.registerSource, "mine", spec)
						results.builtin = pcall(ext.registerSource, "streakDay", spec)
					end,
				},
			},
		})
		expect(results).toEqual({ first = true, dup = false, builtin = false })
	end)

	it("declares its two actions with the page's limits and routes them without erroring", function()
		local Server =
			require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("Goals"))
		local part = Server.new()
		expect(part.actions.skipGoals.limit).toEqual({ rate = 0.5, burst = 2 })
		expect(part.actions.ackGoal.limit).toEqual({ rate = 1, burst = 3 })
		local declared = {}
		for name in part.actions do
			table.insert(declared, name)
		end
		expect(sorted(declared)).toEqual({ "ackGoal", "skipGoals" })
		local h = StudWork.test.harness({
			modules = { kit("Economy"), Goals },
			config = { Economy = F.economy(), Goals = { chain = F.goalsChain() } },
		})
		local p = h:addPlayer({ userId = 1 })
		for _, c in { { "skipGoals", true }, { "ackGoal", "open" }, { "ackGoal", "nope" } } do
			local ok = pcall(h.action, h, p, Goals, table.unpack(c))
			expect(c[1] .. ":" .. tostring(ok)).toBe(c[1] .. ":true")
		end
	end)

	it("registers its console commands", function()
		local h = StudWork.test.harness({ modules = { Goals } })
		local help = h:console("help")
		for _, cmd in { "goals state", "goals complete", "goals reset" } do
			expect(cmd .. ":" .. tostring(string.find(help, cmd, 1, true) ~= nil)).toBe(cmd .. ":true")
		end
	end)
end)

describe("client parts shape", function()
	it("Quests declares its actions and every client api function", function()
		expect(sorted(QuestsClient.actions)).toEqual(
			sorted({ "claimQuest", "rerollQuest", "pinQuest", "ackQuest" })
		)
		for _, fn in { "active", "board", "onCompleted", "onClaimed", "open" } do
			expect(fn .. ":" .. type(QuestsClient.api[fn])).toBe(fn .. ":function")
		end
		expect(type(QuestsClient.api.read)).toBe("table")
		expect(type(QuestsClient.init)).toBe("function")
		expect(type(QuestsClient.start)).toBe("function")
	end)

	it("Goals declares its actions and every client api function", function()
		expect(sorted(GoalsClient.actions)).toEqual({ "ackGoal", "skipGoals" })
		for _, fn in { "goal", "pointer", "onChanged", "registerPicker", "setHidden" } do
			expect(fn .. ":" .. type(GoalsClient.api[fn])).toBe(fn .. ":function")
		end
		expect(type(GoalsClient.init)).toBe("function")
		expect(type(GoalsClient.start)).toBe("function")
	end)
end)

describe("sanitize (config-free shape repair)", function()
	local function many(n, make)
		local out = {}
		for i = 1, n do
			table.insert(out, make(i))
		end
		return out
	end

	it("never errors on garbage and returns the default shape", function()
		for _, garbage in
			{
				nil,
				5,
				"x",
				true,
				{},
				{ day = 5, week = "x", prog = 3, done = "y", waiting = 1, pins = true, granted = 2 },
			}
		do
			local ok, out = pcall(Quests.data.sanitize, garbage)
			expect(ok).toBe(true)
			expect(out.day).toEqual({ id = -1, slots = {}, seen = {} })
			expect(out.week).toEqual({ id = -1, slots = {}, seen = {} })
			expect(out.prog).toEqual({})
			expect(out.waiting).toEqual({})
			expect(out.pins).toEqual({})
			expect(out.granted).toEqual({})
			local okG, outG = pcall(Goals.data.sanitize, garbage)
			expect(okG).toBe(true)
			expect(outG.fin).toBe(false)
			expect(outG.hide).toBe(false)
			expect(outG.v).toBe(0)
		end
	end)

	it("cuts over-long lists at the hard maxima and drops malformed entries", function()
		local out = Quests.data.sanitize({
			day = {
				id = 20000,
				slots = many(9, function(i)
					return { q = "q" .. i, n = { 1, 2, 3, 4, 5, 6 }, s = 1, r = 1 }
				end),
				seen = { a = true, b = false, ["bad id!"] = true, c = "yes" },
			},
			week = {
				id = 19998,
				slots = { { q = 5 }, "x", { q = "ok", n = { -3, 0 / 0, 2.7 }, s = 9, r = -1 } },
			},
			prog = { good = { n = { 1 }, s = 2, p = 20000, k = 2 }, bad = "x", [7] = { n = {} } },
			done = { claimed = 123, weird = true, ["no way"] = 5 },
			waiting = many(20, function(i)
				return { q = "w" .. i, k = "daily", p = i }
			end),
			pins = { "a", "a", "b", 5, "c", "d", "e", "f", "g" },
			granted = { gift = true, nope = 1 },
		})
		expect(out.day.id).toBe(20000)
		expect(#out.day.slots).toBe(6)
		expect(#out.day.slots[1].n).toBe(4)
		expect(out.day.seen).toEqual({ a = true, b = false })
		expect(out.week.slots).toEqual({ { q = "ok", n = { 0, 0, 2 }, s = 0, r = 0 } })
		expect(out.prog).toEqual({ good = { n = { 1 }, s = 2, p = 20000, k = 2 } })
		expect(out.done).toEqual({ claimed = 123, weird = 0 }) -- the ledger keeps a claim with a bad timestamp
		expect(#out.waiting).toBe(12)
		expect(out.waiting[1].q).toBe("w9") -- oldest dropped first
		expect(out.waiting[12].q).toBe("w20")
		expect(out.pins).toEqual({ "a", "b", "c", "d", "e" })
		expect(out.granted).toEqual({ gift = true })

		local done = {}
		for i = 1, 30 do
			done["g" .. string.format("%02d", i)] = true
		end
		done["bad id"] = true
		local g = Goals.data.sanitize({ done = done, fin = "yes", hide = true, v = 3.7 })
		local count = 0
		for _ in g.done do
			count += 1
		end
		expect(count).toBe(20)
		expect(g.fin).toBe(false)
		expect(g.hide).toBe(true)
		expect(g.v).toBe(3)
	end)

	it("loads an old garbage save through the framework without kicking", function()
		local store = StudWork.test.memoryStore()
		local first = StudWork.test.harness({ modules = { Quests, Goals }, store = store })
		local p = first:addPlayer({ userId = 3 })
		first:removePlayer(p)
		local save = first:saved(p)
		save.quests = { day = "broken", pins = { 1, 2, 3 }, waiting = { { q = "x" } }, done = { old = true } }
		save.goals = { done = 5, v = -2 }
		local second =
			StudWork.test.harness({ modules = { Quests, Goals }, store = StudWork.test.memoryStore() })
		local again = second:addPlayer({ userId = 3, data = save })
		expect(again.loaded).toBe(true)
		expect(again.kicked).toBeFalsy()
		second:removePlayer(again)
		expect(second:saved(again).quests.done).toEqual({ old = 0 })
		expect(second:saved(again).goals.v).toBe(0)
	end)
end)
