--!nocheck
--!nolint DeprecatedApi
--[[
	The Quests views (Board, Row, Tracker, Button, Toasts) are React and React isn't available under
	Lune (known issue U5), so these specs read their source for the rules the kit page sets, next to
	the pure State specs (Quests/client/State.spec.luau) that cover what the views render:

	  * every UI.text / UI.useText key a view uses is a key of the module's `strings`
	  * theme tokens only: no colour, font or text size literals; rows at least Theme.touchTarget
	  * every roll reward chip gets an always-visible Odds button, which opens the Odds screen with
	    `detail = extra.questOdds[table]`
	  * claim, reroll and pin call the actions with the quest's own id / kind / slot
	  * gamepad selection: only when the board was opened from a gamepad, only by Board.selectFirst,
	    first Claim else the first tab; B closes; the tracker is not Selectable
	  * nothing opens itself: the screen opens only through `open`, the widgets register at start
]]
local fs = (getmetatable(getfenv(1)) :: any).__index.require("@lune/fs")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Quests =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Quests"):WaitForChild("module"))

local DIR = "packages/kits/quests/Quests/client/"
local FILES = { "init", "Board", "Row", "Tracker", "Button", "Toasts" }

local sources = {}
for _, name in FILES do
	sources[name] = fs.readFile(DIR .. name .. ".luau")
end

local function stripComments(src)
	local out = {}
	for line in string.gmatch(src .. "\n", "(.-)\n") do
		if not string.match(line, "^%s*%-%-") then
			table.insert(out, line)
		end
	end
	return table.concat(out, "\n")
end

local code = {}
for name, src in sources do
	code[name] = stripComments(src)
end

describe("Quests views: strings", function()
	local strings = Quests.strings({ quests = { a = {} } })

	it("every literal UI.text / useText key exists in the module's strings", function()
		local n = 0
		local missing = {}
		for _, src in code do
			for _, pattern in { 'UI%.text%("([^"]+)"', 'UI%.useText%("([^"]+)"', '"(Quests%.[%w_%.]+)"' } do
				for key in string.gmatch(src, pattern) do
					n += 1
					-- "Quests.quest." is the prefix of a per-quest key and "Quests.tracker" a widget id, not keys
					if strings[key] == nil and key ~= "Quests.quest." and key ~= "Quests.tracker" then
						table.insert(missing, key)
					end
				end
			end
		end
		expect(missing).toEqual({})
		expect(n > 10).toBe(true)
	end)

	it("the views use the keys the page lists for the board", function()
		-- State builds the "Resets in" / reward lines the Board shows
		local state = stripComments(fs.readFile(DIR .. "State.luau"))
		local all = table.concat({ code.Board, code.Row, code.Tracker, code.Button, code.init, state }, "\n")
		for _, key in
			{
				"Quests.title",
				"Quests.button",
				"Quests.tab.daily",
				"Quests.tab.weekly",
				"Quests.tab.chain",
				"Quests.tab.event",
				"Quests.tab.waiting",
				"Quests.claim",
				"Quests.claimed",
				"Quests.reroll",
				"Quests.rerollsLeft",
				"Quests.resetsIn",
				"Quests.resetsInDays",
				"Quests.pin",
				"Quests.unpin",
				"Quests.locked",
				"Quests.capReached",
				"Quests.progress",
				"Quests.odds",
				"Quests.empty",
				"Quests.toast.completed",
				"Quests.toast.claimed",
			}
		do
			expect(string.find(all, key, 1, true) ~= nil).toBe(true)
		end
	end)
end)

