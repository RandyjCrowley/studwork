--!strict
-- Client command bar while Play is running. Set KEEP = true to inspect the last viewport.
local KEEP = false
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local HttpService = game:GetService("HttpService")
local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local ReactRoblox = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("ReactRoblox"))
local UI = require(ReplicatedStorage:WaitForChild("UI"))
local Responsive = require(ReplicatedStorage.UI.Responsive)
local e = React.createElement
local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local sizes = {
	{ "desktop", 1280, 720 },
	{ "smallPhone", 667, 375 },
	{ "largePhone", 926, 428 },
	{ "tablet", 1024, 768 },
}
local tiers = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Secret", "Divine" }
local items, odds = {}, {}
for i, tier in tiers do
	local id = "Item" .. i
	table.insert(items, { id = id, name = tier .. " Rainbow Sword of the Ancients", rarity = tier })
	odds[id] = ({ 0.5, 0.25, 0.15, 0.07, 0.0289, 0.001, 0.0001, 0.000001 })[i]
end
local notice = "Paid random items are restricted in your region. You can still earn these rewards by playing."
local cases: { [string]: any } = {
	OddsTable = e(
		UI.Modal,
		{ open = true, title = "Extraordinary Rainbow Rewards", onClose = function() end },
		{
			Table = e(UI.OddsTable, { odds = odds, items = items, restricted = true, layoutOrder = 1 }),
			Action = e(
				UI.Button,
				{ text = "Claim this very long reward", layoutOrder = 2, onActivated = function() end }
			),
		}
	),
	Inventory = e(
		UI.screens and UI.screens:get("Inventory") or UI.Modal,
		{ open = true, title = "Inventory", items = items, onClose = function() end }
	),
	Mailbox = e(UI.screens and UI.screens:get("Mailbox") or UI.Modal, {
		open = true,
		title = "Mailbox",
		messages = {
			{
				id = "mail1",
				kind = "item",
				payload = { itemId = "Legendary Rainbow Sword of the Ancients" },
			},
		},
		onClose = function() end,
	}),
	Button = e(UI.Button, { text = "Upgrade income (5000000)", onActivated = function() end }),
	CurrencyCounter = e(UI.CurrencyCounter, { value = 999999999999999, rate = 999999999 }),
	Panel = e(
		UI.Panel,
		{ title = "Extraordinary Rainbow Rewards" },
		{ Label = e(UI.Button, { text = "Continue", onActivated = function() end }) }
	),
	Toast = e(UI.Toast, { text = notice }),
	ToastHost = e(UI.ToastHost, {
		subscribe = function(push: any)
			push(notice, "Legendary")
			return function() end
		end,
	}),
}
for _, tier in tiers do
	cases["Badge" .. tier] = e(UI.RarityBadge, { rarity = tier })
	cases["Card" .. tier] = e(
		UI.ItemCard,
		{ name = tier .. " Rainbow Sword of the Ancients", rarity = tier, incomePerSec = 99999999 }
	)
end
local output: { [string]: any } = {}
local function scaleOf(inst: Instance): number
	local scale = 1
	local node: Instance? = inst
	while node do
		local uiScale = node:FindFirstChildOfClass("UIScale")
		if uiScale then
			scale *= uiScale.Scale
		end
		node = node.Parent
	end
	return scale
end
local function textIssue(inst: TextLabel | TextButton | TextBox, minimum: number): any?
	if inst.Text == "" or not inst.Visible then
		return nil
	end
	local size = inst.AbsoluteSize
	local scale = scaleOf(inst)
	local constraint = inst:FindFirstChildOfClass("UITextSizeConstraint")
	local nominal = if inst.TextScaled and constraint then constraint.MinTextSize else inst.TextSize
	local effective = nominal * scale
	local padding = inst:FindFirstChildOfClass("UIPadding")
	local padX, padY = 0, 0
	if padding then
		padX = padding.PaddingLeft.Offset + padding.PaddingRight.Offset
		padY = padding.PaddingTop.Offset + padding.PaddingBottom.Offset
	end
	local width = math.max(1, size.X - padX)
	local params = Instance.new("GetTextBoundsParams")
	params.Text = inst.Text
	params.Font = inst.FontFace
	params.Size = if inst.TextScaled
		then math.max(nominal, inst.TextBounds.Y / math.max(1, scale))
		else inst.TextSize
	params.Width = if inst.TextWrapped then width / math.max(scale, 0.01) else 100000
	local ok, bounds = pcall(function()
		return TextService:GetTextBoundsAsync(params)
	end)
	local neededX = if ok then bounds.X * scale else 0
	local neededY = if ok then bounds.Y * scale else 0
	local reason = if size.X <= 0 or size.Y <= 0
		then "zero-size"
		elseif effective < minimum - 0.01 then "below-minimum"
		elseif not ok then "measurement-failed"
		elseif
			neededY > size.Y - padY + 1 or (not inst.TextWrapped and neededX > size.X - padX + 1)
		then "clipped"
		else nil
	if not reason then
		return nil
	end
	return {
		path = inst:GetFullName(),
		text = inst.Text,
		reason = reason,
		absolute = tostring(size),
		needed = tostring(bounds),
		scale = scale,
		effective = effective,
		minimum = minimum,
	}
end
for _, viewport in sizes do
	local name, width, height = viewport[1], viewport[2], viewport[3]
	local findings, hits = {}, {}
	for caseName, element in cases do
		local gui = Instance.new("ScreenGui")
		gui.Name = "UiTextFit_" .. caseName
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.DisplayOrder = 1000
		gui.Parent = playerGui
		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromOffset(width, height)
		frame.BackgroundTransparency = 1
		frame.Parent = gui
		local root = ReactRoblox.createRoot(frame)
		local responsiveScale = Responsive.scale(width, height)
		root:render(e("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1 / responsiveScale, 1 / responsiveScale),
		}, {
			Scale = e("UIScale", { Scale = responsiveScale }),
			Case = element,
		}))
		for _ = 1, 18 do
			RunService.RenderStepped:Wait()
		end
		local minimum = (UI.Theme.metrics and UI.Theme.metrics.minTextSize) or 11
		local body = frame:FindFirstChild("Body", true)
		for _, descendant in frame:GetDescendants() do
			if descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox") then
				local result = textIssue(descendant, minimum)
				if result then
					table.insert(findings, result)
				end
			end
			if
				descendant:IsA("GuiButton")
				and descendant.Name ~= "Sink"
				and body ~= nil
				and descendant:IsDescendantOf(body)
			then
				local center = descendant.AbsolutePosition + descendant.AbsoluteSize / 2
				local top = playerGui:GetGuiObjectsAtPosition(center.X, center.Y)[1]
				if not top or (top ~= descendant and not top:IsDescendantOf(descendant)) then
					table.insert(
						hits,
						{ button = descendant:GetFullName(), top = if top then top:GetFullName() else "none" }
					)
				end
			end
		end
		if not KEEP or name ~= "tablet" then
			root:unmount()
			gui:Destroy()
		end
	end
	output[name] = { width = width, height = height, clipped = findings, blockedButtons = hits }
end
return HttpService:JSONEncode(output)
