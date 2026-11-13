--!strict
--[[
	Goals client part (docs/framework/kits/quests.md, Goals "Client part: the pill and the pointer").

	  StudWork.use(Goals).goal() -> GoalView?               from state (extra.goal)
	  StudWork.use(Goals).pointer() -> { position?, onScreen, distance?, from? }
	  StudWork.use(Goals).onChanged(fn(GoalView?)) -> () -> ()
	  StudWork.use(Goals).registerPicker(name, fn(character) -> (Vector3 | BasePart | Model)?)
	  StudWork.use(Goals).setHidden(hidden)                 fires skipGoals
	  StudWork.use(Goals).actions.skipGoals(hidden) / ackGoal(goalId)

	Parts: ./Pill.luau (HUD widget "Goals.goal", topCenter, order Pill.ORDER), ./Pointer.luau (the
	one world Beam), ./EdgeArrow.luau (the off-screen arrow), ./Resolve.luau (targets, tag cache,
	last known position, StreamingEnabled fallback).

	Never blocks, never forces: no screen is opened, the camera is only read
	(WorldToViewportPoint), GuiService.SelectedObject is never written, nothing sinks input. The
	pointer runs on Heartbeat but does work at most every `pointer.updateSeconds`.

	Engine access goes through one environment built in `start` (`defaultEnv`). Under Lune, where
	those services don't exist, `Goals._setEnv(env)` (specs only) injects fakes (also `env.state`
	and `env.subscribe` in place of StudWork.Client.state and Charm.subscribe); without one the
	pill still registers (when the UI kit loads) and the pointer stays off.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pill = require(script.Pill)
local Pointer = require(script.Pointer)
local EdgeArrow = require(script.EdgeArrow)
local Resolve = require(script.Resolve)

local clientCtx: any = nil -- { name, config, gameConfig } from the client runtime
local pickers: { [string]: (character: any) -> any } = {}
local injected: any = nil
local env: any = nil
local resolver: any = nil
local beam: any = nil
local arrow: any = nil
local current: any = nil -- the GoalView the pointer follows
local lastStep = -math.huge
local info: any = { position = nil, onScreen = false, distance = nil, from = nil }
local listeners: { [any]: boolean } = {}
local cleanups: { () -> () } = {}

local function studWork(): any
	return require(ReplicatedStorage:WaitForChild("Framework")) :: any
end

local function moduleRef(): any
	return require(script.Parent:WaitForChild("module")) :: any
end

local function pointerConfig(): any
	local cfg = clientCtx and clientCtx.config
	return (type(cfg) == "table" and cfg.pointer)
		or { beam = true, edgeArrow = true, updateSeconds = 0.1, nearStuds = 8, maxStuds = 2000 }
end

local function goalDef(id: string?): any
	local cfg = clientCtx and clientCtx.config
	if id == nil or type(cfg) ~= "table" or type(cfg.chain) ~= "table" then
		return nil
	end
	for _, goal in cfg.chain do
		if type(goal) == "table" and goal.id == id then
			return goal
		end
	end
	return nil
end

-- the raw replicated state (env.state in specs, else StudWork.Client.state())
local function rawState(): any
	if env and env.state then
		return env.state()
	end
	local ok, s = pcall(function(): any
		return studWork().Client.state()
	end)
	return if ok then s else nil
end

local function readView(): any
	return Pill.view(Pill.wireFrom(rawState()))
end

local function sameView(a: any, b: any): boolean
	if a == b then
		return true
	end
	if a == nil or b == nil then
		return false
	end
	return a.id == b.id
		and a.text == b.text
		and a.hidden == b.hidden
		and a.isNext == b.isNext
		and a.widget == b.widget
		and a.index == b.index
		and a.count == b.count
		and (
			a.target == b.target
			or (
				type(a.target) == "table"
				and type(b.target) == "table"
				and a.target.tag == b.target.tag
				and a.target.path == b.target.path
				and a.target.picker == b.target.picker
				and a.target.position == b.target.position
			)
		)
end

--------------------------------------------------------------------------------
-- The engine environment
--------------------------------------------------------------------------------

local function reducedMotionFrom(players: any, guiService: any): () -> boolean
	return function(): boolean
		local lp = players and players.LocalPlayer
		if lp and lp:GetAttribute("CoreReducedMotion") == true then
			return true
		end
		local ok, on = pcall(function(): any
			return guiService.ReducedMotionEnabled
		end)
		return ok and on == true
	end
end

local function themeColor(UI: any, key: string, fallbackKey: string): any
	local ok, c = pcall(UI.Theme.color, key)
	if ok then
		return c
	end
	return UI.Theme.color(fallbackKey)
end

-- Built in start on a real client; nil under Lune (the services aren't there).
local function defaultEnv(): any
	local ok, built = pcall(function(): any
		local Players = game:GetService("Players")
		local RunService = game:GetService("RunService")
		local CollectionService = game:GetService("CollectionService")
		local GuiService = game:GetService("GuiService")
		local Workspace = game:GetService("Workspace")
		local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
		local lp = Players.LocalPlayer
		if lp == nil then
			return nil
		end
		local gui: any = nil
		local function screenGui(): any
			if gui == nil then
				gui = Instance.new("ScreenGui")
				gui.Name = "GoalsPointer"
				gui.ResetOnSpawn = false
				gui.IgnoreGuiInset = false
				gui.DisplayOrder = 0
				gui.Parent = lp:WaitForChild("PlayerGui")
			end
			return gui
		end
		return {
			UI = UI,
			collection = CollectionService,
			root = game,
			now = os.clock,
			pickers = pickers,
			reducedMotion = reducedMotionFrom(Players, GuiService),
			heartbeat = function(fn: () -> ()): () -> ()
				local conn = RunService.Heartbeat:Connect(fn)
				return function()
					conn:Disconnect()
				end
			end,
			character = function(): (any, any)
				local character = lp.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if root == nil or not root:IsA("BasePart") then
					return nil, character
				end
				return (root :: BasePart).Position, character
			end,
			-- (viewport point relative to the arrow's ScreenGui, ScreenGui size); the camera is read only
			project = function(pos: Vector3): (any, any)
				local camera = Workspace.CurrentCamera
				if camera == nil then
					return nil, nil
				end
				local g = screenGui()
				local p = camera:WorldToViewportPoint(pos)
				local origin = g.AbsolutePosition
				return Vector3.new(p.X - origin.X, p.Y - origin.Y, p.Z), g.AbsoluteSize
			end,
			buildBeam = function(): any
				local terrain = Workspace.Terrain
				local from = Instance.new("Attachment")
				from.Name = "GoalsBeamFrom"
				from.Parent = terrain
				local to = Instance.new("Attachment")
				to.Name = "GoalsBeamTo"
				to.Parent = terrain
				local b = Instance.new("Beam")
				b.Name = "GoalsBeam"
				b.Attachment0 = from
				b.Attachment1 = to
				b.FaceCamera = true
				b.Segments = 1
				b.Width0 = 0.6
				b.Width1 = 0.6
				b.LightInfluence = 0
				b.Color = ColorSequence.new(themeColor(UI, "goalPointer", "accent"))
				b.Transparency = NumberSequence.new(0.2, 0.6)
				b.Enabled = false
				b.Parent = terrain
				return { beam = b, from = from, to = to }
			end,
			buildArrow = function(): any
				local label = Instance.new("ImageLabel")
				for key, value in EdgeArrow.PROPS do
					(label :: any)[key] = value
				end
				label.AnchorPoint = Vector2.new(0.5, 0.5)
				label.Size = UDim2.fromOffset(EdgeArrow.SIZE, EdgeArrow.SIZE)
				label.BackgroundColor3 = themeColor(UI, "goalPointer", "accent")
				local corner = Instance.new("UICorner")
				corner.CornerRadius = UDim.new(0.5, 0)
				corner.Parent = label
				local stroke = Instance.new("UIStroke")
				stroke.Color = UI.Theme.color("outline")
				stroke.Thickness = 2
				stroke.Parent = label
				local tip = Instance.new("Frame")
				tip.Name = "Tip"
				tip.Active = false
				tip.Selectable = false
				tip.AnchorPoint = Vector2.new(0.5, 0.5)
				tip.Position = UDim2.new(0.5, 0, 0, 0)
				tip.Size = UDim2.fromOffset(EdgeArrow.SIZE / 2, EdgeArrow.SIZE / 2)
				tip.Rotation = 45
				tip.BorderSizePixel = 0
				tip.BackgroundColor3 = label.BackgroundColor3
				tip.Parent = label
				label.Visible = false
				label.Parent = screenGui()
				return label
			end,
		}
	end)
	return if ok then built else nil
end

--------------------------------------------------------------------------------
-- The pointer step (Heartbeat; real work at most every updateSeconds)
--------------------------------------------------------------------------------

local function hideAll()
	if beam then
		beam:hide()
	end
	if arrow then
		arrow:hide()
	end
	info = { position = nil, onScreen = false, distance = nil, from = nil }
end

local function step()
	if env == nil then
		return
	end
	local cfg = pointerConfig()
	local now = env.now()
	if now - lastStep < cfg.updateSeconds then
		return
	end
	lastStep = now
	local view = current
	if view == nil or view.hidden then
		hideAll()
		return
	end
	local charPos, character = env.character()
	local def = if view.isNext then nil else goalDef(view.id)
	local key = view.id or ("next:" .. view.text)
	local pos, from = resolver:resolve(key, view.target, def and def.fallback, charPos, character)
	if pos == nil then
		hideAll()
		return
	end
	local distance = if charPos then Pointer.distance(charPos, pos) else nil
	local tooFar = distance ~= nil and distance > cfg.maxStuds
	beam:update(now, charPos, pos, not tooFar)
	local onScreen = false
	if env.project then
		local vp, size = env.project(pos)
		if vp ~= nil and size ~= nil then
			local placement = EdgeArrow.place(vp, size)
			onScreen = not placement.visible
			if cfg.edgeArrow ~= false and not tooFar then
				arrow:update(placement, env.reducedMotion and env.reducedMotion() or false)
			else
				arrow:hide()
			end
		end
	end
	info = { position = pos, onScreen = onScreen, distance = distance, from = from }
end

local function setCurrent(view: any)
	if sameView(view, current) then
		return
	end
	current = view
	lastStep = -math.huge -- the next frame updates at once
	for fn in table.clone(listeners) do
		task.spawn(fn, view)
	end
end

--------------------------------------------------------------------------------
-- Part
--------------------------------------------------------------------------------

local Goals = {}

Goals.WIDGET_ID = Pill.WIDGET_ID
Goals.widget = Pill.widget
Goals.actions = { "skipGoals", "ackGoal" }

-- specs only: the engine environment (see the header); nil restores the default
function Goals._setEnv(e: any)
	injected = e
end

-- specs only: run one pointer step now
function Goals._step()
	step()
end

function Goals.init(context: any)
	clientCtx = context
end

function Goals.start(_context: any)
	for _, fn in cleanups do
		fn()
	end
	table.clear(cleanups)
	current, lastStep = nil, -math.huge
	info = { position = nil, onScreen = false, distance = nil, from = nil }
	local UI = if injected then injected.UI else nil
	if UI == nil and injected == nil then
		local ok, loaded = pcall(function(): any
			return require(ReplicatedStorage:WaitForChild("UI"))
		end)
		UI = if ok then loaded else nil -- nil under Lune (the UI kit needs React)
	end
	if UI ~= nil then
		local _, removals = UI.widgets()
		if removals[Pill.WIDGET_ID] == nil then
			UI.registerWidget(Pill.WIDGET_ID, Pill.widget)
		end
	end
	env = injected or defaultEnv()
	if env == nil then
		return -- no engine (Lune without an injected env): no pointer
	end
	if env.pickers == nil then
		env.pickers = pickers
	end
	resolver = Resolve.new(env)
	beam = Pointer.new({ build = env.buildBeam }, pointerConfig())
	arrow = EdgeArrow.new({ build = env.buildArrow })
	table.insert(cleanups, function()
		resolver:destroy()
		beam:destroy()
		arrow:destroy()
	end)
	setCurrent(readView())
	local subscribe = env.subscribe
	if subscribe == nil then
		local Charm = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Charm")) :: any
		subscribe = Charm.subscribe
	end
	table.insert(cleanups, subscribe(readView, setCurrent))
	if env.heartbeat then
		table.insert(cleanups, env.heartbeat(step))
	end
end

Goals.api = {
	goal = function(): any
		return readView()
	end,
	pointer = function(): any
		return table.freeze(table.clone(info))
	end,
	onChanged = function(fn: (view: any) -> ()): () -> ()
		assert(type(fn) == "function", "Goals.onChanged(fn): fn must be a function")
		listeners[fn] = true
		return function()
			listeners[fn] = nil
		end
	end,
	registerPicker = function(name: string, fn: (character: any) -> any)
		assert(type(name) == "string" and name ~= "", "Goals.registerPicker(name, fn): name must be a string")
		assert(type(fn) == "function", "Goals.registerPicker(name, fn): fn must be a function")
		pickers[name] = fn
	end,
	setHidden = function(hidden: boolean)
		assert(type(hidden) == "boolean", "Goals.setHidden(hidden): hidden must be a boolean")
		studWork().use(moduleRef()).actions.skipGoals(hidden)
	end,
}

return Goals
