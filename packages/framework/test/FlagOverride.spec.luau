--!nocheck
--[[
	v1.7.0 live flag override (module-api.md §23.2, docs/framework/kits/environments.md): the
	experience configs read through the ConfigService fake, applied at boot without blocking it,
	changes picked up within refreshSeconds without a restart, failures keeping the last good
	values, wrong types ignored with one warning, and testOnly never switched on in live.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Framework = ReplicatedStorage:WaitForChild("Framework")
local StudWork = require(Framework)
local Flags = require(Framework:WaitForChild("Flags"))
local FlagOverride = require(script.Parent.Parent.server.FlagOverride)
local fakes = StudWork.test.fakes

local DEFS = {
	newShop = { default = false },
	weekly = { default = true },
	debugPanel = { testOnly = true, default = false, test = true },
	pinned = { default = false, override = false },
}

local function boot(opts)
	local captured = {}
	local o = {
		modules = { StudWork.defineModule({ name = "Probe", version = "1.0.0", framework = "^1.7.0" }) },
		servers = {
			Probe = {
				init = function(ctx)
					captured.ctx = ctx
				end,
			},
		},
		flags = DEFS,
		env = "live",
	}
	for k, v in opts or {} do
		o[k] = v
	end
	local h, err = StudWork.test.boot(o)
	assert(h, err)
	return h, captured.ctx
end

local function count(fake, method)
	local n = 0
	for _, c in fake.calls do
		if c.method == method then
			n += 1
		end
	end
	return n
end

local function warned(h, text)
	local n = 0
	for _, w in h:warnings() do
		if string.find(w, text, 1, true) then
			n += 1
		end
	end
	return n
end

local ON = { enabled = true, refreshSeconds = 30 }

describe("the live flag override", function()
	it("is off by default: ConfigService is never read", function()
		local cs = fakes.configService({ values = { flag_newShop = true } })
		local _, ctx = boot({ services = { ConfigService = cs } })
		expect(#cs.calls).toBe(0)
		expect(ctx.flags.isOn("newShop")).toBe(false)
	end)

	it("applies the experience configs at boot, as source override", function()
		local cs = fakes.configService({ values = { flag_newShop = true, flag_weekly = false } })
		local h, ctx = boot({ services = { ConfigService = cs }, flagOverride = ON })
		expect(ctx.flags.isOn("newShop")).toBe(true)
		expect(ctx.flags.source("newShop")).toBe("override")
		expect(ctx.flags.isOn("weekly")).toBe(false)
		local p = h:addPlayer({ userId = 1 })
		expect(h:state(p).framework.flags.newShop).toBe(true)
	end)

	it("uses keyPrefix and never reads a flag with override = false", function()
		local cs =
			fakes.configService({ values = { ff_newShop = true, ff_pinned = true, flag_weekly = false } })
		local _, ctx = boot({
			services = { ConfigService = cs },
			flagOverride = { enabled = true, keyPrefix = "ff_" },
		})
		expect(ctx.flags.isOn("newShop")).toBe(true)
		expect(ctx.flags.isOn("weekly")).toBe(true) -- flag_ isn't this game's prefix
		expect(ctx.flags.isOn("pinned")).toBe(false)
		for _, c in cs.calls do
			expect(c.key ~= "ff_pinned").toBe(true)
		end
	end)

	it("picks up a published change within refreshSeconds, fires onChanged and replicates", function()
		local cs = fakes.configService({ values = {} })
		local h, ctx = boot({ services = { ConfigService = cs }, flagOverride = ON })
		local p = h:addPlayer({ userId = 1 })
		local fired = {}
		ctx.flags.onChanged("newShop", function(on)
			table.insert(fired, on)
		end)
		h:tick(5)
		cs.set("flag_newShop", true)
		cs.publish() -- UpdateAvailable: the first refresh is due 30 s after the boot read
		expect(ctx.flags.isOn("newShop")).toBe(false)
		h:tick(25)
		expect(ctx.flags.isOn("newShop")).toBe(true)
		expect(fired[1]).toBe(true)
		expect(h:state(p).framework.flags.newShop).toBe(true)
	end)

	it("refreshes at most once per refreshSeconds however often configs change", function()
		local cs = fakes.configService({ values = {} })
		local h, ctx = boot({ services = { ConfigService = cs }, flagOverride = ON })
		h:tick(30)
		for i = 1, 5 do
			cs.set("flag_newShop", i % 2 == 1)
			cs.publish()
		end
		expect(count(cs, "Refresh")).toBe(1) -- the interval had passed: the first one refreshes now
		expect(ctx.flags.isOn("newShop")).toBe(true)
		cs.set("flag_newShop", false)
		cs.publish()
		cs.publish()
		expect(count(cs, "Refresh")).toBe(1)
		h:tick(30)
		expect(count(cs, "Refresh")).toBe(2)
		expect(ctx.flags.isOn("newShop")).toBe(false)
	end)

	it("polls Outdated, so a missed update event is still picked up", function()
		local cs = fakes.configService({ values = {} })
		local h, ctx = boot({ services = { ConfigService = cs }, flagOverride = ON })
		cs.set("flag_newShop", true)
		cs.publishQuietly()
		h:tick(29)
		expect(ctx.flags.isOn("newShop")).toBe(false)
		h:tick(1)
		expect(ctx.flags.isOn("newShop")).toBe(true)
	end)

	it("a key that disappears clears the override (back to config)", function()
		local cs = fakes.configService({ values = { flag_newShop = true } })
		local h, ctx = boot({ services = { ConfigService = cs }, flagOverride = ON })
		expect(ctx.flags.isOn("newShop")).toBe(true)
		h:tick(30)
		cs.set("flag_newShop", nil)
		cs.publish()
		expect(ctx.flags.isOn("newShop")).toBe(false)
		expect(ctx.flags.source("newShop")).toBe("config")
	end)

	it("a wrong type is ignored with one warning per key", function()
		local cs = fakes.configService({ values = { flag_newShop = "true", flag_weekly = 0 } })
		local h, ctx = boot({ services = { ConfigService = cs }, flagOverride = ON })
		expect(ctx.flags.isOn("newShop")).toBe(false)
		expect(ctx.flags.isOn("weekly")).toBe(true)
		h:tick(30)
		cs.publish()
		h:tick(30)
		cs.publish()
		expect(warned(h, "'flag_newShop' is a string, not a boolean")).toBe(1)
		expect(warned(h, "'flag_weekly' is a number")).toBe(1)
	end)

	it("never blocks boot: a failing first read keeps config values and retries with backoff", function()
		local cs = fakes.configService({ values = { flag_newShop = true }, failNext = 3 })
		local h, ctx =
			boot({ services = { ConfigService = cs }, flagOverride = { enabled = true, refreshSeconds = 5 } })
		expect(ctx.flags.isOn("newShop")).toBe(false) -- booted on config values
		expect(warned(h, "reading experience configs failed")).toBe(1)
		h:tick(5) -- retry 1 (5 s): fails
		expect(count(cs, "GetConfigAsync")).toBe(2)
		h:tick(10) -- retry 2 (10 s): fails
		expect(count(cs, "GetConfigAsync")).toBe(3)
		h:tick(19)
		expect(count(cs, "GetConfigAsync")).toBe(3)
		h:tick(1) -- retry 3: 20 s = the cap (refreshSeconds x 4)
		expect(count(cs, "GetConfigAsync")).toBe(4)
		expect(ctx.flags.isOn("newShop")).toBe(true)
	end)

	it("the retry delay never exceeds refreshSeconds x 4", function()
		local cs = fakes.configService({ values = { flag_newShop = true }, failNext = 6 })
		local h, ctx =
			boot({ services = { ConfigService = cs }, flagOverride = { enabled = true, refreshSeconds = 5 } })
		h:tick(5 + 10 + 20 + 20 + 20 + 20)
		expect(count(cs, "GetConfigAsync")).toBe(7)
		expect(ctx.flags.isOn("newShop")).toBe(true)
	end)

	it("no ConfigService at all (no fake): config values, a warning, never an error", function()
		local h, ctx = boot({ flagOverride = ON })
		expect(ctx.flags.isOn("newShop")).toBe(false)
		expect(warned(h, "reading experience configs failed")).toBe(1)
	end)

	it("a failed refresh keeps the last good values; the next one takes the new ones", function()
		local cs = fakes.configService({ values = { flag_newShop = true } })
		local h, ctx = boot({ services = { ConfigService = cs }, flagOverride = ON })
		h:tick(30)
		cs.set("flag_newShop", false)
		cs.failRefreshNext(1)
		cs.publish()
		expect(ctx.flags.isOn("newShop")).toBe(true)
		expect(warned(h, "keeping the last values")).toBe(1)
		h:tick(30) -- the snapshot is still Outdated: the poll refreshes again
		expect(ctx.flags.isOn("newShop")).toBe(false)
	end)

	it("in live, an override can't switch a testOnly flag on (warning, flag stays off)", function()
		local cs = fakes.configService({ values = { flag_debugPanel = true } })
		local h, ctx = boot({ services = { ConfigService = cs }, flagOverride = ON })
		expect(ctx.flags.isOn("debugPanel")).toBe(false)
		expect(warned(h, "'debugPanel' is testOnly")).toBe(1)
		h:tick(30)
		cs.publish()
		expect(warned(h, "'debugPanel' is testOnly")).toBe(1) -- the same refused value: no new warning
	end)

	it("in test, the same override is allowed", function()
		local cs = fakes.configService({ values = { flag_debugPanel = false } })
		local _, ctx = boot({ services = { ConfigService = cs }, flagOverride = ON, env = "test" })
		expect(ctx.flags.isOn("debugPanel")).toBe(false)
		expect(ctx.flags.source("debugPanel")).toBe("override")
	end)

	it("a Studio console override stays until that flag's config changes", function()
		local cs = fakes.configService({ values = { flag_newShop = false } })
		local h, ctx = boot({ services = { ConfigService = cs }, flagOverride = ON, isStudio = true })
		h:console("flags set newShop true")
		h:tick(30)
		cs.set("flag_weekly", false)
		cs.publish()
		expect(ctx.flags.isOn("newShop")).toBe(true) -- its key didn't change
		expect(ctx.flags.isOn("weekly")).toBe(false)
		h:tick(30)
		cs.set("flag_newShop", true)
		cs.publish()
		h:tick(30)
		cs.set("flag_newShop", false)
		cs.publish()
		expect(ctx.flags.isOn("newShop")).toBe(false)
	end)
end)

describe("FlagOverride (unit)", function()
	local function make(envName, values)
		local timers = {}
		local clock = 0
		local events = {}
		local cs = fakes.configService({ values = values })
		local state = Flags.new({ flags = DEFS, envName = envName, side = "server" })
		local fo = FlagOverride.new({
			config = ON,
			flags = state,
			services = {
				internal = function(name)
					assert(name == "ConfigService", "only the config service is asked for")
					return cs
				end,
			},
			delay = function(s, fn)
				table.insert(timers, { at = clock + s, fn = fn })
			end,
			now = function()
				return clock
			end,
			analytics = function(event, fields)
				table.insert(events, { event = event, fields = fields })
			end,
		})
		local function tick(s)
			clock += s
			local due = {}
			for i = #timers, 1, -1 do
				if timers[i].at <= clock then
					table.insert(due, table.remove(timers, i))
				end
			end
			for _, t in due do
				t.fn()
			end
		end
		return fo, state, cs, events, tick
	end

	it("reports FlagOverrideRefused { flag } once per refused value in live", function()
		local fo, state, cs, events, tick = make("live", { flag_debugPanel = true })
		fo.start()
		expect(state.api.isOn("debugPanel")).toBe(false)
		expect(#events).toBe(1)
		expect(events[1].event).toBe("FlagOverrideRefused")
		expect(events[1].fields.flag).toBe("debugPanel")
		tick(30)
		cs.publish()
		expect(#events).toBe(1)
		-- the value goes away and comes back: a new refusal, reported again
		tick(30)
		cs.set("flag_debugPanel", nil)
		cs.publish()
		tick(30)
		cs.set("flag_debugPanel", true)
		cs.publish()
		expect(#events).toBe(2)
		expect(fo.reads()).toBe(4) -- the first read + three refreshes
	end)

	it("start() is idempotent and stop() ends the refreshes", function()
		local fo, _, cs = make("live", {})
		fo.start()
		fo.start()
		expect(count(cs, "GetConfigAsync")).toBe(1)
		fo.stop()
		cs.publish()
		expect(count(cs, "Refresh")).toBe(0)
	end)

	it("settings: defaults and the enabled switch", function()
		local s = FlagOverride.settings(nil)
		expect(s.enabled).toBe(false)
		expect(s.keyPrefix).toBe("flag_")
		expect(s.refreshSeconds).toBe(30)
		expect(FlagOverride.settings({ enabled = true, keyPrefix = "" }).keyPrefix).toBe("flag_")
	end)
end)
