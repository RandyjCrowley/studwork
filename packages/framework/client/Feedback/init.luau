--!strict
--[[
	Core.Client.Feedback. Public API: Types.FeedbackAPI
	(+ Feedback.onFeedbackEvent, Feedback.start(ctx)). See README.md.

	pop(text, position?, rarity?)  number pop with squash-and-stretch + float + fade.
	    position: UDim2 = screen pop there; Vector3 = world pop (BillboardGui on a pooled
	    Attachment); nil = screen pop near the upper centre, concurrent pops stack.
	    Colour: the theme tier colour, or theme colour "currency" when rarity is nil.
	flash(rarity)  full-screen glow in the rarity's glow colour, strength from glowStrength.
	sound(key)     theme.sounds[key] via pooled Sounds in SoundService; coin_tick pitch rises on rapid ticks.
	shake(intensity?)  camera shake layered on top of the default camera (RenderStep after
	    Camera priority), stacks up to Shake.MAX_INTENSITY. Big rewards (Legendary+) shake by default.
	Reduced motion: Player attribute "CoreReducedMotion" == true OR GuiService.ReducedMotionEnabled
	    -> no shake, no squash/float (fade only), flash at half strength.
	Limits: MAX_SCREEN_POPS / MAX_WORLD_POPS / SOUND_VOICES pooled instances; spam recycles the
	    oldest one, never creates more.
	Blink Feedback event: every message is forwarded to onFeedbackEvent handlers (kind, text,
	    rarity?). "item" and "pop" are rendered here; "toast" is left to the HUD.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local HandlerList = require(script.Parent.HandlerList)
local Types = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Types"))

local ClientTheme = require(script.Parent.Theme)

local PitchRamp = require(script.PitchRamp)
local Pool = require(script.Pool)
local PopAnim = require(script.PopAnim)
local Shake = require(script.Shake)

local MAX_SCREEN_POPS = 12
local MAX_WORLD_POPS = 16
local SCREEN_SLOTS = 6
local SOUND_VOICES = 4 -- per sound key
local POP_SIZE = Vector2.new(260, 44)
local WORLD_POP_SIZE = Vector2.new(200, 50)
local WORLD_RISE_STUDS = 3
local SCREEN_RISE_PX = 60
local FLASH_TIME = 0.35
local REDUCED_MOTION_ATTRIBUTE = "CoreReducedMotion"
local SHAKE_BIND_NAME = "CoreFeedbackShake"

local Feedback = {}

local feedbackHandlers = HandlerList.new()
local paletteOverrides: { [string]: string }? = nil
local SharedTheme = ClientTheme.shared

-- Theme reads (module-api.md §13): the client's merged theme; legacy GameConfig.palette on top.
local function themeColor(key: string): Color3
	if paletteOverrides and type(paletteOverrides[key]) == "string" then
		return Color3.fromHex(paletteOverrides[key])
	end
	return Color3.fromHex(ClientTheme.current().colors[key])
end

local function tierOf(rarity: any): any
	return SharedTheme.tier(ClientTheme.current(), rarity)
end

local function tierOrder(rarity: string): number
	return SharedTheme.tierOrder(ClientTheme.current())[rarity] or 0
end

local screen: ScreenGui? = nil
local worldFolder: Folder? = nil

type ScreenPop = { label: TextLabel, start: number, base: UDim2, slot: number }
type WorldPop = { gui: BillboardGui, label: TextLabel, attachment: Attachment, start: number }

local screenPool: any = nil
local worldPool: any = nil
local driver: RBXScriptConnection? = nil

local function reducedMotion(): boolean
	local player = Players.LocalPlayer
	if player and player:GetAttribute(REDUCED_MOTION_ATTRIBUTE) == true then
		return true
	end
	local ok, enabled = pcall(function()
		return (GuiService :: any).ReducedMotionEnabled
	end)
	return ok and enabled == true
end

local function getScreen(): ScreenGui
	if screen and screen.Parent then
		return screen
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "CoreFeedback"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	screen = gui
	return gui
end

local function getWorldFolder(): Folder
	if worldFolder and worldFolder.Parent then
		return worldFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "CoreFeedbackWorld"
	folder.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	worldFolder = folder
	return folder
end

local function displayFont(): Font
	return Font.new(ClientTheme.current().fonts.display, Enum.FontWeight.Bold)
end

local function makeLabel(): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.TextScaled = true
	label.FontFace = displayFont()
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Visible = false
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = ClientTheme.current().metrics.strokeThickness
	stroke.Color = themeColor("outline")
	stroke.Parent = label
	return label
end

local function popColor(rarity: Types.RarityTier?): Color3
	local tier = tierOf(rarity)
	if tier then
		return Color3.fromHex(tier.color)
	end
	return themeColor("currency")
end

local function applySample(label: TextLabel, sample: PopAnim.Sample, base: Vector2)
	label.Size = UDim2.fromOffset(base.X * sample.sx, base.Y * sample.sy)
	label.TextTransparency = sample.alpha
	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = sample.alpha
	end
end

local function step()
	local now = os.clock()
	local reduced = reducedMotion()
	for _, pop: ScreenPop in screenPool:active() do
		local t = now - pop.start
		if t >= PopAnim.DURATION then
			screenPool:release(pop)
		else
			local sample = PopAnim.sample(t, reduced)
			applySample(pop.label, sample, POP_SIZE)
			pop.label.Position = pop.base + UDim2.fromOffset(0, -SCREEN_RISE_PX * sample.rise)
		end
	end
	for _, pop: WorldPop in worldPool:active() do
		local t = now - pop.start
		if t >= PopAnim.DURATION then
			worldPool:release(pop)
		else
			local sample = PopAnim.sample(t, reduced)
			applySample(pop.label, sample, WORLD_POP_SIZE)
			pop.gui.StudsOffsetWorldSpace = Vector3.new(0, WORLD_RISE_STUDS * sample.rise, 0)
		end
	end
	if screenPool:activeCount() == 0 and worldPool:activeCount() == 0 and driver then
		driver:Disconnect()
		driver = nil
	end
end

local function ensureDriver()
	if driver == nil then
		driver = RunService.RenderStepped:Connect(step)
	end
end

local function initPools()
	if screenPool then
		return
	end
	screenPool = Pool.new(function(): ScreenPop
		local label = makeLabel()
		label.Parent = getScreen()
		return { label = label, start = 0, base = UDim2.new(), slot = 0 }
	end, function(pop: ScreenPop)
		pop.label.Visible = false
	end, MAX_SCREEN_POPS)

	worldPool = Pool.new(function(): WorldPop
		local attachment = Instance.new("Attachment")
		attachment.Name = "CoreFeedbackPop"
		attachment.Parent = Workspace.Terrain
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(WORLD_POP_SIZE.X * 1.4, WORLD_POP_SIZE.Y * 1.4)
		gui.AlwaysOnTop = true
		gui.LightInfluence = 0
		gui.MaxDistance = 250
		gui.ResetOnSpawn = false
		gui.Adornee = attachment
		gui.Enabled = false
		gui.Parent = getWorldFolder()
		local label = makeLabel()
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.Visible = true
		label.Parent = gui
		return { gui = gui, label = label, attachment = attachment, start = 0 }
	end, function(pop: WorldPop)
		pop.gui.Enabled = false
	end, MAX_WORLD_POPS)
end

function Feedback.pop(text: string, position: Vector3 | UDim2 | nil, rarity: Types.RarityTier?)
	if type(text) ~= "string" then
		return
	end
	initPools()
	local color = popColor(rarity)
	local now = os.clock()
	if typeof(position) == "Vector3" then
		local pop: WorldPop = worldPool:acquire()
		pop.attachment.WorldPosition = position :: Vector3
		pop.label.Text = text
		pop.label.TextColor3 = color
		pop.start = now
		applySample(pop.label, PopAnim.sample(0, reducedMotion()), WORLD_POP_SIZE)
		pop.gui.Enabled = true
	else
		local pop: ScreenPop = screenPool:acquire()
		local base: UDim2
		if typeof(position) == "UDim2" then
			base = position :: UDim2
			pop.slot = -1
		else
			local used: { [number]: boolean } = {}
			for _, other: ScreenPop in screenPool:active() do
				if other ~= pop and other.slot >= 0 then
					used[other.slot] = true
				end
			end
			pop.slot = PopAnim.freeSlot(used, SCREEN_SLOTS)
			base = UDim2.new(0.5, 0, 0.38, PopAnim.stackOffset(pop.slot))
		end
		pop.base = base
		pop.label.Text = text
		pop.label.TextColor3 = color
		pop.label.Position = base
		pop.start = now
		applySample(pop.label, PopAnim.sample(0, reducedMotion()), POP_SIZE)
		pop.label.Visible = true
	end
	ensureDriver()
end

-- flash ----------------------------------------------------------------------------------------

local flashFrame: Frame? = nil
local flashTween: Tween? = nil

function Feedback.flash(rarity: Types.RarityTier)
	local def = tierOf(rarity)
	if def == nil then
		return
	end
	local strength = 0.08 + 0.42 * def.glowStrength -- opacity at peak
	if reducedMotion() then
		strength *= 0.5
	end
	local frame = flashFrame
	if frame == nil or frame.Parent == nil then
		local newFrame = Instance.new("Frame")
		newFrame.Name = "Flash"
		newFrame.Size = UDim2.fromScale(1, 1)
		newFrame.BorderSizePixel = 0
		newFrame.ZIndex = 0
		newFrame.BackgroundTransparency = 1
		local gradient = Instance.new("UIGradient")
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.5, 0.6),
			NumberSequenceKeypoint.new(1, 0),
		})
		gradient.Parent = newFrame
		newFrame.Parent = getScreen()
		flashFrame = newFrame
		frame = newFrame
	end
	local f = frame :: Frame
	if flashTween then
		flashTween:Cancel()
	end
	f.BackgroundColor3 = Color3.fromHex(def.glow)
	f.BackgroundTransparency = 1 - strength
	local tween = TweenService:Create(
		f,
		TweenInfo.new(FLASH_TIME + def.glowStrength * 0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	flashTween = tween
	tween:Play()
end

-- sound ----------------------------------------------------------------------------------------

local soundFolder: Folder? = nil
local voices: { [string]: { list: { Sound }, next: number } } = {}
local coinRamp = PitchRamp.new()

local function getSoundFolder(): Folder
	if soundFolder and soundFolder.Parent then
		return soundFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "CoreFeedbackSounds"
	folder.Parent = SoundService
	soundFolder = folder
	return folder
end

function Feedback.sound(key: string)
	local entry = SharedTheme.sound(ClientTheme.current(), key)
	if entry == nil then
		return
	end
	local bank = voices[key]
	if bank == nil then
		bank = { list = {}, next = 1 }
		voices[key] = bank
	end
	local b = bank :: { list: { Sound }, next: number }
	local sound: Sound? = b.list[b.next]
	if sound == nil or sound.Parent == nil then
		local newSound = Instance.new("Sound")
		newSound.Name = key
		newSound.SoundId = "rbxassetid://" .. tostring(entry.id)
		newSound.Volume = entry.volume or 0.5
		newSound.Parent = getSoundFolder()
		b.list[b.next] = newSound
		sound = newSound
	end
	b.next = (b.next % SOUND_VOICES) + 1
	local s = sound :: Sound
	local pitch = entry.pitch or 1
	if key == "coin_tick" then
		pitch *= coinRamp:next(os.clock())
	end
	s.PlaybackSpeed = pitch
	s.TimePosition = 0
	s:Play()
end

-- shake ----------------------------------------------------------------------------------------

local shakeIntensity = 0
local shakeStart = 0
local shakeSeed = 0
local shakeBound = false

local function stopShake()
	if shakeBound then
		RunService:UnbindFromRenderStep(SHAKE_BIND_NAME)
		shakeBound = false
	end
	shakeIntensity = 0
end

local function shakeStep()
	local elapsed = os.clock() - shakeStart
	if elapsed >= Shake.DURATION or reducedMotion() then
		stopShake()
		return
	end
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local x, y, roll = Shake.offset(elapsed, Shake.DURATION, shakeIntensity, shakeSeed)
	-- runs after the default camera has written its CFrame this frame, so it never accumulates
	camera.CFrame = camera.CFrame * CFrame.new(x, y, 0) * CFrame.Angles(0, 0, roll)
end

function Feedback.shake(intensity: number?)
	local amount = if type(intensity) == "number" and intensity == intensity
		then intensity
		else Shake.DEFAULT_INTENSITY
	if amount <= 0 or reducedMotion() then
		return
	end
	local elapsed = os.clock() - shakeStart
	local remaining = if shakeBound and elapsed < Shake.DURATION
		then shakeIntensity * (1 - elapsed / Shake.DURATION)
		else 0
	shakeIntensity = Shake.combine(remaining, amount)
	shakeStart = os.clock()
	shakeSeed = (shakeSeed + 1) % 1000
	if not shakeBound then
		shakeBound = true
		RunService:BindToRenderStep(SHAKE_BIND_NAME, Enum.RenderPriority.Camera.Value + 1, shakeStep)
	end
end

-- events ---------------------------------------------------------------------------------------

function Feedback.onFeedbackEvent(
	handler: (kind: string, text: string, rarity: Types.RarityTier?) -> ()
): Types.Connection
	return feedbackHandlers:add(handler)
end

local function onMessage(message: any)
	if type(message) ~= "table" or type(message.Kind) ~= "string" or type(message.Text) ~= "string" then
		return
	end
	local kind: string = message.Kind
	local text: string = message.Text
	local rarity: Types.RarityTier? = if tierOf(message.Tier) then message.Tier else nil
	local position: Vector3? = if typeof(message.Position) == "Vector3" then message.Position else nil
	if kind == "item" then
		Feedback.pop(text, position, rarity)
		if rarity then
			Feedback.flash(rarity)
			local soundKey = tierOf(rarity).soundKey
			if type(soundKey) == "string" then
				Feedback.sound(soundKey)
			end
			local intensity = Shake.forRarity(tierOrder(rarity))
			if intensity then
				Feedback.shake(intensity)
			end
		end
	elseif kind == "pop" then
		Feedback.pop(text, position, rarity)
		Feedback.sound("coin_tick")
		if rarity then
			local intensity = Shake.forRarity(tierOrder(rarity))
			if intensity then
				Feedback.shake(intensity)
			end
		end
	end
	feedbackHandlers:fire(kind, text, rarity)
end

local started = false

function Feedback.start(ctx: any)
	if started then
		return
	end
	started = true
	if ctx and ctx.config and type(ctx.config.palette) == "table" then
		paletteOverrides = ctx.config.palette
	end
	ctx.net.Feedback.On(onMessage)
end

return Feedback
