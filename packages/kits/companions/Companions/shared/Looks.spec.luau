--!strict
local Looks = require(game:GetService("ReplicatedStorage").Modules.Companions.shared.Looks)
describe("Companion appearances", function()
	it("applies variant then mutation, protects errors and disconnects safely", function()
		local registry = Looks.new()
		local calls = {}
		local connection = registry.registerLook("shell", function()
			table.insert(calls, "shell")
			error("partial")
		end)
		registry.registerLook("gold", function()
			table.insert(calls, "gold")
		end)
		local model = {} :: any
		registry.applyLook(model, { companions = { look = "shell" } }, "gold")
		expect(table.concat(calls, ",")).toBe("shell,gold")
		expect((pcall(registry.registerLook, "gold", function() end))).toBe(false)
		local version = registry.version()
		connection:Disconnect()
		expect(registry.version()).toBe(version + 1)
		registry.registerLook("shell", function() end)
		connection:Disconnect()
		expect(registry.version()).toBe(version + 2)
	end)
end)

describe("Synchronous appearances", function()
	it("applies a shared variant/mutation key once and cancels yielded work", function()
		local registry = Looks.new()
		local calls = 0
		registry.registerLook("same", function()
			calls += 1
		end)
		registry.applyLook({} :: any, { companions = { look = "same" } }, "same")
		expect(calls).toBe(1)
		local thread: thread? = nil
		local changed = false
		registry.registerLook("yielding", function()
			thread = coroutine.running()
			coroutine.yield()
			changed = true
		end)
		registry.applyLook({} :: any, {}, "yielding")
		expect(coroutine.status(thread :: thread)).toBe("dead")
		expect((coroutine.resume(thread :: thread))).toBe(false)
		expect(changed).toBe(false)
	end)
end)