describe("Quests views: theme and mobile", function()
	it("uses theme tokens only: no colour, font or text size literals", function()
		for _, src in code do
			expect(string.find(src, "Color3.fromRGB", 1, true)).toBe(nil)
			expect(string.find(src, "Color3.new", 1, true)).toBe(nil)
			expect(string.find(src, "Color3.fromHex", 1, true)).toBe(nil)
			expect(string.find(src, "Enum.Font", 1, true)).toBe(nil)
			expect(string.find(src, "Font.new", 1, true)).toBe(nil)
			expect(string.match(src, "TextSize%s*=%s*%d")).toBe(nil)
			expect(string.match(src, "#%x%x%x%x%x%x")).toBe(nil)
		end
	end)

	it("text sizes come from Theme.text and never below small; rows keep the touch target", function()
		expect(string.find(code.Row, "Theme.text.small", 1, true) ~= nil).toBe(true)
		expect(string.find(code.Row, "UISizeConstraint", 1, true) ~= nil).toBe(true)
		expect(string.find(code.Row, "MinSize = Vector2.new(0, Theme.touchTarget)", 1, true) ~= nil).toBe(
			true
		)
		expect(string.find(code.Tracker, "Theme.touchTarget", 1, true) ~= nil).toBe(true)
		expect(string.find(code.Row, "Theme.text.min", 1, true)).toBe(nil)
	end)

	it("every button is a UI.Button (Selectable); no raw TextButton but the tracker line", function()
		for _, name in { "Board", "Row", "Button" } do
			expect(string.find(code[name], '"TextButton"', 1, true)).toBe(nil)
			expect(string.find(code[name], "UI.Button", 1, true) ~= nil).toBe(true)
		end
	end)

	it("reduced motion: the progress fill jumps instead of tweening", function()
		expect(string.find(code.Row, "CoreReducedMotion", 1, true) ~= nil).toBe(true)
		expect(string.find(code.Row, "ReducedMotionEnabled", 1, true) ~= nil).toBe(true)
		expect(string.find(code.Row, "if reducedMotion() then", 1, true) ~= nil).toBe(true)
	end)

	it("the modal sizes itself: UI.Modal gets no `size` (a given size turns AutomaticSize off)", function()
		-- replaces the v1.8 check for `UDim2.fromScale(0.85, 0)`: that size made the panel's body
		-- height 0 and hung it off-screen in Studio. UI.Modal's own default is 0.6 of the screen
		-- wide (320-640 px) and auto height, scrolling inside the screen (ModalFit).
		expect(string.find(code.Board, "UI.Modal", 1, true) ~= nil).toBe(true)
		local i = string.find(code.Board, "e(UI.Modal, {", 1, true)
		expect(i ~= nil).toBe(true)
		local block = string.sub(code.Board, i, string.find(code.Board, "}, children)", i, true))
		expect(string.find(block, "size%s*=") == nil).toBe(true)
		expect(string.find(code.Board, "fromScale(0.85", 1, true) == nil).toBe(true)
	end)
end)

describe("Quests views: odds, actions", function()
	it("every roll reward chip has an unconditional Odds button for its own table", function()
		local row = code.Row
		local i = string.find(row, 'if reward.kind == "roll" then', 1, true)
		expect(i ~= nil).toBe(true)
		local block = string.sub(row, i, i + 260)
		expect(string.find(block, "UI.Button", 1, true) ~= nil).toBe(true)
		expect(string.find(block, 'UI.text("Quests.odds")', 1, true) ~= nil).toBe(true)
		expect(string.find(block, "props.onOdds(reward.table)", 1, true) ~= nil).toBe(true)
		-- not hidden by luck, flags or the odds being absent
		expect(string.find(block, "odds", 1, true) ~= nil).toBe(true)
		expect(string.find(block, "luck", 1, true)).toBe(nil)
		expect(string.find(block, "disabled", 1, true)).toBe(nil)
	end)

	it("the Odds screen opens with extra.questOdds[table] as the detail", function()
		expect(string.find(code.init, 'UI.open("Odds"', 1, true) ~= nil).toBe(true)
		expect(string.find(code.init, "odds[tableId]", 1, true) ~= nil).toBe(true)
		expect(string.find(code.init, "detail = detail", 1, true) ~= nil).toBe(true)
		expect(string.find(code.Board, "env.openOdds(tableId, odds)", 1, true) ~= nil).toBe(true)
		expect(string.find(code.Board, "State.odds(state)", 1, true) ~= nil).toBe(true)
	end)

	it("claim, reroll and pin call the actions with the quest's own values", function()
		expect(string.find(code.Board, "env.claim(v.id)", 1, true) ~= nil).toBe(true)
		expect(string.find(code.Board, "env.reroll(v.kind, v.slot)", 1, true) ~= nil).toBe(true)
		expect(string.find(code.Board, "env.pin(v.id, not v.pinned)", 1, true) ~= nil).toBe(true)
		expect(string.find(code.init, "actions().claimQuest(id)", 1, true) ~= nil).toBe(true)
		expect(string.find(code.init, "actions().rerollQuest(kind, slot)", 1, true) ~= nil).toBe(true)
		expect(string.find(code.init, "actions().pinQuest(id, on)", 1, true) ~= nil).toBe(true)
	end)

	it("Claim shows only for a complete quest; Reroll only for an active slot with rerolls left", function()
		expect(string.find(code.Row, 'view.status == "complete" then', 1, true) ~= nil).toBe(true)
		expect(string.find(code.Row, "(view.rerollsLeft or 0) > 0", 1, true) ~= nil).toBe(true)
	end)
end)

