--!strict
--[[
	Override (c): the whole HUD replaced with this layout (GameConfig.client.hud.layout). The
	framework renders it with props { slots = { [slot] = { elements } }, toasts, state, opts }:
	every widget of every slot is stacked in one panel on the left edge instead of the default
	top-centre row. Colours and sizes come from the theme (UI kit components only).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local UI = require(ReplicatedStorage:WaitForChild("UI"))

local e = React.createElement

local ORDER = { "topLeft", "topCenter", "topRight", "left", "right", "bottom" }

local function MyHud(props: { slots: { [string]: { [string]: any } }, toasts: any })
	local rows: { [string]: any } = {}
	local n = 0
	for _, slot in ORDER do
		local elements = props.slots[slot]
		if elements then
			for key, element in elements do
				n += 1
				rows[slot .. "_" .. tostring(key)] = e("Frame", {
					BackgroundTransparency = 1,
					Size = UDim2.fromScale(0, 0),
					AutomaticSize = Enum.AutomaticSize.XY,
					LayoutOrder = n,
				}, { Widget = element })
			end
		end
	end
	return e(UI.ScaledRoot, nil, {
		Column = e(UI.Panel, {
			title = "My HUD",
			size = UDim2.fromOffset(260, 0),
			automaticSize = Enum.AutomaticSize.Y,
			position = UDim2.new(0, 12, 0.5, 0),
			anchorPoint = Vector2.new(0, 0.5),
		}, rows),
		Toasts = props.toasts,
	})
end

return MyHud
