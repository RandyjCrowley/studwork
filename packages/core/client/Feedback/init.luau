--!strict
--[[
	Core.Client.Feedback. OWNED BY AGENT G (core/g-client). Public API: Types.FeedbackAPI.

	PHASE 0 STUB: pop() shows a short-lived TextLabel, flash() tints the screen in the rarity
	colour, sound() plays Sounds[key] if it has an id, shake() is a no-op. Listens to the Blink
	Feedback event and forwards it. Agent G: tweened number pops (world + screen), rarity glow,
	camera shake for big rewards, rising-pitch coin ticks, pooling, reduced-motion option.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local HandlerList = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("HandlerList"))
local RarityTiers = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("RarityTiers"))
local Sounds = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Sounds"))
local Types = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Types"))

local Feedback = {}

local feedbackHandlers = HandlerList.new()
local screen: ScreenGui? = nil

local function getScreen(): ScreenGui
	if screen and screen.Parent then
		return screen
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "CoreFeedback"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	screen = gui
	return gui
end

function Feedback.pop(text: string, position: Vector3 | UDim2 | nil, rarity: Types.RarityTier?)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromOffset(240, 40)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = if typeof(position) == "UDim2" then position else UDim2.fromScale(0.5, 0.4)
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = Color3.fromHex(RarityTiers.get(rarity or "Common").color)
	label.Parent = getScreen()
	task.delay(1.2, function()
		label:Destroy()
	end)
end

function Feedback.flash(rarity: Types.RarityTier)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromHex(RarityTiers.get(rarity).glow)
	frame.BackgroundTransparency = 0.7
	frame.BorderSizePixel = 0
	frame.Parent = getScreen()
	task.delay(0.25, function()
		frame:Destroy()
	end)
end

function Feedback.sound(key: string)
	local entry = Sounds[key]
	if entry == nil or entry.id == 0 then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = "rbxassetid://" .. tostring(entry.id)
	sound.Volume = entry.volume or 0.5
	sound.PlaybackSpeed = entry.pitch or 1
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
end

function Feedback.shake(_intensity: number?) end

function Feedback.onFeedbackEvent(
	handler: (kind: string, text: string, rarity: Types.RarityTier?) -> ()
): Types.Connection
	return feedbackHandlers:add(handler)
end

function Feedback.start(ctx: any)
	ctx.net.Feedback.On(function(message: any)
		local rarity = if RarityTiers.isTier(message.Rarity) then message.Rarity else nil
		if message.Kind == "pop" or message.Kind == "item" then
			Feedback.pop(message.Text, nil, rarity)
			if rarity then
				Feedback.flash(rarity)
				Feedback.sound(RarityTiers.get(rarity).soundKey)
			end
		end
		feedbackHandlers:fire(message.Kind, message.Text, rarity)
	end)
end

return Feedback
