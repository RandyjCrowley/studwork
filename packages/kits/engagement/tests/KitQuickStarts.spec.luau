--!nocheck
--[[
	The "Quick start" code of docs/framework/kits/{leaderboards,badges,textfilter,environments,
	localization}.md, run as a spec so the snippets can't rot. If you change one, change the other.
	(Notifications: NotificationsQuickStart.spec.) Mocked: nothing calls Roblox.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Leaderboards = require(Modules:WaitForChild("Leaderboards"):WaitForChild("module"))
local Badges = require(Modules:WaitForChild("Badges"):WaitForChild("module"))
local TextFilter = require(Modules:WaitForChild("TextFilter"):WaitForChild("module"))
local Notifications = require(Modules:WaitForChild("Notifications"):WaitForChild("module"))

local fakes = StudWork.test.fakes

describe("leaderboards.md quick start", function()
	it("submits a score and reads the top", function()
		local h = StudWork.test.harness({
			modules = { Leaderboards },
			config = { Leaderboards = { boards = { bestScore = { period = "allTime", mode = "max" } } } },
			services = { UserService = fakes.userService() },
		})
		local api = h:use(Leaderboards)
		local p = h:addPlayer({ userId = 1 })
		expect(api.submit(p, "bestScore", 120)).toBe(true)
		h:tick(121) -- past writeSeconds: the write happens, then the shared top refreshes
		api.refresh("bestScore")
		local top = api.top("bestScore")
		expect(top.rows[1].userId).toBe(1)
		expect(top.rows[1].value).toBe(120)
	end)
end)

describe("badges.md quick start", function()
	it("awards a manual badge once", function()
		local h = StudWork.test.harness({
			modules = { Badges },
			config = { Badges = { badges = { firstWin = { id = 0, trigger = { kind = "manual" } } } } },
			services = { BadgeService = fakes.badgeService() },
		})
		local api = h:use(Badges)
		local p = h:addPlayer({ userId = 1 })
		expect(api.award(p, "firstWin")).toBe(true)
		expect(api.award(p, "firstWin")).toBe(false) -- never twice
		expect(api.has(p, "firstWin")).toBe(true)
	end)
end)

describe("textfilter.md quick start", function()
	it("filters a submission for everyone", function()
		local h = StudWork.test.harness({
			modules = { TextFilter },
			services = { TextService = fakes.textService({ replace = { badword = true } }) },
			policy = { [1] = { IsContentSharingAllowed = true } },
		})
		local api = h:use(TextFilter)
		local p = h:addPlayer({ userId = 1 })
		local ok, result = api.filter(p, "my badword pet", "public")
		expect(ok).toBe(true)
		expect(string.find(result.public, "badword", 1, true)).toBe(nil)
	end)
end)

describe("environments.md quick start (flags)", function()
	local function boot(flags, env)
		local h = StudWork.test.harness({
			modules = { Notifications },
			config = {
				Notifications = { flag = "notifications", templates = { comeBack = { messageId = "123" } } },
			},
			flags = flags,
			env = env,
			storeBudgets = { memoryUnits = { base = 100000, perPlayer = 0 } },
		})
		return h, h:use(Notifications)
	end

	it("a kit's flag off is a kill switch", function()
		local h, api = boot({ notifications = { default = false } })
		local ok, reason = api.schedule(7, "comeBack", h.clock + 3600)
		expect(ok).toBe(false)
		expect(reason).toBe("disabled")
	end)

	it("the same flag on in the studio environment", function()
		local h, api = boot({ notifications = { default = false, studio = true } }, "studio")
		local ok, reason = api.schedule(7, "comeBack", h.clock + 3600)
		expect(reason).toBe(nil)
		expect(ok).toBe(true)
	end)
end)

describe("localization.md quick start", function()
	it("rewords a key and adds a game key", function()
		local captured = {}
		local Game = StudWork.defineModule({ name = "Probe", version = "1.0.0", framework = "^1.7.0" })
		local h = StudWork.test.harness({
			modules = { Game },
			servers = {
				Probe = {
					init = function(ctx)
						captured.ctx = ctx
					end,
				},
			},
			strings = { ["ui.close"] = "Done", ["game.welcome"] = "Welcome back, {name}!" },
		})
		local p = h:addPlayer({ userId = 1 })
		expect(captured.ctx.text.format(p, "game.welcome", { name = "Ada" })).toBe("Welcome back, Ada!")
		expect(captured.ctx.text.english("ui.close")).toBe("Done")
	end)
end)
