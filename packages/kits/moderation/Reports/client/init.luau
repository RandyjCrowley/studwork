--!strict
--[[
	Reports client part (docs/framework/kits/moderation.md "Reports", "Network and client").

	  StudWork.use(Reports).open(targetUserId?)    opens the "Report" screen (registered with
	                                                UI.registerScreen at start unless the game
	                                                registered its own): pick a player (in this
	                                                server or recently left), a category, an
	                                                optional note, send; then the thanks message and
	                                                the block prompt. Does nothing while the
	                                                module's flag is off.
	  StudWork.use(Reports).recent() -> { { userId, name } }   extra.recent (setAll; names only)
	  StudWork.use(Reports).actions.submit(targetUserId, category, note?)   this module's own Net
	                                                event Submit (net.blink)
	  StudWork.use(Reports).read                    the screen's pure view state (./State.luau)

	The screen's props (also what a game's own "Report" screen receives): targetUserId?, config,
	submit(targetUserId, category, note?), recent(), onClose.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State = require(script.State)

local NAME = "Reports"
local SCREEN = "Report"

local config: any = nil

local function studWork(): any
	return require(ReplicatedStorage:WaitForChild("Framework")) :: any
end

local function ui(): any
	return require(ReplicatedStorage:WaitForChild("UI")) :: any
end

local function views(): any
	return require(script.Views) :: any
end

local function ref(): any
	return require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild(NAME):WaitForChild("module")) :: any
end

local function recent(): { any }
	local state = studWork().Client.state()
	if type(state) ~= "table" or type(state.modules) ~= "table" then
		return {}
	end
	local slice = state.modules[NAME]
	local extra = if type(slice) == "table" then slice.extra else nil
	local list = if type(extra) == "table" then extra.recent else nil
	local out = {}
	if type(list) == "table" then
		for _, entry in list do
			if type(entry) == "table" and type(entry.userId) == "number" and type(entry.name) == "string" then
				table.insert(out, { userId = entry.userId, name = entry.name })
			end
		end
	end
	return out
end

-- the flag decides presentation only (the server refuses a report while it is off); a flag
-- the client can't read (serverOnly) counts as on
local function flagOn(): boolean
	local flag = if type(config) == "table" then config.flag else nil
	if flag == nil then
		return true
	end
	local ok, on = pcall(function(): boolean
		return studWork().flags.isOn(flag)
	end)
	return not ok or on == true
end

local function submit(targetUserId: number, category: string, note: string?)
	studWork().use(ref()).actions.submit(targetUserId, category, note)
end

local Reports = {}

Reports.SCREEN = SCREEN

function Reports.start(context: any)
	config = if type(context) == "table" then context.config else nil
	local UI = ui()
	if UI.screens:get(SCREEN) == nil then
		UI.registerScreen(SCREEN, function(props: any): any
			return views().Screen(props)
		end)
	end
end

-- `submit = true`: fire this part's own Net event Submit (module-api §19.9)
Reports.actions = { submit = true }

Reports.api = {
	open = function(targetUserId: number?)
		if not flagOn() then
			return
		end
		local UI = ui()
		if UI.screens:get(SCREEN) == nil then
			return
		end
		UI.open(SCREEN, {
			targetUserId = targetUserId,
			config = config,
			submit = submit,
			recent = recent,
		})
	end,
	recent = recent,
	read = State,
}

return Reports
