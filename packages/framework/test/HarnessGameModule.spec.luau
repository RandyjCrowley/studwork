--!nocheck
-- (v1.7.0) What a game module's spec needs from StudWork.test: Workspace and Players exist (empty
-- world, the harness's players), a module's client request is h:action, and what a module sends to
-- a client is h:sent (a fake net event per event in the module's net.blink). Nothing calls Roblox.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Notifications =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Notifications"):WaitForChild("module"))

local SECRET = "OpenCloudNotifications"

local function boot(): any
	local oc = StudWork.test.fakes.openCloud()
	return StudWork.test.harness({
		modules = { Notifications },
		config = {
			Notifications = {
				templates = { comeBack = { messageId = "123" } },
				optIn = { minSessionSeconds = 0, minSessions = 0 },
			},
		},
		openCloud = oc,
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
end

describe("a spec for a game module", function()
	it("sees an empty Workspace and the harness's Players", function()
		local workspaceService = game:GetService("Workspace")
		expect(workspaceService:FindFirstChild("AnyWorld")).toBeNil()
		expect(#workspaceService:GetDescendants()).toBe(0)
		expect(workspace).toBe(workspaceService)
		local Players = game:GetService("Players")
		local h = boot()
		expect(#Players:GetPlayers()).toBe(0)
		local p = h:addPlayer({ userId = 7 })
		expect(Players:GetPlayers()[1]).toBe(p)
		expect(Players:GetPlayerByUserId(7)).toBe(p)
		h:removePlayer(p)
		expect(#Players:GetPlayers()).toBe(0)
	end)

	it("reads what a module sent to a client with h:sent", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		expect(#h:sent("Notifications")).toBe(0)
		expect(h:use(Notifications).suggestOptIn(p, "egg")).toBe(true)
		local asked = h:sent("Notifications", "PromptOptIn")
		expect(#asked).toBe(1)
		expect(asked[1].player).toBe(p)
		expect(#h:sent("Notifications", "SetUtcOffset")).toBe(0)
		expect(#h:sent("Other")).toBe(0)
	end)

	it("drives the client's answer as a player with h:action", function()
		local h = boot()
		local p = h:addPlayer({ userId = 1 })
		h:use(Notifications).suggestOptIn(p, "egg")
		local id = h:sent("Notifications", "PromptOptIn")[1].args[1]
		local ok = h:action(p, Notifications, "optInShown", id, true)
		expect(ok).toBe(true)
	end)
end)
