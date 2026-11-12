--!strict
--[[
	Default "Mailbox" screen (replace with UI.registerScreen("Mailbox", ...)).
	props: messages ({ { id, kind, payload } }, Mail's replicated extra.mailbox), describe?(msg)
	-> string, onClaim?(id, msg), title?, emptyText?, onClose.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Button = require(script.Parent.Parent.Button)
local Modal = require(script.Parent.Parent.Modal)
local Theme = require(script.Parent.Parent.Theme)
local UIText = require(script.Parent.Parent.Text)

local e = React.createElement

local function defaultDescribe(msg: any): string
	local payload = msg.payload
	local item = if type(payload) == "table"
		then (if type(payload.item) == "table" then payload.item.itemId else payload.itemId)
		else nil
	return UIText.text("ui.mail.claim", { item = tostring(item or msg.kind) })
end

return function(props: any)
	UIText.useLocale()
	local messages: { any } = props.messages or {}
	local describe = props.describe or defaultDescribe
	local rows: { [string]: any } = {}
	for i, msg in messages do
		rows["Row" .. i] = e(Button, {
			text = describe(msg),
			variant = "secondary",
			layoutOrder = i,
			disabled = props.onClaim == nil,
			onActivated = function()
				if props.onClaim then
					props.onClaim(msg.id, msg)
				end
			end,
		})
	end
	if #messages == 0 then
		rows.Empty = e("TextLabel", {
			Text = props.emptyText or UIText.text("ui.mail.empty"),
			FontFace = Theme.font("body"),
			TextSize = Theme.text.body,
			TextColor3 = Theme.color("textMuted"),
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.XY,
			Size = UDim2.fromOffset(0, 0),
		})
	end
	return e(
		Modal,
		{ open = true, title = props.title or UIText.text("ui.mail.title"), onClose = props.onClose },
		rows
	)
end
