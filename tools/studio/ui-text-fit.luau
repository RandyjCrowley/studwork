--!strict
--[[
	UI kit text-fit audit (Studio, Client VM, during Play). Paste into the Client command bar, or run
	through Studio MCP execute_luau with datamodel_type = "Client". Returns JSON.

	Mounts every UI kit component and default screen with its longest realistic strings (long item
	names, the region notice, "LEGENDARY", "0.0001%", huge numbers, a long toast) one at a time in a
	surface sized to each of the four sizes (desktop 1280x720, small phone 667x375, large phone
	926x428, tablet 1024x768), under the same responsive UIScale UI.ScaledRoot applies there.

	"Clipped" is measured, never read from TextFits (TextFits stays true for the v1.6.1 notice
	that showed one line of three). For every TextLabel/TextButton/TextBox with text:
	  s      = product of every ancestor UIScale (responsive scale, Modal fit, ...)
	  inner  = AbsoluteSize / s minus the label's UIPadding (design px)
	  plain  : TextService:GetTextBoundsAsync at TextSize (wrap width = inner width if TextWrapped)
	           must fit inner; with TextTruncate set it only needs one line (reported as truncated)
	  scaled : the size the engine renders is emulated (largest size in [MinTextSize, MaxTextSize]
	           whose wrapped bounds fit inner); if even MinTextSize doesn't fit, it is clipped
	  every text's rendered size x s must be >= Theme.metrics.minTextSize (11 if absent)
	Modal buttons: every GuiButton inside a kit Modal whose centre is on screen and inside every
	clipping ancestor (scrolled-out rows are skipped, not failed) must be the top hit of
	PlayerGui:GetGuiObjectsAtPosition (or a descendant of the button).

	Pass: every size reports clipped = {} and blocked = {}. Set KEEP and KEEP_CASE to leave one
	size's case mounted for a screenshot (stop Play to clear it); ONLY runs a single case.
]]

local KEEP: string? = nil -- e.g. "smallPhone"
local KEEP_CASE: string? = nil -- e.g. "OddsScreen"
local ONLY: string? = nil -- run only this case (debugging)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local ReactRoblox = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("ReactRoblox"))
local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
local Responsive = require(ReplicatedStorage:WaitForChild("UI"):WaitForChild("Responsive")) :: any
local e = React.createElement
local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local SIZES = {
	{ "desktop", 1280, 720 },
	{ "smallPhone", 667, 375 },
	{ "largePhone", 926, 428 },
	{ "tablet", 1024, 768 },
}
local TIERS = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical", "Secret", "Divine" }
local PROBS = { 0.5, 0.25, 0.15, 0.07, 0.0289, 0.001, 0.0001, 0.000001 }
local items, odds = {}, {}
for i, tier in TIERS do
	local id = "Item" .. i
	table.insert(items, { id = id, name = tier .. " Rainbow Sword of the Ancients", rarity = tier })
	odds[id] = PROBS[i]
end
local NOTICE = "Paid random items are restricted in your region. You can still earn these rewards by playing."
local function noop() end

local function screen(name: string): any
	return if UI.screens then UI.screens:get(name) else nil
end

