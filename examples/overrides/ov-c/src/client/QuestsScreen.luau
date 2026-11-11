--!strict
--[[
	Override (c): a custom screen. Main.client registers it with UI.registerScreen("Quests", ...)
	and the action bar's "Quests" button opens it with UI.open("Quests"). Screens get props plus
	onClose from the screen registry.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local UI = require(ReplicatedStorage:WaitForChild("UI"))

local e = React.createElement

local function QuestsScreen(props: { onClose: () -> (), from: string? })
	return e(UI.Modal, {
		open = true,
		title = "Quests",
		onClose = props.onClose,
	}, {
		Body = e(UI.Button, {
			text = "Collect 10 items (opened from " .. tostring(props.from or "?") .. ")",
			variant = "secondary",
			layoutOrder = 1,
			onActivated = props.onClose,
		}),
	})
end

return QuestsScreen
