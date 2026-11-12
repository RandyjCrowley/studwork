--!nocheck
--!nolint DeprecatedApi
--[[
	Leaderboards client part: it has no action (nothing a client can call to submit a value), reads
	rows and its own line from the replicated state, and registers the "Leaderboards" screen.
]]
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Ref = require(Modules:WaitForChild("Leaderboards"):WaitForChild("module"))
local Part = require(Modules:WaitForChild("Leaderboards"):WaitForChild("client"))

describe("Leaderboards client part", function()
	it("declares no actions, so a client can't submit or raise a value", function()
		expect(Part.actions).toBe(nil)
		for name in Part.api do
			expect(string.find(string.lower(name), "submit", 1, true)).toBe(nil)
			expect(string.find(string.lower(name), "score", 1, true)).toBe(nil)
		end
		expect(Ref.name).toBe("Leaderboards")
	end)

	it("exposes board, mine, attach, open and the pure readers", function()
		for _, name in { "board", "mine", "attach", "open" } do
			expect(type(Part.api[name])).toBe("function")
		end
		expect(type(Part.api.read.rows)).toBe("function")
		expect(type(Part.start)).toBe("function")
	end)

	it("registers the screen unless the game did, and its views have no English", function()
		local init = fs.readFile("packages/kits/engagement/Leaderboards/client/init.luau")
		expect(string.find(init, "UI.screens:get(SCREEN) == nil", 1, true) ~= nil).toBe(true)
		expect(string.find(init, "UI.registerScreen(SCREEN", 1, true) ~= nil).toBe(true)
		local views = fs.readFile("packages/kits/engagement/Leaderboards/client/Views.luau")
		expect(string.find(views, 'UI.useText("Leaderboards.title")', 1, true) ~= nil).toBe(true)
		expect(string.find(views, "UI.text(", 1, true) ~= nil).toBe(true)
		expect(string.find(views, 'text = "', 1, true)).toBe(nil)
		expect(string.find(views, 'Text = "', 1, true)).toBe(nil)
	end)
end)
