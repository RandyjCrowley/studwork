--!nocheck
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Probe = StudWork.defineModule({ name = "ConfigProbe", version = "1.0.0", framework = "^1.7.0" })
local function boot(fake)
	local captured
	local h = StudWork.test.harness({
		modules = { Probe },
		services = { ConfigService = fake },
		servers = { ConfigProbe = {
			init = function(ctx)
				captured = ctx
			end,
		} },
	})
	return h, captured
end
describe("public configuration snapshots", function()
	it("exposes server snapshots while preserving the service refusal", function()
		local fake = StudWork.test.fakes.configService({ values = { offers = { enabled = true } } })
		local _, ctx = boot(fake)
		expect(#fake.calls).toBe(0)
		local snapshot = ctx.configValues.snapshot()
		expect(snapshot:GetValue("offers").enabled).toBe(true)
		expect(pcall(ctx.services.get, "ConfigService")).toBe(false)
		fake.set("offers", { enabled = false })
		fake.publish()
		expect(snapshot.Outdated).toBe(true)
		expect(snapshot:GetValue("offers").enabled).toBe(true)
		snapshot:Refresh()
		expect(snapshot:GetValue("offers").enabled).toBe(false)
	end)
	it("propagates errors so a caller can keep its last good cache", function()
		local fake = StudWork.test.fakes.configService({ failNext = 1 })
		local _, ctx = boot(fake)
		expect(pcall(ctx.configValues.snapshot)).toBe(false)
		expect(pcall(ctx.configValues.snapshot)).toBe(true)
	end)
end)
