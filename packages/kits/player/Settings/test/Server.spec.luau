--!nocheck
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Settings =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Settings"):WaitForChild("module"))
local Part = require(script.Parent.Parent.server)
local Harness = require("packages/framework/test/harness.luau")

local function custom()
	return {
		id = "quality",
		type = "choice",
		choices = { "simple", "full" },
		default = "full",
		category = "graphics",
		labelKey = "game.quality",
		scope = "saved",
	}
end

local function boot(config, opts)
	opts = opts or {}
	local now, timers, events = 0, {}, {}
	local part = Part.new({
		delay = function(seconds, fn)
			table.insert(timers, { at = now + seconds, fn = fn })
		end,
	})
	part.net =
		{ Set = Harness.fakeEvent("Settings.Set", events), Ack = Harness.fakeEvent("Settings.Ack", events) }
	local store = opts.store or StudWork.test.memoryStore()
	local stats = { saves = 0 }
	local save = store.save
	store.save = function(...)
		stats.saves += 1
		return save(...)
	end
	local modules, servers = { Settings }, { Settings = part }
	for _, ref in opts.modules or {} do
		table.insert(modules, ref)
	end
	for name, server in opts.servers or {} do
		servers[name] = server
	end
	local h = StudWork.test.harness({
		modules = modules,
		servers = servers,
		store = store,
		config = { Settings = config or {} },
		flags = opts.flags,
	})
	local function advance(seconds)
		now += seconds
		h:tick(seconds)
		local due, keep = {}, {}
		for _, timer in timers do
			table.insert(if timer.at <= now then due else keep, timer)
		end
		timers = keep
		for _, timer in due do
			timer.fn()
		end
	end
	local function state(p)
		return h:state(p).modules.Settings
	end
	return h, h:use(Settings), advance, events, stats, state, part
end

local function action(h, p, id, kind, value, request)
	local b, n, s = false, 0, ""
	if kind == "toggle" then
		b = value
	elseif kind == "slider" then
		n = value
	else
		s = value
	end
	local routed, accepted = h:action(p, Settings, "set", id, kind, b, n, s, request)
	return routed, accepted
end