describe("Quests views: input and focus", function()
	it(
		"GuiService.SelectedObject is written only by Board.selectFirst, when opened from a gamepad",
		function()
			for name, src in code do
				local writes = select(2, string.gsub(src, "SelectedObject%s*=[^=]", ""))
				expect(writes).toBe(if name == "Board" then 1 else 0)
			end
			expect(string.find(code.Board, "if props.gamepad == true then", 1, true) ~= nil).toBe(true)
			expect(string.find(code.init, "gamepad = openedFromGamepad()", 1, true) ~= nil).toBe(true)
		end
	)

	it("selects the first Claim, else the first tab; B closes", function()
		expect(string.find(code.Board, '"^Claim%d+$"', 1, true) ~= nil).toBe(true)
		expect(string.find(code.Board, '"Tab_" .. firstTab', 1, true) ~= nil).toBe(true)
		expect(string.find(code.Board, "Enum.KeyCode.ButtonB", 1, true) ~= nil).toBe(true)
	end)

	it("the tracker lines are not Selectable and a tap opens the board", function()
		expect(string.find(code.Tracker, "Selectable = false", 1, true) ~= nil).toBe(true)
		expect(string.find(code.Tracker, "props.onOpen(State.tabOf(view))", 1, true) ~= nil).toBe(true)
		expect(string.find(code.Tracker, "if #pinned == 0 then", 1, true) ~= nil).toBe(true)
	end)

	it("the toast host creates its gui on the first toast, not at start", function()
		expect(string.find(code.Toasts, "local function ensure()", 1, true) ~= nil).toBe(true)
		local start = string.find(code.init, "function Quests.start", 1, true)
		expect(string.find(string.sub(code.init, start), "Toasts.new", 1, true)).toBe(nil)
	end)

	it("nothing opens the board by itself: UI.open runs only inside open() and openOdds()", function()
		local count = 0
		for _, src in code do
			for _ in string.gmatch(src, "UI%.open%(") do
				count += 1
			end
			for _ in string.gmatch(src, "ui%(%)%.open%(") do
				count += 1
			end
		end
		expect(count).toBe(2)
		expect(string.find(code.init, "ui().open(SCREEN", 1, true) ~= nil).toBe(true)
		local start = string.find(code.init, "function Quests.start", 1, true)
		local startBody = string.sub(code.init, start, string.find(code.init, "Quests.check =", 1, true))
		expect(string.find(startBody, "open(", 1, true)).toBe(nil)
	end)

	it("registers the screen unless the game has one, and the widgets unless removed", function()
		expect(string.find(code.init, "UI.screens:get(SCREEN) == nil", 1, true) ~= nil).toBe(true)
		expect(string.find(code.init, "removals[TRACKER_ID] == nil", 1, true) ~= nil).toBe(true)
		expect(string.find(code.init, "removals[BUTTON_ID] == nil", 1, true) ~= nil).toBe(true)
		expect(string.find(code.init, 'TRACKER_ID = "Quests.tracker"', 1, true) ~= nil).toBe(true)
		expect(string.find(code.init, 'BUTTON_ID = "Quests.button"', 1, true) ~= nil).toBe(true)
		-- right slot, orders 5 and 4
		expect(string.find(code.init, 'slot = "right",\n\t\t\torder = 5', 1, true) ~= nil).toBe(true)
		expect(string.find(code.init, 'slot = "right",\n\t\t\torder = 4', 1, true) ~= nil).toBe(true)
	end)
end)
