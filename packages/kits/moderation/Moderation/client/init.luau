--!strict
--[[
	Moderation client part (docs/framework/kits/moderation.md "Network and client").

	  - hears Notice(key, argsJson) (net.blink; server -> this player only) and opens the screen
	    "ModerationNotice": a modal with the localized preset (UI.text(key)) and, for a mute, how long
	    it lasts ("Moderation.mute.until" with { minutes }). A game replaces the screen with
	    UI.registerScreen("ModerationNotice", ...) (props: key, args, onClose).
	  - StudWork.use(Moderation).isMuted() -> (boolean, untilTs?)   from extra.muted (own player only)
	  - StudWork.use(Moderation).onNotice(fn(key, args)) -> Connection   for a game's own notice UI

	No client actions: nothing here can ask the server to moderate anyone. No tweens: the modal
	respects reduced motion by construction.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NAME = "Moderation"
local SCREEN = "ModerationNotice"

local net: any = nil
local handlers: { [number]: (string, any) -> () } = {}
local nextHandler = 0

local function studWork(): any
	return require(ReplicatedStorage:WaitForChild("Framework")) :: any
end

local function ui(): any
	return require(ReplicatedStorage:WaitForChild("UI")) :: any
end

local function mutedUntil(): number?
	local state = studWork().Client.state()
	if type(state) ~= "table" or type(state.modules) ~= "table" then
		return nil
	end
	local slice = state.modules[NAME]
	local extra = if type(slice) == "table" then slice.extra else nil
	local value = if type(extra) == "table" then extra.muted else nil
	return if type(value) == "number" then value else nil
end

local Moderation = {}

Moderation.SCREEN = SCREEN

-- argsJson -> a flat table of strings and numbers (anything else, or bad JSON: {})
function Moderation.decodeArgs(argsJson: any): { [string]: any }
	if type(argsJson) ~= "string" or argsJson == "" then
		return {}
	end
	local ok, decoded = pcall(function(): any
		return game:GetService("HttpService"):JSONDecode(argsJson)
	end)
	local out: { [string]: any } = {}
	if ok and type(decoded) == "table" then
		for k, v in decoded do
			if type(k) == "string" and (type(v) == "string" or type(v) == "number") then
				out[k] = v
			end
		end
	end
	return out
end

-- the lines a notice shows: { title, body, extra? } (all localized through UI.text)
function Moderation.lines(text: (string, any?) -> string, key: string, args: { [string]: any }): any
	local isWarn = string.sub(key, 1, #"Moderation.warn.") == "Moderation.warn."
	local heading = if isWarn then text("Moderation.warn.title") else text("Moderation.notice.title")
	local extra: string? = nil
	if type(args.minutes) == "number" then
		extra = text("Moderation.mute.until", { minutes = args.minutes })
	end
	return { title = heading, body = text(key, args), extra = extra }
end

local function NoticeScreen(props: any): any
	local UI = ui()
	local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React")) :: any
	local e = React.createElement
	local lines = Moderation.lines(UI.text, props.key or "Moderation.notice.title", props.args or {})
	local function label(text: string, order: number): any
		return e("TextLabel", {
			Text = text,
			TextWrapped = true,
			FontFace = UI.Theme.font("body"),
			TextSize = UI.Theme.text.body,
			TextColor3 = UI.Theme.color("text"),
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = order,
		})
	end
	return e(UI.Modal, { open = true, title = lines.title, onClose = props.onClose }, {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UI.Theme.padding(),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
		}),
		Body = label(lines.body, 1),
		Extra = if lines.extra then label(lines.extra, 2) else nil,
		Ok = e(UI.Button, {
			text = UI.text("Moderation.notice.ok"),
			layoutOrder = 3,
			onActivated = props.onClose,
		}),
	})
end

function Moderation.onNotice(key: string, argsJson: string)
	if type(key) ~= "string" or key == "" then
		return
	end
	local args = Moderation.decodeArgs(argsJson)
	for _, fn in table.clone(handlers) do
		task.spawn(fn, key, args)
	end
	local ok, err = pcall(function()
		local UI = ui()
		if UI.screens:get(SCREEN) ~= nil then
			UI.open(SCREEN, {
				key = key,
				args = args,
				onClose = function()
					UI.close(SCREEN)
				end,
			})
		end
	end)
	if not ok then
		warn(`[Moderation] notice: {tostring(err)}`)
	end
end

function Moderation.init(_context: any)
	local ok, loaded = pcall(function(): any
		return (require :: any)(script.Net)
	end)
	net = if ok then loaded else nil
end

function Moderation.start(_context: any)
	pcall(function()
		local UI = ui()
		if UI.screens:get(SCREEN) == nil then
			UI.registerScreen(SCREEN, NoticeScreen)
		end
	end)
	local event = if net ~= nil then net.Notice else nil
	if event ~= nil and type(event.On) == "function" then
		event.On(function(key: string, argsJson: string)
			Moderation.onNotice(key, argsJson)
		end)
	end
end

Moderation.api = {
	isMuted = function(): (boolean, number?)
		local untilTs = mutedUntil()
		if untilTs == nil or untilTs <= os.time() then
			return false, nil
		end
		return true, untilTs
	end,
	onNotice = function(fn: (key: string, args: { [string]: any }) -> ()): any
		assert(type(fn) == "function", "Moderation.onNotice(fn): fn must be a function(key, args)")
		nextHandler += 1
		local id = nextHandler
		handlers[id] = fn
		local conn: any = { Connected = true }
		function conn.Disconnect(self: any)
			self.Connected = false
			handlers[id] = nil
		end
		return conn
	end,
}

return Moderation
