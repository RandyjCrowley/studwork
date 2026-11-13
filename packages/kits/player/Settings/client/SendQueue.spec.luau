local Model = require(script.Parent.Model)
local SendQueue = require(script.Parent.SendQueue)
local Schema = require(script.Parent.Parent.shared.Schema)
local function setup()
	local now, enabled, jobs, sent = 0, true, {}, {}
	local applied = {}
	local queue
	local function delay(seconds, fn)
		table.insert(jobs, { at = now + seconds, fn = fn })
	end
	local defs = Schema.resolve()
	local model = Model.new(defs, {
		default = function(def)
			return def.default
		end,
		validate = Schema.validate,
		enabled = function()
			return enabled
		end,
		maxRequest = Schema.MAX_REQUEST,
		debounce = 0.5,
		delay = delay,
		changed = function(id, value)
			applied[id] = value
		end,
		cancelled = function()
			if queue then
				queue.reset()
			end
		end,
		send = function(...)
			queue.send(...)
		end,
	})
	queue = SendQueue.new({
		model = model,
		now = function()
			return now
		end,
		delay = delay,
		enabled = function()
			return enabled
		end,
		interval = 1,
		timeout = 10,
		default = function(id)
			return defs[id].default
		end,
		fire = function(...)
			table.insert(sent, { ... })
		end,
	})
	local function advance(seconds)
		local finish = now + seconds
		while true do
			local chosen, index
			for i, job in jobs do
				if job.at <= finish and (chosen == nil or job.at < chosen.at) then
					chosen, index = job, i
				end
			end
			if chosen == nil then
				break
			end
			table.remove(jobs, index)
			now = chosen.at
			chosen.fn()
		end
		now = finish
	end
	model.snapshot({ showTips = true, musicVolume = 1, effectsVolume = 1 }, 0)
	return model, queue, advance, sent, function(value)
		enabled = value
	end, applied
end
describe("preference flag cancellation", function()
	it("rolls back a draft when disabled during debounce and does not revive it on re-enable", function()
		local model, queue, advance, sent, enable, applied = setup()
		model.edit("showTips", false)
		enable(false)
		queue.cancel()
		enable(true)
		advance(1)
		expect(#sent).toBe(0)
		expect(model.get("showTips")).toBe(true)
		expect(applied.showTips).toBe(true)
		expect(model.status).toBe("saved")
		model.snapshot({ showTips = true }, 1)
		expect(model.get("showTips")).toBe(true)
		model.edit("showTips", false)
		advance(0.5)
		expect(#sent).toBe(1)
	end)
	it("cancels when the disabled debounce guard runs even before its flag listener", function()
		local model, _, advance, sent, enable = setup()
		model.edit("showTips", false)
		enable(false)
		advance(0.5)
		enable(true)
		expect(model.get("showTips")).toBe(true)
		expect(model.status).toBe("saved")
		expect(#sent).toBe(0)
	end)
	it("cancels a paced send and an old timeout without affecting a later generation", function()
		local model, queue, advance, sent, enable = setup()
		model.edit("musicVolume", 0.5)
		model.edit("effectsVolume", 0.4)
		advance(0.5)
		expect(#sent).toBe(1)
		enable(false)
		queue.cancel()
		enable(true)
		model.edit("effectsVolume", 0.2)
		advance(0.5)
		expect(#sent).toBe(2)
		expect(sent[2][2]).toBe(0.2)
		model.ack("effectsVolume", 0.2, sent[2][3], true, 1)
		advance(10)
		expect(#sent).toBe(2)
		expect(model.get("effectsVolume")).toBe(0.2)
		expect(model.drafts.musicVolume).toBeNil()
		expect(model.drafts.effectsVolume).toBeNil()
	end)
	it("rolls back a paced request if its enabled guard observes a disabled flag", function()
		local model, _, advance, sent, enable = setup()
		model.edit("musicVolume", 0.5)
		model.edit("effectsVolume", 0.4)
		advance(0.5)
		enable(false)
		advance(1)
		enable(true)
		expect(#sent).toBe(1)
		expect(model.get("effectsVolume")).toBe(1)
		expect(model.status).toBe("saved")
		advance(10)
		expect(#sent).toBe(1)
	end)
end)