local cases: { [string]: any } = {
	-- the default Odds screen, restricted (the v1.6.1 bug), long names, an action under the table
	OddsScreen = e(screen("Odds"), {
		items = items,
		odds = odds,
		restricted = true,
		onClose = noop,
		actions = { Buy = e(UI.Button, { text = "Buy egg", layoutOrder = 2, onActivated = noop }) },
	}),
	-- OddsTable on its own (a game's own panel)
	OddsTable = e(UI.OddsTable, { odds = odds, items = items, restricted = true }),
	Inventory = e(screen("Inventory"), { items = items, onClose = noop }),
	Mailbox = e(screen("Mailbox"), {
		messages = {
			{ id = "m1", kind = "gift", payload = { itemId = "Item5" } },
			{ id = "m2", kind = "item", payload = { item = { itemId = "Item6" } } },
		},
		onClose = noop,
	}),
	ModalLongTitle = e(UI.Modal, { open = true, title = "Extraordinary Rainbow Rewards", onClose = noop }, {
		Claim = e(UI.Button, { text = "Claim this very long reward", layoutOrder = 1, onActivated = noop }),
	}),
	Button = e(UI.Button, { text = "Upgrade income (5000000)", onActivated = noop }),
	CurrencyCounter = e(UI.CurrencyCounter, { value = 999999999999999, rate = 999999999, label = "Coins" }),
	Panel = e(UI.Panel, { title = "Extraordinary Rainbow Rewards" }, {
		Continue = e(UI.Button, { text = "Continue", onActivated = noop }),
	}),
	Toast = e(UI.Toast, { text = NOTICE }),
}
for i, tier in TIERS do
	cases["Badge" .. tier] = e(UI.RarityBadge, { rarity = tier })
	cases["Card" .. tier] = e(UI.ItemCard, {
		name = items[i].name,
		rarity = tier,
		incomePerSec = 999999999,
		mutation = "Rainbow",
	})
end

local minimum: number = (UI.Theme.metrics and UI.Theme.metrics.minTextSize) or 11

local function scaleOf(inst: Instance): number
	local s = 1
	local node: Instance? = inst
	while node do
		for _, child in node:GetChildren() do
			if child:IsA("UIScale") then
				s *= child.Scale
			end
		end
		node = node.Parent
	end
	return s
end

local cache: { [string]: Vector2 } = {}
local function bounds(text: string, font: Font, size: number, width: number): Vector2?
	local key = table.concat({
		text,
		font.Family,
		tostring(font.Weight),
		tostring(size),
		tostring(math.floor(width)),
	}, "|")
	local hit = cache[key]
	if hit then
		return hit
	end
	local params = Instance.new("GetTextBoundsParams")
	params.Text = text
	params.Font = font
	params.Size = size
	params.Width = width
	local ok, result = pcall(function()
		return TextService:GetTextBoundsAsync(params)
	end)
	params:Destroy()
	if ok then
		cache[key] = result
		return result
	end
	return nil
end

local function inset(inst: GuiObject, w: number, h: number): (number, number)
	local pad = inst:FindFirstChildOfClass("UIPadding")
	if not pad then
		return 0, 0
	end
	return pad.PaddingLeft.Scale * w
		+ pad.PaddingLeft.Offset
		+ pad.PaddingRight.Scale * w
		+ pad.PaddingRight.Offset,
		pad.PaddingTop.Scale * h
			+ pad.PaddingTop.Offset
			+ pad.PaddingBottom.Scale * h
			+ pad.PaddingBottom.Offset
end

local function check(inst: any): (any?, any?)
	if inst.Text == "" or not inst.Visible then
		return nil, nil
	end
	local s = scaleOf(inst)
	local fullW, fullH = inst.AbsoluteSize.X / s, inst.AbsoluteSize.Y / s
	local padX, padY = inset(inst, fullW, fullH)
	local w, h = fullW - padX, fullH - padY
	local info: { [string]: any } = {
		path = (inst:GetFullName():gsub("^.-PlayerGui%.", "")),
		text = inst.Text,
		box = string.format("%.0fx%.0f", w, h),
		scale = math.floor(s * 1000 + 0.5) / 1000,
	}
	if w <= 0 or h <= 0 then
		info.reason = "zero-size"
		return info, nil
	end
	local rendered: number
	if inst.TextScaled then
		local c = inst:FindFirstChildOfClass("UITextSizeConstraint")
		local lo = if c then math.max(1, c.MinTextSize) else 1
		local hi = if c then c.MaxTextSize else 100
		local function fits(size: number): boolean
			local b = bounds(inst.Text, inst.FontFace, size, w)
			return b ~= nil and b.X <= w + 1 and b.Y <= h + 1
		end
		if not fits(lo) then
			local b = bounds(inst.Text, inst.FontFace, lo, w)
			info.reason = "clipped"
			info.needed = if b then string.format("%.0fx%.0f at %d", b.X, b.Y, lo) else "?"
			return info, nil
		end
		local a, z = lo, hi
		while z - a > 0.5 do
			local mid = (a + z) / 2
			if fits(mid) then
				a = mid
			else
				z = mid
			end
		end
		rendered = a
	else
		rendered = inst.TextSize
		local b = bounds(inst.Text, inst.FontFace, rendered, if inst.TextWrapped then w else 100000)
		if b == nil then
			info.reason = "measure-failed"
			return info, nil
		end
		info.needed = string.format("%.0fx%.0f", b.X, b.Y)
		local autoX = inst.AutomaticSize == Enum.AutomaticSize.X
			or inst.AutomaticSize == Enum.AutomaticSize.XY
		local tooWide = not inst.TextWrapped and not autoX and b.X > w + 1
		local tooTall = b.Y > h + 1
		if inst.TextTruncate ~= Enum.TextTruncate.None and (tooWide or tooTall) then
			local line = bounds("Ag", inst.FontFace, rendered, 100000)
			if line and line.Y > h + 1 then
				info.reason = "clipped"
				return info, nil
			end
			info.reason = "truncated (intentional)"
			return nil, info
		end
		if tooWide or tooTall then
			info.reason = "clipped"
			return info, nil
		end
	end
	info.rendered = math.floor(rendered * s * 10 + 0.5) / 10
	if rendered * s < minimum - 0.01 then
		info.reason = string.format("below minTextSize %d", minimum)
		return info, nil
	end
	return nil, nil
end

-- the on-screen rectangle a descendant can be hit in: the camera viewport cut by every
-- clipping ancestor (ScrollingFrame, ClipsDescendants)
local function visibleRect(inst: GuiObject): (Vector2, Vector2)
	local cam = Workspace.CurrentCamera
	local lo = Vector2.zero
	local hi = if cam then cam.ViewportSize else Vector2.new(math.huge, math.huge)
	local node: Instance? = inst.Parent
	while node and not node:IsA("ScreenGui") do
		if node:IsA("GuiObject") and (node.ClipsDescendants or node:IsA("ScrollingFrame")) then
			local p, sz = node.AbsolutePosition, node.AbsoluteSize
			lo = Vector2.new(math.max(lo.X, p.X), math.max(lo.Y, p.Y))
			hi = Vector2.new(math.min(hi.X, p.X + sz.X), math.min(hi.Y, p.Y + sz.Y))
		end
		node = node.Parent
	end
	return lo, hi
end

local output: { [string]: any } = {}
for _, size in SIZES do
	local name, width, height = size[1], size[2], size[3]
	local clipped, truncated, blocked, checkedButtons, labels = {}, {}, {}, 0, 0
	for caseName, element in cases do
		if ONLY and caseName ~= ONLY then
			continue
		end
		local gui = Instance.new("ScreenGui")
		gui.Name = "UiTextFit_" .. caseName
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.DisplayOrder = 1000
		gui.Parent = playerGui
		local surface = Instance.new("Frame")
		surface.Name = "Surface"
		surface.Size = UDim2.fromOffset(width, height)
		surface.BackgroundTransparency = 0.3
		surface.BackgroundColor3 = Color3.new(0.2, 0.25, 0.3)
		surface.ClipsDescendants = true
		surface.Parent = gui
		local root = ReactRoblox.createRoot(surface)
		local rs = Responsive.scale(width, height)
		root:render(e("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1 / rs, 1 / rs),
		}, { Scale = e("UIScale", { Scale = rs }), Case = element }))
		for _ = 1, 30 do
			RunService.RenderStepped:Wait()
		end
		task.wait(0.3) -- WrappedText measures asynchronously
		for _ = 1, 5 do
			RunService.RenderStepped:Wait()
		end
		local modalBody: Instance? = nil
		for _, d in surface:GetDescendants() do
			if d.Name == "Sink" and d.Parent then
				modalBody = d.Parent
			end
		end
		for _, d in surface:GetDescendants() do
			if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
				labels += 1
				local bad, cut = check(d)
				if bad then
					bad.case = caseName
					table.insert(clipped, bad)
				elseif cut then
					cut.case = caseName
					table.insert(truncated, cut)
				end
			end
			if d:IsA("GuiButton") and d.Name ~= "Sink" and modalBody and d:IsDescendantOf(modalBody) then
				local c = d.AbsolutePosition + d.AbsoluteSize / 2
				local lo, hi = visibleRect(d)
				if c.X > lo.X and c.Y > lo.Y and c.X < hi.X and c.Y < hi.Y then
					checkedButtons += 1
					local top = playerGui:GetGuiObjectsAtPosition(c.X, c.Y)[1]
					if top == nil or (top ~= d and not top:IsDescendantOf(d)) then
						table.insert(blocked, {
							case = caseName,
							button = (d:GetFullName():gsub("^.-PlayerGui%.", "")),
							top = if top then (top:GetFullName():gsub("^.-PlayerGui%.", "")) else "none",
						})
					end
				end
			end
		end
		if KEEP == name and KEEP_CASE == caseName then
			continue
		end
		root:unmount()
		gui:Destroy()
	end
	output[name] = {
		viewport = width .. "x" .. height,
		responsiveScale = Responsive.scale(width, height),
		labels = labels,
		modalButtonsChecked = checkedButtons,
		clipped = clipped,
		blocked = blocked,
		truncated = truncated,
	}
end
return HttpService:JSONEncode(output)
