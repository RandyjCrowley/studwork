--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local React = require(ReplicatedStorage.Packages.React) :: any
local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
local Responsive = require(ReplicatedStorage.UI.Responsive)
local ModalFit = require(ReplicatedStorage.UI.ModalFit)
local Layout = require(script.Parent.Layout)
local e = React.createElement
local Views = {}
local function textScale(): number
	local value = Players.LocalPlayer:GetAttribute("CoreTextScale")
	if type(value) == "number" then
		return math.clamp(value, 1, 1.5)
	end
	local preferred = tostring(GuiService.PreferredTextSize)
	return if string.find(preferred, "Largest", 1, true)
		then 1.5
		elseif string.find(preferred, "Larger", 1, true) then 1.35
		elseif string.find(preferred, "Large", 1, true) then 1.15
		else 1
end
local function textLimit(size: number?): any
	local pixels = math.ceil(size or UI.Theme.text.body * textScale())
	return e("UITextSizeConstraint", { MinTextSize = pixels, MaxTextSize = pixels })
end
local function target(): number
	return math.max(
		UI.Theme.touchTarget,
		Layout.touch(
			UI.Theme.metrics.minTouchTarget,
			Responsive.MIN_SCALE,
			ModalFit.minScale(UI.Theme.tokens)
		)
	)
end
local function label(text: string, order: number, size: number?): any
	return e("TextLabel", {
		Text = text,
		FontFace = UI.Theme.font("body"),
		TextSize = size or UI.Theme.text.body * textScale(),
		TextColor3 = UI.Theme.color("text"),
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = order,
	}, { TextLimit = textLimit(size) })
end
local function button(text: string, action: () -> (), order: number, width: number?): any
	return e("TextButton", {
		Text = text,
		FontFace = UI.Theme.font("body"),
		TextSize = UI.Theme.text.body * textScale(),
		TextColor3 = UI.Theme.color("text"),
		BackgroundColor3 = UI.Theme.color("accentAlt"),
		BorderSizePixel = 0,
		Size = UDim2.new(width or 1, if width then -UI.Theme.metrics.padding else 0, 0, target()),
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		[React.Event.Activated] = action,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, UI.Theme.metrics.cornerRadius) }),
		TextLimit = textLimit(),
	})
end
function Views.Screen(props: any): any
	local _, redraw = React.useState(0)
	local refresh = function()
		redraw(function(n: number)
			return n + 1
		end)
	end
	React.useEffect(function()
		local disconnect = props.subscribe(refresh)
		local textConnection = Players.LocalPlayer:GetAttributeChangedSignal("CoreTextScale"):Connect(refresh)
		local preferenceConnection = GuiService:GetPropertyChangedSignal("PreferredTextSize"):Connect(refresh)
		return function()
			disconnect()
			textConnection:Disconnect()
			preferenceConnection:Disconnect()
		end
	end, {})
	local title = UI.useText("Settings.title")
	local children: { [string]: any } = {}
	local list = {}
	for _, def in props.definitions do
		table.insert(list, def)
	end
	table.sort(list, function(a: any, b: any): boolean
		return if a.category == b.category then a.id < b.id else a.category < b.category
	end)
	local category = ""
	local order = 0
	for _, def in list do
		if category ~= def.category then
			category = def.category
			order += 1
			children["Category" .. category] =
				label(UI.text("Settings.category." .. category), order, UI.Theme.text.title * textScale())
		end
		order += 1
		children["Label" .. def.id] = label(UI.text(def.labelKey), order)
		if def.descriptionKey then
			order += 1
			children["Description" .. def.id] = label(UI.text(def.descriptionKey), order)
		end
		order += 1
		local value = props.api.get(def.id)
		if def.type == "toggle" then
			children[def.id] = button(UI.text(if value then "Settings.on" else "Settings.off"), function()
				props.api.set(def.id, not props.api.get(def.id))
			end, order)
		elseif def.type == "slider" then
			children[def.id] = e(
				"Frame",
				{ BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, target()), LayoutOrder = order },
				{
					Layout = e("UIListLayout", {
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, UI.Theme.metrics.padding),
					}),
					Minus = button(UI.text("Settings.decrease"), function()
						props.api.set(def.id, Layout.step(props.api.get(def.id), -1, def))
					end, 1, 0.35),
					Value = e("TextLabel", {
						Text = string.format("%.2f", value),
						FontFace = UI.Theme.font("body"),
						TextSize = UI.Theme.text.body * textScale(),
						TextColor3 = UI.Theme.color("text"),
						BackgroundTransparency = 1,
						Size = UDim2.new(0.3, -UI.Theme.metrics.padding, 1, 0),
						LayoutOrder = 2,
					}, { TextLimit = textLimit() }),
					Plus = button(UI.text("Settings.increase"), function()
						props.api.set(def.id, Layout.step(props.api.get(def.id), 1, def))
					end, 3, 0.35),
				}
			)
		else
			local choices = def.choices
			local index = table.find(choices, value) or 1
			local key = if string.match(tostring(value), "^[%a][%w_]*%.[%w_.]+$")
				then value
				elseif def.id == "textSize" then "Settings.choice." .. tostring(value)
				else "Settings.choice." .. def.id .. "." .. tostring(index)
			children[def.id] = button(UI.text(key), function()
				props.api.set(def.id, choices[index % #choices + 1])
			end, order)
		end
	end
	order += 1
	children.Status = label(UI.text("Settings." .. props.status()), order)
	order += 1
	children.Reset = button(UI.text("Settings.reset"), props.api.reset, order)
	order += 1
	children.Close = button(UI.text("Settings.close"), props.onClose, order)
	return e(UI.Modal, { open = true, title = title, dismissOnBackdrop = false }, children)
end
return Views
