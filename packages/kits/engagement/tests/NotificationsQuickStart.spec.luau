--!nocheck
--[[
	The code in docs/framework/kits/notifications.md ("Quick start" and "Tests"), run as a spec so the
	snippets can't rot. If you change one, change the other. Mocked: nothing calls Roblox.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Notifications =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Notifications"):WaitForChild("module"))

local SECRET = "OpenCloudNotifications"

-- The doc's harness options for a game that uses Notifications (a spec boots as a Studio server)
local function boot(notificationsConfig)
	local openCloudFake = StudWork.test.fakes.openCloud()
	local h = StudWork.test.harness({
		modules = { Notifications },
		config = { Notifications = notificationsConfig },
		isStudio = true,
		openCloud = openCloudFake,
		secrets = { [SECRET] = true },
		serverConfig = {
			openCloud = {
				secrets = {
					[SECRET] = {
						modules = { "Notifications" },
						methods = { "POST" },
						paths = { "users/*/notifications" },
					},
				},
			},
		},
		storeBudgets = { memoryUnits = { base = 100000, perPlayer = 0 } },
	})
	return h, h:use(Notifications), openCloudFake
end

describe("notifications.md quick start", function()
	it("prompts a new player once the opt-in rules allow it", function()
		-- minSessions = 0: a brand-new player has finished no session yet (the default 1 needs one)
		local h, api = boot({
			templates = { comeBack = { messageId = "123" } },
			optIn = { minSessions = 0 },
		})
		local p = h:addPlayer({ userId = 1 })
		expect(api.suggestOptIn(p, "egg")).toBe(false) -- before minSessionSeconds (180)
		h:tick(181)
		expect(api.suggestOptIn(p, "egg")).toBe(true)
		local asked = h:sent("Notifications", "PromptOptIn")
		expect(#asked).toBe(1)
		h:action(p, Notifications, "optInShown", asked[1].args[1], true)
	end)

	it("with the default minSessions = 1 a new player is not prompted", function()
		local h, api = boot({ templates = { comeBack = { messageId = "123" } } })
		local p = h:addPlayer({ userId = 2 })
		h:tick(181)
		expect(api.suggestOptIn(p, "egg")).toBe(false)
	end)

	it("sends a scheduled notification when it is due", function()
		local h, api, openCloudFake = boot({
			templates = { comeBack = { messageId = "123" } },
			sendInStudio = true, -- else a Studio server only logs "would send"
			quiet = { startHour = 0, endHour = 0 }, -- no quiet hours, so any due time is open
			schedule = { shards = 1 }, -- one shard: one poll reads it
		})
		expect(api.schedule(7, "comeBack", h.clock + 6 * 3600)).toBe(true)
		h.clock += 6 * 3600 -- jump to the due time
		h:tick(30 + 1) -- at least one poll: pollSeconds + 1
		expect(#openCloudFake.requests).toBe(1)
	end)

	it("sends nothing in Studio without sendInStudio", function()
		local h, api, openCloudFake = boot({
			templates = { comeBack = { messageId = "123" } },
			quiet = { startHour = 0, endHour = 0 },
			schedule = { shards = 1 },
		})
		api.schedule(7, "comeBack", h.clock + 3600)
		h.clock += 3600
		h:tick(31)
		expect(#openCloudFake.requests).toBe(0)
	end)
end)
