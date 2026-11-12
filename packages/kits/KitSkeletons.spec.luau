--!nocheck
--[[
	v1.7.0 kit skeletons (Notifications, Leaderboards, Badges, TextFilter): each boots through the harness
	with its config defaults, owns its save section, registers its strings, and its empty API answers with
	the documented safe defaults. Behaviour specs belong to each kit's builder.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")

local function kit(name)
	return require(Modules:WaitForChild(name):WaitForChild("module"))
end
local Notifications = kit("Notifications")
local Leaderboards = kit("Leaderboards")
local Badges = kit("Badges")
local TextFilter = kit("TextFilter")

describe("v1.7.0 kit definitions", function()
	it("are normal modules on framework ^1.7.0 with their save sections", function()
		for _, ref in { Notifications, Leaderboards, Badges, TextFilter } do
			expect(StudWork.isModuleRef(ref)).toBe(true)
			expect(ref.version).toBe("1.0.0")
			expect(ref.framework).toBe("^1.7.0")
			expect(ref.data.version).toBe(1)
		end
		expect(Notifications.data.key).toBe("notifications")
		expect(Leaderboards.data.key).toBe("leaderboards")
		expect(Badges.data.key).toBe("badges")
		expect(TextFilter.data.key).toBe("textfilter")
		expect(TextFilter.data.replicate).toBe(false)
		expect(Notifications.data.default.scheduled).toBe(nil) -- the schedule lives in the shared ledger
		expect(TextFilter.data.default.originals).toEqual({})
		expect(TextFilter.data.default.nextId).toBe(1)
		expect(Badges.data.replicate).toEqual({ "awarded" })
	end)

	it("declare their client parts (TextFilter has none)", function()
		expect(Notifications.client).toBe("Notifications")
		expect(Leaderboards.client).toBe("Leaderboards")
		expect(Badges.client).toBe("Badges")
		expect(TextFilter.client).toBe(nil)
	end)

	it("carry the pages' config defaults", function()
		local n = Notifications.config.defaults
		expect(n.secret).toBe("OpenCloudNotifications")
		expect(n.optIn.minSessionSeconds).toBe(180)
		expect(n.schedule.shards).toBe(4)
		expect(n.retry).toEqual({ base = 30, factor = 2, max = 900, attempts = 4 })
		local l = Leaderboards.config.defaults
		expect(l.refreshSeconds).toBe(60)
		expect(l.topReadsPerMinute).toBe(6000)
		expect(l.weekStartsOn).toBe("monday")
		local b = Badges.config.defaults
		expect(b.budget.perMinute).toEqual({ base = 50, perPlayer = 35 })
		expect(b.retry.attempts).toBe(6)
		local t = TextFilter.config.defaults
		expect(t.maxLength).toBe(40)
		expect(t.cache).toEqual({ maxEntries = 500, seconds = 600 })
		expect(t.fallbackKey).toBe("TextFilter.hidden")
	end)
end)

describe("v1.7.0 kit skeletons boot", function()
	local config = {
		Leaderboards = { boards = { coins = { period = "allTime" } } },
		Badges = { badges = { first = { id = 0, trigger = { kind = "manual" } } } },
	}
	local function harness()
		return StudWork.test.harness({
			modules = { Leaderboards, Badges, Notifications, TextFilter },
			config = config,
		})
	end

	it("boot with no errors or warnings and every section in the save", function()
		local h = harness()
		local p = h:addPlayer({ userId = 1 })
		expect(h:warnings()).toEqual({})
		h:removePlayer(p)
		local saved = h:saved(p)
		expect(saved.leaderboards).never.toBe(nil)
		expect(saved.badges.awarded).toEqual({})
		expect(saved.notifications.sessions).toBe(0)
		expect(saved.textfilter.nextId).toBe(1)
		expect(StudWork.use(Notifications)).never.toBe(nil)
	end)

	it("register their strings, including the function forms built from config", function()
		local captured
		local probe = StudWork.defineModule({ name = "Probe", version = "1.0.0", framework = "^1.7.0" })
		StudWork.test.harness({
			modules = { Leaderboards, Badges, TextFilter, probe },
			config = config,
			servers = {
				Probe = {
					init = function(ctx)
						captured = ctx
					end,
				},
			},
		})
		expect(captured.text.english("Leaderboards.title")).toBe("Leaderboards")
		expect(captured.text.english("Leaderboards.board.coins")).toBe("coins")
		expect(captured.text.english("Badges.awarded", { name = "First" })).toBe("Badge earned: First")
		expect(captured.text.english("Badges.badge.first")).toBe("first")
		expect(captured.text.english("TextFilter.hidden")).toBe("...")
	end)

	it("the empty APIs answer with the documented safe defaults", function()
		local h = harness()
		local p = h:addPlayer({ userId = 1 })
		local n = h:use(Notifications)
		expect(select(2, n.send(1, "x"))).toBe("disabled")
		expect(n.cancel(1, "x")).toBe(false)
		expect(n.suggestOptIn(p, "test")).toBe(false)
		local lb = h:use(Leaderboards)
		expect(lb.submit(p, "coins", 5)).toBe(true) -- a configured submit board accepts it
		expect(lb.submit(p, "nope", 5)).toBe(false)
		expect(lb.top("coins").rows).toEqual({}) -- nothing read from the stores yet
		local b = h:use(Badges)
		expect(b.award(p, "first")).toBe(false)
		expect(b.has(p, "first")).toBe(false)
		-- TextFilter fails closed: nothing unfiltered ever comes out
		local tf = h:use(TextFilter)
		local ok, reason = tf.filter(p, "hello", "public")
		expect(ok).toBe(false)
		expect(reason).toBe("filter_failed")
		expect(tf.textFor(p, p, "hello", "public")).toBe(nil)
		expect(tf.shown({}, p)).toBe(nil)
	end)

	it("Notifications declares its client actions as module actions", function()
		local h = harness()
		local p = h:addPlayer({ userId = 1 })
		expect(h:action(p, Notifications, "optInShown", "r1", true)).toBe(true)
		expect(h:action(p, Notifications, "setUtcOffset", 2)).toBe(true)
	end)
end)

describe("a game that leaves the kits out", function()
	it("boots without them", function()
		local h = StudWork.test.harness({ modules = {} })
		expect(h:warnings()).toEqual({})
		expect(pcall(function()
			return h:use(Badges).has({ UserId = 1 }, "x")
		end)).toBe(false) -- the module isn't enabled: its API errors clearly
	end)
end)
