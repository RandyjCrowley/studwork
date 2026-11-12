--!nocheck
--[[
	v1.7.0 foundation: the wiring. A probe module captures its scoped ctx through the harness, and the
	spec checks every v1.7.0 field is there and reaches the in-memory stores, services, Open Cloud,
	policy, flags and strings (module-api.md §23). Behaviour beyond "it is wired" is each surface's
	builder's.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local fakes = StudWork.test.fakes

local function probe(strings)
	local captured = {}
	local ref = StudWork.defineModule({
		name = "Probe",
		version = "1.0.0",
		framework = "^1.7.0",
		strings = strings or { ["Probe.hello"] = "Hello {name}" },
	})
	local part = {
		init = function(ctx)
			captured.ctx = ctx
		end,
	}
	return ref, part, captured
end

local function boot(opts)
	local ref, part, captured = probe(opts and opts.strings)
	local o = { modules = { ref }, servers = { Probe = part } }
	for k, v in opts or {} do
		if k == "gameStrings" then
			o.strings = v -- GameConfig.strings
		elseif k ~= "strings" then
			o[k] = v
		end
	end
	local h = StudWork.test.harness(o)
	return h, captured.ctx
end

describe("scoped ctx (v1.7.0 fields)", function()
	it("has env, flags, services, openCloud, text and data.ordered / sortedMap / census", function()
		local _, ctx = boot()
		expect(type(ctx.env.name)).toBe("function")
		expect(type(ctx.flags.isOn)).toBe("function")
		expect(type(ctx.services.get)).toBe("function")
		expect(type(ctx.openCloud.request)).toBe("function")
		expect(type(ctx.openCloud.available)).toBe("function")
		expect(type(ctx.text.format)).toBe("function")
		expect(type(ctx.text.english)).toBe("function")
		expect(type(ctx.data.ordered)).toBe("function")
		expect(type(ctx.data.sortedMap)).toBe("function")
		expect(type(ctx.data.census)).toBe("function")
		expect(type(ctx.policy.allows)).toBe("function")
	end)
end)

describe("environment", function()
	it("is live by default, studio in Studio, forced by harness env, test by placeId", function()
		local _, a = boot()
		expect(a.env.name()).toBe("live")
		local _, b = boot({ isStudio = true })
		expect(b.env.name()).toBe("studio")
		local _, c = boot({ env = "test" })
		expect(c.env.name()).toBe("test")
		local _, d = boot({ placeId = 77, environments = { test = { placeIds = { 77 } } } })
		expect(d.env.name()).toBe("test")
		expect(d.env.placeId()).toBe(77)
		expect(StudWork.env.name()).toBe("test")
	end)

	it("an id under both test and live is a boot error", function()
		local ref = StudWork.defineModule({ name = "Probe", version = "1.0.0", framework = "^1.7.0" })
		local h, err = StudWork.test.boot({
			modules = { ref },
			servers = { Probe = {} },
			environments = { test = { placeIds = { 1 } }, live = { placeIds = { 1 } } },
		})
		expect(h).toBe(nil)
		expect(string.find(err, "both test and live", 1, true) ~= nil).toBe(true)
	end)
end)

describe("flags", function()
	local flags = {
		shop = { default = false, test = true },
		debug = { default = false, test = true, testOnly = true },
		secret = { default = true, serverOnly = true },
	}

	it("resolve per environment and replicate (never a serverOnly flag)", function()
		local h, ctx = boot({ flags = flags, env = "test" })
		expect(ctx.flags.isOn("shop")).toBe(true)
		expect(StudWork.flags.isOn("debug")).toBe(true)
		local p = h:addPlayer({ userId = 1 })
		local fw = h:state(p).framework
		expect(fw.env).toBe("test")
		expect(fw.flags.shop).toBe(true)
		expect(fw.flags.secret).toBe(nil)
		local _, live = boot({ flags = flags, env = "live" })
		expect(live.flags.isOn("shop")).toBe(false)
	end)

	it("a testOnly flag that would be on in live is a boot error", function()
		local ref = StudWork.defineModule({ name = "Probe", version = "1.0.0", framework = "^1.7.0" })
		local h, err = StudWork.test.boot({
			modules = { ref },
			servers = { Probe = {} },
			flags = { dbg = { default = false, live = true, testOnly = true } },
		})
		expect(h).toBe(nil)
		expect(string.find(err, "testOnly", 1, true) ~= nil).toBe(true)
	end)

	it("ServerConfig.flags are hidden; a clash with GameConfig.flags is a boot error", function()
		local h, ctx = boot({ serverConfig = { flags = { hidden = { default = true } } } })
		expect(ctx.flags.isOn("hidden")).toBe(true)
		local p = h:addPlayer({ userId = 1 })
		expect(h:state(p).framework.flags.hidden).toBe(nil)
		local ref = StudWork.defineModule({ name = "Probe", version = "1.0.0", framework = "^1.7.0" })
		local bad, err = StudWork.test.boot({
			modules = { ref },
			servers = { Probe = {} },
			flags = { a = { default = true } },
			serverConfig = { flags = { a = { default = true } } },
		})
		expect(bad).toBe(nil)
		expect(string.find(err, "both GameConfig.flags and ServerConfig.flags", 1, true) ~= nil).toBe(true)
	end)

	it("the console lists flags and sets a Studio override", function()
		local h, ctx = boot({ flags = flags, env = "live", isStudio = true })
		expect(string.find(h:console("flags"), "shop = false", 1, true) ~= nil).toBe(true)
		h:console("flags set shop true")
		expect(ctx.flags.isOn("shop")).toBe(true)
		expect(ctx.flags.source("shop")).toBe("override")
	end)
end)

describe("ordered stores (in memory)", function()
	it("set / get / update / top / remove through ctx.data.ordered, backed by h:orderedStore", function()
		local h, ctx = boot()
		local board = ctx.data.ordered("scores")
		expect(board.set("1", 5)).toBe(true)
		expect(board.set("2", 9)).toBe(true)
		local ok, v = board.get("1")
		expect(ok).toBe(true)
		expect(v).toBe(5)
		local _, updated = board.update("1", function(old)
			return math.max(old or 0, 7)
		end)
		expect(updated).toBe(7)
		local _, rows = board.top(10, "desc")
		expect(rows[1].key).toBe("2")
		expect(rows[2].value).toBe(7)
		expect(board.remove("2")).toBe(true)
		expect(h:orderedStore("Probe", "scores").entries()).toEqual({ ["1"] = 7 })
	end)

	it('failure injection returns (false, "failed") and never raises', function()
		local h, ctx = boot()
		local board = ctx.data.ordered("scores")
		h:orderedStore("Probe", "scores").failNext(3) -- the first try and both retries (§23.3)
		local ok, reason = board.set("1", 5)
		expect(ok).toBe(false)
		expect(reason).toBe("failed")
		expect(board.set("1", 5)).toBe(true)
	end)

	it("two harnesses on one memoryStore share the data", function()
		local store = StudWork.test.memoryStore()
		local _, a = boot({ store = store })
		local _, b = boot({ store = store })
		a.data.ordered("scores").set("1", 3)
		local _, v = b.data.ordered("scores").get("1")
		expect(v).toBe(3)
	end)
end)

describe("sorted maps (in memory)", function()
	it("set / get / range / expiry on the harness clock", function()
		local h, ctx = boot()
		local map = ctx.data.sortedMap("daily/1")
		expect(map.set("a", { n = 1 }, 100, 10)).toBe(true)
		expect(map.set("b", { n = 2 }, 10, 20)).toBe(true)
		local ok, value, sortKey = map.get("a")
		expect(ok).toBe(true)
		expect(value.n).toBe(1)
		expect(sortKey).toBe(10)
		local _, rows = map.range("desc", 10)
		expect(rows[1].key).toBe("b")
		local _, above = map.range("asc", 10, { sortKey = 10 })
		expect(#above).toBe(1)
		h:tick(11)
		local _, remaining = map.range("asc", 10)
		expect(#remaining).toBe(1)
		expect(remaining[1].key).toBe("a")
	end)

	it("update, remove, injected failure and the throttle code mapping", function()
		local h, ctx = boot()
		local map = ctx.data.sortedMap("m")
		map.set("k", 1, 60)
		local ok, new = map.update("k", function(old)
			return old + 1
		end, 60)
		expect(ok).toBe(true)
		expect(new).toBe(2)
		h:sortedMap("Probe", "m").failNext(3, "PartitionRequestsOverLimit") -- the first try and both retries (§23.4)
		local failed, reason = map.set("k", 3, 60)
		expect(failed).toBe(false)
		expect(reason).toBe("throttled")
		expect(map.remove("k")).toBe(true)
		expect(h:sortedMap("Probe", "m").entries()).toEqual({})
	end)

	it("applies the per-partition request limit and the experience memory quota", function()
		local store = StudWork.test.memoryStore({ sortedMap = { partitionLimit = 3, quotaBytes = 400 } })
		local _, ctx = boot({ store = store })
		local map = ctx.data.sortedMap("m")
		expect(map.set("a", 1, 60)).toBe(true)
		expect(map.set("b", 1, 60)).toBe(true)
		expect(map.set("c", 1, 60)).toBe(true)
		local ok, reason = map.set("d", 1, 60)
		expect(ok).toBe(false)
		expect(reason).toBe("throttled")
		local big = StudWork.test.memoryStore({ sortedMap = { quotaBytes = 100 } })
		local _, ctx2 = boot({ store = big })
		local ok2, reason2 = ctx2.data.sortedMap("m").set("k", string.rep("x", 200), 60)
		expect(ok2).toBe(false)
		expect(reason2).toBe("memory_full")
	end)
end)

describe("census", function()
	it("is nil until read, or the harness's fixed reading", function()
		local _, none = boot()
		expect(none.data.census()).toBe(nil)
		local _, fixed = boot({ census = { servers = 3, players = 10, peakPlayers = 25 } })
		local c = fixed.data.census()
		expect(c.servers).toBe(3)
		expect(c.players).toBe(10)
		expect(c.peakPlayers).toBe(25)
	end)
end)

describe("services and Open Cloud", function()
	it("ctx.services.get returns the harness fake and refuses framework-surface services", function()
		local badge = fakes.badgeService({})
		local _, ctx = boot({ services = { BadgeService = badge } })
		expect(ctx.services.get("BadgeService")).toBe(badge)
		expect(pcall(ctx.services.get, "DataStoreService")).toBe(false)
		expect(pcall(function()
			ctx.services.get("UserService"):GetUserInfosByUserIdsAsync({ 1 })
		end)).toBe(false) -- no test fake
	end)

	it("ctx.openCloud sends only what ServerConfig.openCloud allows, through the fake", function()
		local oc = fakes.openCloud()
		local _, ctx = boot({
			openCloud = oc,
			secrets = { Key = true },
			serverConfig = {
				openCloud = {
					secrets = {
						Key = {
							modules = { "Probe" },
							methods = { "POST" },
							paths = { "users/*/notifications" },
						},
					},
				},
			},
		})
		expect(ctx.openCloud.available("Key")).toBe(true)
		expect(ctx.openCloud.available("Other")).toBe(false)
		local ok, status = ctx.openCloud.request({
			secret = "Key",
			method = "POST",
			path = "users/9/notifications",
			body = { a = 1 },
		})
		expect(ok).toBe(true)
		expect(status).toBe(200)
		expect(#oc.requests).toBe(1)
		expect(oc.requests[1].secret).toBe("Key")
		local _, _, why1 =
			ctx.openCloud.request({ secret = "Key", method = "GET", path = "users/9/notifications" })
		local _, _, why2 =
			ctx.openCloud.request({ secret = "Key", method = "POST", path = "universes/1/data-stores/x" })
		local _, _, why3 =
			ctx.openCloud.request({ secret = "Other", method = "POST", path = "users/9/notifications" })
		expect(why1).toBe("not_allowed")
		expect(why2).toBe("forbidden")
		expect(why3).toBe("not_allowed")
		expect(#oc.requests).toBe(1)
	end)

	it("a bad ServerConfig.openCloud shape is a boot error", function()
		local ref = StudWork.defineModule({ name = "Probe", version = "1.0.0", framework = "^1.7.0" })
		local h, err = StudWork.test.boot({
			modules = { ref },
			servers = { Probe = {} },
			serverConfig = {
				openCloud = { secrets = { Key = { modules = {}, methods = { "FETCH" }, paths = { "a" } } } },
			},
		})
		expect(h).toBe(nil)
		expect(string.find(err, "ServerConfig.openCloud", 1, true) ~= nil).toBe(true)
	end)
end)

describe("ctx.policy.allows", function()
	it("is false until known, then the field; an unknown field errors", function()
		local h, ctx = boot({
			policy = { [1] = { IsContentSharingAllowed = true }, [2] = { IsContentSharingAllowed = false } },
		})
		local a = h:addPlayer({ userId = 1 })
		local b = h:addPlayer({ userId = 2 })
		expect(ctx.policy.allows(a, "IsContentSharingAllowed")).toBe(true)
		expect(ctx.policy.allows(b, "IsContentSharingAllowed")).toBe(false)
		expect(ctx.policy.allows({ UserId = 9 }, "IsContentSharingAllowed")).toBe(false)
		expect(pcall(ctx.policy.allows, a, "NoSuchField")).toBe(false)
		expect(ctx.policy.paidRandomRestricted(a)).toBe(false)
	end)
end)

describe("strings", function()
	it("ctx.text resolves a module default, GameConfig.strings and the framework keys", function()
		local h, ctx = boot({ strings = { ["Probe.hello"] = "Hello {name}" } })
		expect(ctx.text.english("Probe.hello", { name = "Ada" })).toBe("Hello Ada")
		expect(ctx.text.english("framework.kick.sessionEnded")).toBe(
			"Your save data was opened in another server. Please rejoin."
		)
		local p = h:addPlayer({ userId = 1 })
		expect(ctx.text.format(p, "Probe.hello", { name = "Bo" })).toBe("Hello Bo")
		expect(ctx.text.english("Probe.missing")).toBe("Probe.missing")
		local _, reworded = boot({ gameStrings = { ["Probe.hello"] = "Howdy {name}" } })
		expect(reworded.text.english("Probe.hello", { name = "Cy" })).toBe("Howdy Cy")
	end)

	it("GameConfig.strings reword a key and the player's translator wins", function()
		local translator = fakes.translator({ locale = "es", entries = { ["Probe.hello"] = "Hola {name}" } })
		local h, ctx = boot({
			strings = { ["Probe.hello"] = "Hello {name}" },
			localization = { sourceLocale = "en" },
			translator = translator,
			locale = "es",
		})
		local p = h:addPlayer({ userId = 1 })
		expect(ctx.text.format(p, "Probe.hello", { name = "Ana" })).toBe("Hola Ana")
		-- a key the translator has no entry for falls back to English
		expect(ctx.text.format(p, "TextFallback.none") ~= "").toBe(true)
		expect(ctx.text.format(p, "framework.kick.saveFailed")).toBe(
			"Your save couldn't be loaded safely, so nothing was changed. Please rejoin in a moment."
		)
	end)

	it("a module's strings function gets the merged config", function()
		local ref = StudWork.defineModule({
			name = "Probe",
			version = "1.0.0",
			framework = "^1.7.0",
			config = { schema = { names = "{string}" }, defaults = { names = { "a", "b" } } },
			strings = function(config)
				local out = {}
				for _, n in config.names do
					out["Probe.name." .. n] = string.upper(n)
				end
				return out
			end,
		})
		local captured
		local h = StudWork.test.harness({
			modules = { ref },
			servers = { Probe = {
				init = function(ctx)
					captured = ctx
				end,
			} },
		})
		expect(h).never.toBe(nil)
		expect(captured.text.english("Probe.name.a")).toBe("A")
		expect(captured.text.english("Probe.name.b")).toBe("B")
	end)
end)
