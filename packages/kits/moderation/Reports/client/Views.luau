--!strict
--[[
	The default "Report" screen (React). Loaded lazily by client/init.luau, so requiring the client
	part in a test or on a server never needs React. The logic is in ./State.luau (pure, specced).

	props (UI.open("Report", props); a game's own "Report" screen gets the same):
	  targetUserId?   preselect a player (skips the picker when they can be reported)
	  config          config.Reports (categories, note, blockPrompt)
	  submit(targetUserId, category, note?)   fires the Submit action
	  recent() -> { { userId, name } }        the recently-left list
	  onClose         from the screen host

	Mobile first (667x375): one column inside UI.Modal, every control a full-width row at least
	Theme.touchTarget tall. Theme tokens only, every label a Reports.* key through UI.text, player
	names shown as they are (AutoLocalize off). No tweens or animations at all (plain TextButtons,
	not the kit Button with its press tween), so reduced motion is respected by construction.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages:WaitForChild("React")) :: any
local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
local State = require(script.Parent.State)

local e = React.createElement
local Theme = UI.Theme

local Views = {}

local function inServer(): ({ any }, { [number]: boolean })
	local list, set = {}, {}
	for _, p in Players:GetPlayers() do
		table.insert(list, { userId = p.UserId, name = p.Name })
		set[p.UserId] = true
	end
	return list, set
end

local function selfUserId(): number?
	local player = Players.LocalPlayer
	return if player then player.UserId else nil
end

-- a full-width row button with no animation. props: text, layoutOrder, onActivated?, selected?,
-- disabled?, localize? (false for player names)
local function Choice(props: any): any
	local disabled = props.disabled == true
	local color = if disabled
		then "surface"
		elseif props.selected then "accent"
		elseif props.primary then "accentAlt"
		else "surfaceAlt"
	return e("TextButton", {
		Text = props.text,
		AutoLocalize = props.localize ~= false,
		AutoButtonColor = false,
		Active = not disabled,
		FontFace = Theme.font("bold"),
		TextSize = Theme.text.body,
		TextColor3 = if disabled then Theme.color("textMuted") else Theme.color("text"),
		TextWrapped = true,
		BackgroundColor3 = Theme.color(color),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Theme.touchTarget),
		LayoutOrder = props.layoutOrder,
		[React.Event.Activated] = function()
			if not disabled and props.onActivated then
				props.onActivated()
			end
		end,
	}, {
		Corner = e("UICorner", { CornerRadius = Theme.cornerRadius() }),
		Stroke = e("UIStroke", {
			Color = Theme.color("outline"),
			Thickness = Theme.metrics.strokeThickness,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}),
	})
end

local function Label(text: string, layoutOrder: number, muted: boolean?, localize: boolean?): any
	return e("TextLabel", {
		Text = text,
		AutoLocalize = localize ~= false,
		FontFace = Theme.font("body"),
		TextSize = Theme.text.body,
		TextColor3 = if muted then Theme.color("textMuted") else Theme.color("text"),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = layoutOrder,
	})
end

function Views.Screen(props: any): any
	local title = UI.useText("Reports.title")
	local config = if type(props.config) == "table" then props.config else {}
	local here, hereSet = inServer()
	local recent = if type(props.recent) == "function" then props.recent() else {}
	local candidates = State.candidates(here, recent, selfUserId())
	local s, setS = React.useState(function(): any
		return State.initial(props.targetUserId, candidates)
	end)
	local children: { [string]: any } = {}
	local order = 0
	local function add(name: string, element: any)
		order += 1
		children[name] = element
	end

	if s.step == "pick" then
		add("Pick", Label(UI.text("Reports.pick"), order + 1))
		local section = nil
		for i, c in candidates do
			if c.section ~= section then
				section = c.section
				add(
					"Section" .. i,
					Label(
						UI.text(if c.section == "recent" then "Reports.recent" else "Reports.inServer"),
						order + 1,
						true
					)
				)
			end
			add(
				"Player" .. c.userId,
				e(Choice, {
					text = c.name,
					localize = false,
					layoutOrder = order + 1,
					onActivated = function()
						setS(State.pick(s, c.userId, candidates))
					end,
				})
			)
		end
		if #candidates == 0 then
			add("Empty", Label(UI.text("Reports.noPlayers"), order + 1, true))
		end
		add(
			"Cancel",
			e(
				Choice,
				{ text = UI.text("Reports.cancel"), layoutOrder = order + 1, onActivated = props.onClose }
			)
		)
	elseif s.step == "category" then
		add("Target", Label(s.targetName or "", order + 1, false, false))
		add("Why", Label(UI.text("Reports.why"), order + 1, true))
		local categories = State.categories(config)
		for _, c in categories do
			add(
				"Category" .. c.id,
				e(Choice, {
					text = UI.text(c.key),
					selected = s.category == c.id,
					layoutOrder = order + 1,
					onActivated = function()
						setS(State.choose(s, c.id, categories))
					end,
				})
			)
		end
		local noteCfg = if type(config.note) == "table" then config.note else {}
		if noteCfg.enabled == true then
			add(
				"Note",
				e("TextBox", {
					Text = s.note,
					PlaceholderText = UI.text("Reports.note"),
					ClearTextOnFocus = false,
					TextWrapped = true,
					FontFace = Theme.font("body"),
					TextSize = Theme.text.body,
					TextColor3 = Theme.color("text"),
					PlaceholderColor3 = Theme.color("textMuted"),
					TextXAlignment = Enum.TextXAlignment.Left,
					BackgroundColor3 = Theme.color("surface"),
					BorderSizePixel = 0,
					Size = UDim2.new(1, 0, 0, Theme.touchTarget),
					LayoutOrder = order + 1,
					[React.Change.Text] = function(rbx: any)
						if rbx.Text ~= s.note then
							setS(State.setNote(s, rbx.Text, noteCfg.maxLength or 0))
						end
					end,
				}, {
					Corner = e("UICorner", { CornerRadius = Theme.cornerRadius() }),
					Padding = e("UIPadding", {
						PaddingLeft = Theme.padding(),
						PaddingRight = Theme.padding(),
					}),
				})
			)
		end
		local target, category, note = State.args(s, config)
		add(
			"Submit",
			e(Choice, {
				text = UI.text("Reports.submit"),
				primary = true,
				disabled = target == nil,
				layoutOrder = order + 1,
				onActivated = function()
					if target ~= nil and category ~= nil and type(props.submit) == "function" then
						props.submit(target, category, note)
						setS(State.sent(s))
					end
				end,
			})
		)
		add(
			"Back",
			e(Choice, {
				text = UI.text("Reports.back"),
				layoutOrder = order + 1,
				onActivated = function()
					setS(State.back(s))
				end,
			})
		)
	else
		add("Thanks", Label(UI.text("Reports.thanks"), order + 1))
		if State.offerBlock(s, config, hereSet) then
			add(
				"Block",
				e(Choice, {
					text = UI.text("Reports.block"),
					layoutOrder = order + 1,
					onActivated = function()
						local player = Players:GetPlayerByUserId(s.target)
						if player ~= nil then
							pcall(function()
								StarterGui:SetCore("PromptBlockPlayer", player)
							end)
						end
					end,
				})
			)
		end
		add(
			"Done",
			e(Choice, {
				text = UI.text("Reports.done"),
				primary = true,
				layoutOrder = order + 1,
				onActivated = props.onClose,
			})
		)
	end

	return e(UI.Modal, { open = true, title = title, onClose = props.onClose }, children)
end

return Views
