--!nocheck
--!nolint DeprecatedApi
--[[
	Reports client part: the "Report" screen's pure view state (client/State.luau), the part's
	shape (open, recent, the one Submit action), and the views' rules (no English, no tweens,
	theme tokens, the block prompt in pcall).
]]
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Part = require(Modules:WaitForChild("Reports"):WaitForChild("client"))
local Ref = require(Modules:WaitForChild("Reports"):WaitForChild("module"))
local State = Part.api.read

local CONFIG = {
	categories = { "cheating", "scam" },
	note = { enabled = true, maxLength = 5 },
	blockPrompt = true,
}

describe("Reports client part", function()
	it("exposes open, recent and the pure state; its only action is submit", function()
		expect(type(Part.api.open)).toBe("function")
		expect(type(Part.api.recent)).toBe("function")
		expect(type(Part.start)).toBe("function")
		expect(Part.actions).toEqual({ submit = true })
		expect(Part.SCREEN).toBe("Report")
		expect(Ref.client).toBe("Reports")
	end)

	it("registers the screen unless the game did; the views have no English and no animation", function()
		local init = fs.readFile("packages/kits/moderation/Reports/client/init.luau")
		expect(string.find(init, "UI.screens:get(SCREEN) == nil", 1, true) ~= nil).toBe(true)
		expect(string.find(init, "UI.registerScreen(SCREEN", 1, true) ~= nil).toBe(true)
		local views = fs.readFile("packages/kits/moderation/Reports/client/Views.luau")
		expect(string.find(views, 'UI.useText("Reports.title")', 1, true) ~= nil).toBe(true)
		expect(string.find(views, 'Text = "', 1, true)).toBe(nil)
		expect(string.find(views, 'text = "', 1, true)).toBe(nil)
		expect(string.find(views, "TweenService", 1, true)).toBe(nil)
		expect(string.find(views, "UI.Button", 1, true)).toBe(nil) -- its press tween
		expect(string.find(views, "Theme.touchTarget", 1, true) ~= nil).toBe(true)
		expect(
			string.find(
				views,
				'pcall(function()\n\t\t\t\t\t\t\t\tStarterGui:SetCore("PromptBlockPlayer", player)',
				1,
				true
			) ~= nil
		).toBe(true)
		-- every Reports.* key the views name has an English default
		local strings = Ref.strings(Ref.config.defaults)
		for key in string.gmatch(views, '"(Reports%.[%w_.]+)"') do
			expect(strings[key] ~= nil).toBe(true)
		end
	end)
end)

describe("Report screen state", function()
	local here = { { userId = 3, name = "carol" }, { userId = 1, name = "Me" }, { userId = 2, name = "Bob" } }
	local gone =
		{ { userId = 2, name = "Bob" }, { userId = 9, name = "Zed" }, { userId = 8, name = "amy" }, "junk" }

	it("candidates: this server first, then recently left; never self, nobody twice", function()
		local c = State.candidates(here, gone, 1)
		expect(c).toEqual({
			{ userId = 2, name = "Bob", section = "inServer" },
			{ userId = 3, name = "carol", section = "inServer" },
			{ userId = 8, name = "amy", section = "recent" },
			{ userId = 9, name = "Zed", section = "recent" },
		})
		expect(State.candidates(nil, nil, 1)).toEqual({})
	end)

	it("open with a reportable target skips the picker; an unknown one starts at the picker", function()
		local c = State.candidates(here, gone, 1)
		local s = State.initial(9, c)
		expect(s.step).toBe("category")
		expect(s.target).toBe(9)
		expect(s.targetName).toBe("Zed")
		expect(State.initial(1, c).step).toBe("pick") -- self
		expect(State.initial(nil, c).step).toBe("pick")
	end)

	it("pick, choose, note, back, sent", function()
		local c = State.candidates(here, gone, 1)
		local cats = State.categories(CONFIG)
		expect(cats).toEqual({
			{ id = "cheating", key = "Reports.category.cheating" },
			{ id = "scam", key = "Reports.category.scam" },
		})
		local s = State.initial(nil, c)
		expect(State.pick(s, 42, c)).toBe(s) -- not a candidate
		s = State.pick(s, 2, c)
		expect(s.step).toBe("category")
		expect(State.args(s, CONFIG)).toBe(nil) -- no category yet
		expect(State.choose(s, "nope", cats)).toBe(s)
		s = State.choose(s, "scam", cats)
		local target, category, note = State.args(s, CONFIG)
		expect(target).toBe(2)
		expect(category).toBe("scam")
		expect(note).toBe(nil)
		s = State.setNote(s, "héllo world", 5)
		expect(s.note).toBe("héllo")
		target, category, note = State.args(s, CONFIG)
		expect(note).toBe("héllo")
		-- the note box hidden: no note sent
		local off = { categories = CONFIG.categories, note = { enabled = false, maxLength = 5 } }
		expect(select(3, State.args(s, off))).toBe(nil)
		expect(State.back(s).step).toBe("pick")
		local done = State.sent(s)
		expect(done.step).toBe("thanks")
		expect(State.args(done, CONFIG)).toBe(nil)
	end)

	it(
		"offers the block prompt after sending, for a player in this server, when blockPrompt is on",
		function()
			local c = State.candidates(here, gone, 1)
			local s = State.sent(State.initial(2, c))
			expect(State.offerBlock(s, CONFIG, { [2] = true })).toBe(true)
			expect(State.offerBlock(s, CONFIG, {})).toBe(false) -- left the server
			expect(State.offerBlock(s, { blockPrompt = false }, { [2] = true })).toBe(false)
			expect(State.offerBlock(State.initial(2, c), CONFIG, { [2] = true })).toBe(false) -- not sent yet
		end
	)
end)
