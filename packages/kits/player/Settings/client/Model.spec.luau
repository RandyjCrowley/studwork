local Model = require(script.Parent.Model)
local Schema = require(script.Parent.Parent.shared.Schema)
local function setup()
	local defs = Schema.resolve()
	local jobs, sent, changes = {}, {}, {}
	local platform = false
	local model = Model.new(defs, {
		default = function(def)
			return if def.id == "reduceMotion" then platform else def.default
		end,
		validate = Schema.validate,
		enabled = function()
			return true
		end,
		maxRequest = Schema.MAX_REQUEST,
		debounce = 0.5,
		delay = function(_, fn)
			table.insert(jobs, fn)
		end,
		send = function(...)
			table.insert(sent, { ... })
		end,
		changed = function(...)
			table.insert(changes, { ... })
		end,
	})
	local function flush()
		local current = jobs
		jobs = {}
		for _, fn in current do
			fn()
		end
	end
	return model, flush, sent, changes, function(value)
		platform = value
	end
end
describe("preference draft reconciliation", function()
	it("debounces superseded edits and retains a newer draft across an old acknowledgement", function()
		local m, flush, sent = setup()
		m.snapshot({ musicVolume = 1 }, 0)
		m.edit("musicVolume", 0.5)
		m.edit("musicVolume", 0.4)
		flush()
		expect(#sent).toBe(1)
		expect(sent[1][2]).toBe(0.4)
		m.edit("musicVolume", 0.3)
		m.ack("musicVolume", 0.4, 1, true, 1)
		expect(m.get("musicVolume")).toBe(0.3)
		m.snapshot({ musicVolume = 0.4 }, 1)
		expect(m.get("musicVolume")).toBe(0.3)
		flush()
		m.ack("musicVolume", 0.3, 2, true, 2)
		expect(m.get("musicVolume")).toBe(0.3)
	end)
	it("ignores older snapshots and chooses a newer server set over an older reply", function()
		local m, flush = setup()
		m.snapshot({ musicVolume = 1 }, 0)
		m.edit("musicVolume", 0.5)
		flush()
		m.snapshot({ musicVolume = 0.2 }, 2)
		expect(m.get("musicVolume")).toBe(0.5)
		m.ack("musicVolume", 0.5, 1, true, 1)
		expect(m.get("musicVolume")).toBe(0.2)
		m.snapshot({ musicVolume = 1 }, 0)
		expect(m.get("musicVolume")).toBe(0.2)
	end)
	it("rolls back a rejected edit and rejects invalid writes before sending", function()
		local m, flush, sent = setup()
		m.snapshot({ musicVolume = 0.8 }, 0)
		expect(m.edit("musicVolume", 0 / 0)).toBe(false)
		expect(m.edit("musicVolume", 0.21)).toBe(false)
		expect(m.edit("unknown", true)).toBe(false)
		m.edit("musicVolume", 0.2)
		flush()
		m.ack("musicVolume", 0.8, 1, false, 0)
		expect(m.get("musicVolume")).toBe(0.8)
		expect(m.status).toBe("rejected")
		expect(#sent).toBe(1)
	end)
	it("keeps local values off the wire and resets to current platform defaults", function()
		local m, flush, sent, _, platform = setup()
		m.edit("reduceMotion", true)
		flush()
		expect(#sent).toBe(0)
		platform(false)
		m.reset("reduceMotion")
		expect(m.get("reduceMotion")).toBe(false)
		platform(true)
		m.refreshDefault("reduceMotion")
		expect(m.get("reduceMotion")).toBe(true)
	end)
	it("does not wrap request identifiers and cancels pending work on destroy", function()
		local m, flush, sent = setup()
		m.nextRequest = Schema.MAX_REQUEST
		expect(m.edit("musicVolume", 0.5)).toBe(false)
		m.nextRequest = 0
		m.edit("musicVolume", 0.5)
		m.destroy()
		flush()
		expect(#sent).toBe(0)
	end)
end)
