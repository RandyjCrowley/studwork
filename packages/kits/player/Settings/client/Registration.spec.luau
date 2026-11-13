local Registration = require(script.Parent.Registration)
local Model = require(script.Parent.Model)
local Schema = require(script.Parent.Parent.shared.Schema)
local function setup(saved)
	local defs, hooks, deferred, calls = {}, {}, {}, {}
	local def = {
		id = "customToggle",
		type = "toggle",
		default = true,
		category = "gameplay",
		labelKey = "game.customToggle",
		scope = "saved",
	}
	local hook = function(value)
		table.insert(calls, value)
	end
	local model = Model.new(defs, {
		default = function(d)
			return d.default
		end,
		validate = Schema.validate,
		enabled = function()
			return true
		end,
		maxRequest = Schema.MAX_REQUEST,
		debounce = 0.5,
		delay = function() end,
		send = function() end,
		changed = function(id, value)
			if hooks[id] then
				hooks[id](value)
			end
		end,
	})
	local opts = {
		defs = defs,
		hooks = hooks,
		deferred = deferred,
		model = model,
		validate = Schema.validateDefinition,
		same = function(a, b)
			return a.id == b.id and a.default == b.default and a.scope == b.scope and a.type == b.type
		end,
	}
	return opts,
		def,
		hook,
		calls,
		{ schema = { customToggle = def }, values = { customToggle = saved }, revision = 0 }
end
describe("saved preference hook registration", function()
	it("initializes a deferred hook once even when the saved value equals its default", function()
		local opts, def, hook, calls, extra = setup(true)
		local waiting = table.clone(def)
		waiting.apply = hook
		opts.deferred[def.id] = waiting
		Registration.receive(opts, extra)
		expect(#calls).toBe(1)
		expect(calls[1]).toBe(true)
		Registration.receive(opts, extra)
		expect(#calls).toBe(1)
	end)
	it("initializes a deferred hook with the reconciled value instead of a transient default", function()
		local opts, def, hook, calls, extra = setup(false)
		local waiting = table.clone(def)
		waiting.apply = hook
		opts.deferred[def.id] = waiting
		Registration.receive(opts, extra)
		expect(#calls).toBe(1)
		expect(calls[1]).toBe(false)
	end)
	it("initializes registration after owner metadata with the same resolved value", function()
		local opts, def, hook, calls, extra = setup(true)
		Registration.receive(opts, extra)
		Registration.attach(opts.hooks, def.id, hook, opts.model)
		expect(#calls).toBe(1)
		expect(calls[1]).toBe(true)
	end)
	it("does not attach a deferred definition that differs from the server schema", function()
		local opts, def, hook, calls, extra = setup(true)
		local waiting = table.clone(def)
		waiting.default = false
		waiting.apply = hook
		opts.deferred[def.id] = waiting
		Registration.receive(opts, extra)
		expect(#calls).toBe(0)
		expect(opts.hooks[def.id]).toBeNil()
	end)
end)
