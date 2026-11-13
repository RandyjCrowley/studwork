--!strict
--[[
	One quest row of the board (React). Loaded lazily by client/Board.luau. Every label is a string
	key through UI.text; colours, fonts and sizes come from the theme (text never below
	Theme.text.small, rows at least Theme.touchTarget tall, every button a UI.Button).

	props: view (State.View), env (client/init.luau: cfg, items, primaryCurrency), odds
	       ({ [tableId]: OddsDetail }), pinCount, pinMax, index (the row's order and its name, for
	       gamepad selection), onClaim(view), onReroll(view), onPin(view), onOdds(tableId)

	The Claim button sits in a Frame named "Claim<index>" so the board can select the first one
	when it was opened from a gamepad.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React")) :: any
local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
local State = require(script.Parent.State)

local e = React.createElement
local Theme = UI.Theme

local Row = {}

local MUTED = "textMuted" -- a theme colour key

-- Reduced motion: the framework's convention (Feedback): the CoreReducedMotion attribute or GuiService.
local function reducedMotion(): boolean
	local player = Players.LocalPlayer
	if player and player:GetAttribute("CoreReducedMotion") == true then
		return true
	end
	local ok, enabled = pcall(function()
		return (GuiService :: any).ReducedMotionEnabled
	end)
	return ok and enabled == true
end
Row.reducedMotion = reducedMotion

local function label(props: { [string]: any }): any
	return e("TextLabel", {
		BackgroundTransparency = 1,
		Size = props.size or UDim2.new(1, 0, 0, 0),
		AutomaticSize = props.automaticSize or Enum.AutomaticSize.Y,
		FontFace = Theme.font(props.font or "body"),
		TextSize = props.textSize or Theme.text.small,
		TextColor3 = Theme.color(props.color or "text"),
		TextWrapped = props.wrapped ~= false,
		TextXAlignment = props.align or Enum.TextXAlignment.Left,
		Text = props.text,
		LayoutOrder = props.layoutOrder,
	})
end
Row.label = label

-- A progress bar: the fill tweens to the new ratio, or jumps with reduced motion.
local function Bar(props: any): any
	local fill = React.useRef(nil :: Frame?)
	local ratio = math.clamp(props.ratio or 0, 0, 1)
	React.useEffect(function(): any
		local f = fill.current
		if f == nil then
			return nil
		end
		local goal = UDim2.fromScale(ratio, 1)
		if reducedMotion() then
			f.Size = goal
			return nil
		end
		local tween = TweenService:Create(f, TweenInfo.new(0.25, Enum.EasingStyle.Quad), { Size = goal })
		tween:Play()
		return function()
			tween:Cancel()
		end
	end, { ratio })
	return e("Frame", {
		BackgroundColor3 = Theme.color("surface"),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, props.height or 8),
		LayoutOrder = props.layoutOrder,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		Fill = e("Frame", {
			ref = fill,
			BackgroundColor3 = Theme.color(props.color or "accent"),
			BorderSizePixel = 0,
			Size = UDim2.fromScale(ratio, 1),
		}, { Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }) }),
	})
end
Row.Bar = Bar

local function transparentFrame(props: any, children: any): any
	return e("Frame", {
		BackgroundTransparency = 1,
		Size = props.size or UDim2.new(1, 0, 0, 0),
		AutomaticSize = props.automaticSize or Enum.AutomaticSize.Y,
		LayoutOrder = props.layoutOrder,
	}, children)
end

local function Objective(props: any): any
	local o = props.objective
	local key, args = State.objectiveLine(o)
	local name = UI.text(key, args)
	local progress = UI.text("Quests.progress", { value = o.value, target = o.target })
	return transparentFrame({ layoutOrder = props.layoutOrder }, {
		Layout = e("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
		Head = transparentFrame({ layoutOrder = 1 }, {
			Name = label({ text = name, color = MUTED, size = UDim2.new(0.7, 0, 0, 0), layoutOrder = 1 }),
			Value = label({
				layoutOrder = 2,
				text = progress,
				align = Enum.TextXAlignment.Right,
				size = UDim2.new(0.3, 0, 0, 0),
				font = "bold",
			}),
			Layout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		}),
		Bar = e(Bar, {
			ratio = if o.target > 0 then o.value / o.target else 0,
			color = if o.value >= o.target then "success" else "accent",
			layoutOrder = 2,
		}),
	})
end

local function Chip(props: any): any
	local reward = props.reward
	local key, args = State.rewardLine(reward, props.env)
	local text = UI.text(key, args)
	local children: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		}),
		Text = label({
			text = text,
			font = "bold",
			automaticSize = Enum.AutomaticSize.XY,
			size = UDim2.new(),
			wrapped = false, -- an auto-sized chip never wraps: it grows to its text (the Rewards row wraps chips)
			layoutOrder = 1,
		}),
	}
	if reward.kind == "roll" then
		children.Odds = e(UI.Button, {
			text = UI.text("Quests.odds"),
			variant = "secondary",
			layoutOrder = 2,
			onActivated = function()
				props.onOdds(reward.table)
			end,
		})
	end
	return e("Frame", {
		BackgroundColor3 = Theme.color("surface"),
		BackgroundTransparency = 0.2,
		Size = UDim2.new(),
		AutomaticSize = Enum.AutomaticSize.XY,
		LayoutOrder = props.layoutOrder,
	}, {
		Corner = e("UICorner", { CornerRadius = Theme.cornerRadius() }),
		Pad = e("UIPadding", {
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 8),
			PaddingTop = UDim.new(0, 4),
			PaddingBottom = UDim.new(0, 4),
		}),
		Content = e("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(),
			AutomaticSize = Enum.AutomaticSize.XY,
		}, children),
	})