describe("authoritative preferences", function()
	it("publishes saved defaults and schema exclusively to each owner", function()
		local h, api, _, events, _, state = boot()
		local a, b = h:addPlayer({ userId = 1 }), h:addPlayer({ userId = 2 })
		expect(api.get(a, "musicVolume")).toBe(1)
		expect(api.get(a, "reduceMotion")).toBe(nil)
		expect(api.set(a, "musicVolume", 0.25)).toBe(true)
		expect(state(a).extra.values.musicVolume).toBe(0.25)
		expect(state(b).extra.values.musicVolume).toBe(1)
		expect(state(a).data).toBe(nil)
		expect(state(a).extra.schema.musicVolume.scope).toBe("saved")
		expect(state(a).extra.schema.reduceMotion).toBe(nil)
		for _, event in events do
			expect(event.all).toBe(nil)
		end
	end)

	it("validates types, finite ranges, steps, choices and saved scope on every API write", function()
		local h, api = boot({ schema = { custom() }, rate = { rate = 100, burst = 100 } })
		local p = h:addPlayer({ userId = 1 })
		for _, value in { 2, -0.05, 0.56, 0 / 0, math.huge, "0.5", false, {} } do
			expect(api.set(p, "musicVolume", value)).toBe(false)
		end
		expect(api.set(p, "musicVolume", 0.55)).toBe(true)
		expect(api.set(p, "quality", "simple")).toBe(true)
		expect(api.set(p, "quality", "other")).toBe(false)
		expect(api.set(p, "showTips", 0)).toBe(false)
		expect(api.set(p, "showTips", false)).toBe(true)
		expect(api.get(p, "showTips")).toBe(false)
		expect(api.set(p, "reduceMotion", true)).toBe(false)
		expect(api.set(p, "unknown", true)).toBe(false)
	end)

	it("checks exact wire kinds and refuses malformed or replayed request ids", function()
		local h, api, _, events = boot()
		local p = h:addPlayer({ userId = 1 })
		local routed, accepted = action(h, p, "musicVolume", "slider", 0.5, 1)
		expect(routed).toBe(true)
		expect(accepted).toBe(true)
		expect(select(2, action(h, p, "musicVolume", "slider", 0.25, 1))).toBe(false)
		expect(select(2, action(h, p, "musicVolume", "choice", "0.25", 2))).toBe(false)
		expect(select(2, action(h, p, "musicVolume", "slider", 0.25, 0 / 0))).toBe(false)
		expect(select(2, action(h, p, "musicVolume", "slider", 0.25, 0))).toBe(false)
		expect(select(2, action(h, p, "musicVolume", "slider", 0.25, 4294967296))).toBe(false)
		expect(api.get(p, "musicVolume")).toBe(0.5)
		expect(#events).toBe(3)
		expect(events[2].args[3]).toBe(false)
		expect(events[2].args[4]).toBe(0.5)
		expect(events[2].args[7]).toBe(false)
		expect(events[2].args[8]).toBe(1)
	end)

	it("never echoes unknown setting ids or invalid wire values", function()
		local h, _, _, events = boot()
		local p = h:addPlayer({ userId = 1 })
		action(h, p, "untrusted_text", "choice", "untrusted_value", 1)
		expect(#events).toBe(0)
		action(h, p, "musicVolume", "choice", "untrusted_value", 1)
		expect(#events).toBe(1)
		expect(events[1].args[1]).toBe("musicVolume")
		expect(events[1].args[5]).toBe("")
		expect(events[1].args[4]).toBe(1)
	end)

	it(
		"advances owner revision for server changes and acknowledges the current authoritative value",
		function()
			local h, api, _, events, _, state = boot()
			local p = h:addPlayer({ userId = 1 })
			expect(api.set(p, "musicVolume", 0.5)).toBe(true)
			expect(select(2, action(h, p, "musicVolume", "slider", 0.25, 3))).toBe(true)
			expect(api.set(p, "musicVolume", 0.75)).toBe(true)
			expect(select(2, action(h, p, "musicVolume", "slider", 0.1, 2))).toBe(false)
			expect(state(p).extra.revision).toBe(3)
			expect(events[#events].args[4]).toBe(0.75)
			expect(events[#events].args[8]).toBe(3)
		end
	)

	it("applies a configurable write budget to API calls as well as actions", function()
		local h, api, advance = boot({ rate = { rate = 1, burst = 1 } })
		local p = h:addPlayer({ userId = 1 })
		expect(api.set(p, "showTips", false)).toBe(true)
		local ok, reason = api.set(p, "showTips", true)
		expect(ok).toBe(false)
		expect(reason).toBe("rate_limited")
		advance(1)
		expect(select(2, action(h, p, "showTips", "toggle", true, 1))).toBe(true)
		expect(api.get(p, "showTips")).toBe(true)
	end)

	it("checks its kill switch for API and action writes", function()
		local h, api, _, events = boot(
			{ flag = "preferences" },
			{ flags = { preferences = { default = false } } }
		)
		local p = h:addPlayer({ userId = 1 })
		expect(api.set(p, "showTips", false)).toBe(false)
		expect(select(2, action(h, p, "showTips", "toggle", false, 1))).toBe(false)
		expect(events[1].args[7]).toBe(false)
		expect(api.get(p, "showTips")).toBe(true)
	end)

	it("registers a dependency schema before load, freezes registration and strips apply hooks", function()
		local accepted
		local definition = custom()
		definition.apply = function()
			error("must remain on client")
		end
		local Probe = StudWork.defineModule({
			name = "PreferenceOwner",
			version = "1.0.0",
			framework = "^1.7.0",
			dependsOn = { Settings },
		})
		local h, api, _, _, _, state = boot({}, {
			modules = { Probe },
			servers = {
				PreferenceOwner = {
					init = function(ctx)
						accepted = ctx.depsExt[Settings].register(definition)
					end,
				},
			},
		})
		expect(accepted).toBe(true)
		definition.choices[1] = "mutated"
		local p = h:addPlayer({ userId = 1 })
		expect(api.get(p, "quality")).toBe("full")
		expect(api.set(p, "quality", "simple")).toBe(true)
		expect(state(p).extra.schema.quality.apply).toBe(nil)
		expect(state(p).extra.schema.quality.choices[1]).toBe("simple")
		expect(api.register(custom())).toBe(false)
	end)

	it("refuses invalid defaults, duplicates and capacity overflow during server registration", function()
		local h, api = boot({ maxSettings = 9 })
		local bad = custom()
		bad.default = "invalid"
		expect(api.register(bad)).toBe(false)
		expect(api.register(custom())).toBe(false)
		expect(api.register({ id = "showTips" })).toBe(false)
		expect(#h:warnings()).toBe(0)
	end)

	it("prunes removed ids and invalid old values and restores defaults before replication", function()
		local store = StudWork.test.memoryStore()
		local first, _, step = boot({}, { store = store })
		local old = first:addPlayer({ userId = 1 })
		step(2)
		first:removePlayer(old)
		local root = store.load(1)
		root.settings.values =
			{ removed = "old", musicVolume = 2, effectsVolume = 0.4, reduceMotion = true, showTips = false }
		store.save(1, root)
		local h, api, advance, _, _, state = boot({}, { store = store })
		local p = h:addPlayer({ userId = 1 })
		expect(p.loaded).toBe(true)
		expect(api.get(p, "musicVolume")).toBe(1)
		expect(api.get(p, "effectsVolume")).toBe(0.4)
		expect(api.get(p, "showTips")).toBe(false)
		expect(state(p).extra.values.removed).toBe(nil)
		expect(state(p).extra.values.reduceMotion).toBe(nil)
		advance(2)
		expect(h:saved(p).settings.values.removed).toBe(nil)
		expect(h:saved(p).settings.values.musicVolume).toBe(1)
	end)

	it("debounces saves from the first dirty edit without starving continuous changes", function()
		local h, api, advance, _, stats = boot({ rate = { rate = 100, burst = 100 } })
		local p = h:addPlayer({ userId = 1 })
		advance(2)
		local before = stats.saves
		expect(api.set(p, "musicVolume", 0.25)).toBe(true)
		advance(1)
		expect(api.set(p, "effectsVolume", 0.5)).toBe(true)
		expect(stats.saves).toBe(before)
		advance(1)
		expect(stats.saves).toBe(before + 1)
		expect(h:saved(p).settings.values.effectsVolume).toBe(0.5)
		advance(10)
		expect(stats.saves).toBe(before + 1)
	end)

	it("retries a failed debounced save while retaining the authoritative transaction", function()
		local h, api, advance, _, stats = boot()
		local p = h:addPlayer({ userId = 1 })
		advance(2)
		local before = stats.saves
		expect(api.set(p, "showTips", false)).toBe(true)
		h.store.failNext(1)
		advance(2)
		expect(api.get(p, "showTips")).toBe(false)
		advance(2)
		expect(stats.saves).toBe(before + 2)
		expect(h:saved(p).settings.values.showTips).toBe(false)
	end)

	it("invalidates old timers on leave and keeps accepted changes in the final save", function()
		local h, api, advance, _, stats = boot()
		local p = h:addPlayer({ userId = 1 })
		advance(2)
		expect(api.set(p, "showTips", false)).toBe(true)
		h:removePlayer(p)
		local before = stats.saves
		advance(2)
		expect(stats.saves).toBe(before)
		expect(api.get(p, "showTips")).toBe(nil)
		expect(h:saved(p).settings.values.showTips).toBe(false)
	end)

	it("emits Changed only for accepted owner changes and persists dirty values on shutdown", function()
		local h, api = boot()
		local p = h:addPlayer({ userId = 1 })
		local calls = {}
		api.signals.Changed:Connect(function(owner, id, value)
			table.insert(calls, { owner.UserId, id, value })
		end)
		expect(api.set(p, "showTips", false)).toBe(true)
		expect(api.set(p, "showTips", "no")).toBe(false)
		expect(#calls).toBe(1)
		expect(calls[1]).toEqual({ 1, "showTips", false })
		h:shutdown()
		expect(h:saved(p).settings.values.showTips).toBe(false)
	end)
end)
