--!nocheck
--[[
	An unknown console command suggests the near matches (v1.7.0): a module's commands are
	prefixed with its lower-case module name, so `dogfood points` finds `dogfoodgame points`.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

local function boot()
	local h, err = StudWork.test.boot({
		modules = { StudWork.defineModule({ name = "DogfoodGame", version = "1.0.0", framework = "^1.7.0" }) },
		servers = {
			DogfoodGame = {
				init = function(ctx)
					ctx.console.register("points", function()
						return "ok"
					end)
					ctx.console.register("reset", function()
						return "ok"
					end)
				end,
			},
		},
	})
	assert(h, err)
	return h
end

describe("console: unknown command", function()
	it("suggests the module prefix for a shortened one", function()
		local h = boot()
		local reply = h:console("dogfood points")
		expect(string.find(reply, "did you mean 'dogfoodgame points'", 1, true) ~= nil).toBe(true)
	end)

	it("only suggests commands whose second word fits", function()
		local h = boot()
		local reply = h:console("dogfood reset")
		expect(string.find(reply, "dogfoodgame reset", 1, true) ~= nil).toBe(true)
		expect(string.find(reply, "dogfoodgame points", 1, true) == nil).toBe(true)
	end)

	it("keeps the plain reply when nothing is near", function()
		local h = boot()
		local reply = h:console("zzz nothing")
		expect(string.find(reply, "did you mean", 1, true) == nil).toBe(true)
		expect(string.find(reply, "try 'help'", 1, true) ~= nil).toBe(true)
	end)
end)