end

function Row.Component(props: any): any
	local view = props.view
	-- subscribes the row to locale changes
	local claimText = UI.useText("Quests.claim")
	local statusKey: string? = nil
	if view.status == "claimed" then
		statusKey = if view.cap ~= nil and (view.claims or 0) >= view.cap
			then "Quests.capReached"
			else "Quests.claimed"
	elseif view.status == "locked" then
		statusKey = "Quests.locked"
	end
	local title = UI.text(view.title)

	local header: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 8),
		}),
		Title = label({
			text = title,
			font = "bold",
			textSize = Theme.text.body,
			size = UDim2.new(if statusKey then 0.7 else 1, 0, 0, 0),
			layoutOrder = 1,
		}),
	}
	if statusKey then
		header.Status = label({
			text = UI.text(statusKey),
			color = if statusKey == "Quests.claimed" then "success" else "textMuted",
			align = Enum.TextXAlignment.Right,
			size = UDim2.new(0.3, -8, 0, 0),
			layoutOrder = 2,
		})
	end

	local body: { [string]: any } = {
		Layout = e("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
		Pad = e("UIPadding", {
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 10),
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 8),
		}),
		Corner = e("UICorner", { CornerRadius = Theme.cornerRadius() }),
		MinHeight = e("UISizeConstraint", { MinSize = Vector2.new(0, Theme.touchTarget) }),
		Header = transparentFrame({ layoutOrder = 1 }, header),
	}

	if view.text then
		body.Text = label({ text = UI.text(view.text), color = MUTED, layoutOrder = 2 })
	end

	local objectives: { [string]: any } = {
		Layout = e("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	}
	for i, o in ipairs(view.objectives) do
		objectives[`O{i}`] = e(Objective, { objective = o, layoutOrder = i })
	end
	body.Objectives = transparentFrame({ layoutOrder = 3 }, objectives)

	if #view.reward > 0 then
		local chips: { [string]: any } = {
			Layout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
				Wraps = true,
			}),
		}
		for i, reward in ipairs(view.reward) do
			chips[`R{i}`] =
				e(Chip, { reward = reward, env = props.env, layoutOrder = i, onOdds = props.onOdds })
		end
		body.Rewards = transparentFrame({ layoutOrder = 4 }, chips)
	end

	local actions: { [string]: any } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Wraps = true,
		}),
	}
	local hasActions = false
	if view.status == "complete" then
		hasActions = true
		actions[`Claim{string.format("%04d", props.index)}`] = transparentFrame({
			layoutOrder = 1,
			size = UDim2.new(),
			automaticSize = Enum.AutomaticSize.XY,
		}, {
			Button = e(UI.Button, {
				text = claimText,
				variant = "primary",
				onActivated = function()
					props.onClaim(view)
				end,
			}),
		})
	end
	if view.status == "active" and view.slot ~= nil and (view.rerollsLeft or 0) > 0 and not view.waiting then
		hasActions = true
		actions.Reroll = e(UI.Button, {
			text = UI.text("Quests.reroll")
				.. " · "
				.. UI.text("Quests.rerollsLeft", { n = view.rerollsLeft }),
			variant = "secondary",
			layoutOrder = 2,
			onActivated = function()
				props.onReroll(view)
			end,
		})
	end
	if (view.status == "active" or view.status == "complete") and not view.waiting and props.pinMax > 0 then
		hasActions = true
		actions.Pin = e(UI.Button, {
			text = UI.text(if view.pinned then "Quests.unpin" else "Quests.pin"),
			variant = "secondary",
			disabled = not view.pinned and props.pinCount >= props.pinMax,
			layoutOrder = 3,
			onActivated = function()
				props.onPin(view)
			end,
		})
	end
	if hasActions then
		body.Actions = transparentFrame({ layoutOrder = 5 }, actions)
	end

	return e("Frame", {
		BackgroundColor3 = Theme.color("surfaceAlt"),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = props.index,
		Name = `Row{string.format("%04d", props.index)}`,
	}, body)
end

return Row
