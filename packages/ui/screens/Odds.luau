--!strict
--[[
	Default "Odds" screen (registered by the UI kit; replace with UI.registerScreen("Odds", ...)).
	props: title?, detail (server OddsDetail), odds? (legacy map), items ({id,name,rarity}),
	restricted?, restrictedText?, sortBy?, actions? (children: buttons under the table), onClose.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Modal = require(script.Parent.Parent.Modal)
local OddsTable = require(script.Parent.Parent.OddsTable)
local UIText = require(script.Parent.Parent.Text)

local e = React.createElement

return function(props: any)
	UIText.useLocale()
	local children: { [string]: any } = {
		Table = e(OddsTable, {
			detail = props.detail,
			odds = props.odds,
			items = props.items or {},
			restricted = props.restricted,
			restrictedText = props.restrictedText,
			sortBy = props.sortBy,
			layoutOrder = 1,
			title = false,
		}),
	}
	if type(props.actions) == "table" then
		for k, v in props.actions do
			children[k] = v
		end
	end
	return e(
		Modal,
		{ open = true, title = props.title or UIText.text("ui.odds.title"), onClose = props.onClose },
		children
	)
end
