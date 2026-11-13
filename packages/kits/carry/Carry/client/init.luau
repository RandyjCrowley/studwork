--!strict
--[[
	Carry client part (docs/framework/kits/carry.md, "Client"). The server decides everything; this part
	sends requests (object ids only), shows state and renders cosmetics that never replicate.

	  actions: carryPickUp(objectId), carryDrop(objectId), carryHandOff(objectId, toUserId)
	           (this module's own Blink events, ./Net.luau)
	  api (StudWork.use(Carry)):
	    carrying() -> objectId?             the local player's held object id
	    stateOf(objectId) -> (state, { userId })?   decoded from state.modules.Carry.extra
	    onWobble(fn(objectId, angleDeg, phase)) -> Connection   the computed sway, for a game's own visuals
	    setControls(enabled)                bind / unbind interact + pass, show / hide the widget

	  bindings (StudWork.Client.Input.bind, touchButton = true, so key + gamepad + on-screen button):
	    "Carry.interact"  E / ButtonX: pick up / help carry the nearest carriable in reach; drop what is held
	    "Carry.pass"      F / ButtonY: only while the sole holder of a min == 1 object; hands it to the
	                      nearest present player within throwRange in the camera's forward 90 degree cone
	                      (else the nearest overall), highlighted with a client-only Highlight
	  widget "Carry.status" (slot "bottom", order 1): a small chip while carrying
	  wobble: a damped spring on the carried object's OBSERVED acceleration, applied as a local visual
	          offset; nothing wobble-related is sent per tick

	Streaming: a streamed-out object is tolerated (nothing to read, wobble skips it); carrying() and the
	widget come from the replicated state, which is independent of streaming.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = script.Parent:WaitForChild("shared")
local Box = require(Shared:WaitForChild("Box"))
local CF = require(Shared:WaitForChild("CF"))
local State = require(script.State)
local Wobble = require(script.Wobble)

local WIDGET_ID = "Carry.status"
local REFRESH_SECONDS = 0.15
local PASS_CONE_DOT = 0.7071 -- cos 45 degrees: the camera's forward 90 degree cone
local WIDGET_MIN_WIDTH = 120
local WIDGET_MAX_WIDTH = 320
local WIDGET_WIDTH_FRACTION = 0.5

local function studWork(): any
	return require(ReplicatedStorage:WaitForChild("Framework")) :: any
end

local function ui(): any
	return require(ReplicatedStorage:WaitForChild("UI")) :: any
end

local function ref(): any
	return require(script.Parent:WaitForChild("module")) :: any
end

local config: any = nil
local controls = true
local started = false

local function rawState(): any
	return studWork().Client.state()
end

local function localUserId(): number
	local Players = game:GetService("Players")
	return Players.LocalPlayer.UserId
end

-- API ---------------------------------------------------------------------------------------------------

local wobbleListeners: { (string, number, number) -> () } = {}

local api: any = {}

function api.carrying(): string?
	local id = State.carrying(rawState(), localUserId())
	return id
end

function api.stateOf(objectId: string): (string?, { number }?)
	return State.stateOf(rawState(), objectId)
end

function api.onWobble(fn: (string, number, number) -> ()): any
	assert(type(fn) == "function", "Carry.onWobble: fn must be a function")
	table.insert(wobbleListeners, fn)
	local connection = { Connected = true }
	function connection.Disconnect(self: any)
		if self.Connected then
			self.Connected = false
			local at = table.find(wobbleListeners, fn)
			if at then
				table.remove(wobbleListeners, at)
			end
		end
	end
	return connection
end

-- bindings: interact + pass ---------------------------------------------------------------------------------

local boundInteract: string? = nil -- the title key currently bound, so a re-bind happens only on change
local boundPass = false
local passTarget: any = nil
local highlight: any = nil

local function keyCodes(names: { string }): { any }
	local out: { any } = {}
	for _, name in names do
		local code = (Enum :: any).KeyCode[name]
		if code ~= nil then
			table.insert(out, code)
		end
	end
	return out
end

local function carriableDef(tag: string): any
	return config.carriables[tag]
end

-- the nearest carriable instance within reach of the local character (a cosmetic local read)
local function nearestCarriable(): (any, string?)
	local Players = game:GetService("Players")
	local CollectionService = game:GetService("CollectionService")
	local character = Players.LocalPlayer.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil then
		return nil, nil
	end
	local rootPos = CF.fromCFrame(root.CFrame).p
	local state = rawState()
	local best, bestId, bestDist = nil, nil, math.huge
	for tag, def in config.carriables do
		local reach = def.pickUpRadius or config.pickUpRadius
		for _, inst in CollectionService:GetTagged(tag) do
			local id = inst:GetAttribute("CarryObjectId")
			if type(id) == "string" then
				local info = State.info(state, id)
				local st = if info then info.state else "idle"
				local max = if def.carriers then def.carriers.max else 1
				local full = info ~= nil and #info.carriers >= max
				if st ~= "delivered" and st ~= "thrown" and not full then
					local cf, size
					if inst:IsA("Model") then
						local bcf, bsize = inst:GetBoundingBox()
						cf, size = CF.fromCFrame(bcf), bsize
					elseif inst:IsA("BasePart") then
						cf, size = CF.fromCFrame(inst.CFrame), inst.Size
					end
					if cf ~= nil then
						local d = Box.distance(cf, vector.create(size.X, size.Y, size.Z), rootPos)
						if d <= reach and d < bestDist then
							best, bestId, bestDist = inst, id, d
						end
					end
				end
			end
		end
	end
	return best, bestId
end

local function clearHighlight()
	if highlight ~= nil then
		highlight:Destroy()
		highlight = nil
	end
	passTarget = nil
end

local function setHighlight(player: any)
	if passTarget == player then
		return
	end
	clearHighlight()
	local character = if player then player.Character else nil
	if character ~= nil then
		local h = Instance.new("Highlight")
		h.Name = "CarryPassTarget"
		h.Adornee = character
		h.FillTransparency = 1
		h.Parent = character
		highlight = h
		passTarget = player
	end
end

-- the nearest present player within throwRange in the camera's forward cone, else the nearest overall
local function choosePassTarget(): any
	local Players = game:GetService("Players")
	local me = Players.LocalPlayer
	local character = me.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil then
		return nil
	end
	local camera = (game:GetService("Workspace") :: any).CurrentCamera
	local look = if camera then camera.CFrame.LookVector else root.CFrame.LookVector
	local here = root.Position
	local bestCone, bestConeD, bestAny, bestAnyD = nil, math.huge, nil, math.huge
	for _, other in Players:GetPlayers() do
		local oc = if other ~= me then other.Character else nil
		local orp = if oc then oc:FindFirstChild("HumanoidRootPart") else nil
		if orp ~= nil then
			local offset = orp.Position - here
			local d = offset.Magnitude
			if d <= config.throwRange and d > 0 then
				if d < bestAnyD then
					bestAny, bestAnyD = other, d
				end
				if look:Dot(offset.Unit) >= PASS_CONE_DOT and d < bestConeD then
					bestCone, bestConeD = other, d
				end
			end
		end
	end
	return bestCone or bestAny
end

local function act(action: string, ...: any)
	task.spawn(function(...)
		studWork().use(ref()).actions[action](...)
	end, ...)
end

local function bindInteract(titleKey: string?, handler: (() -> ())?)
	local Input = studWork().Client.Input
	if titleKey == nil or handler == nil then
		if boundInteract ~= nil then
			Input.unbind("Carry.interact")
			boundInteract = nil
		end
		return
	end
	if boundInteract == titleKey then
		return
	end
	boundInteract = titleKey
	local UI = ui()
	local title = if titleKey == "drop"
		then UI.text("Carry.drop")
		elseif titleKey == "join" then UI.text("Carry.join")
		else UI.text("Carry.pickUp")
	Input.bind("Carry.interact", {
		keys = keyCodes(config.bindings.interact.keys),
		gamepad = keyCodes(config.bindings.interact.gamepad),
		touchButton = true,
		title = title,
	}, function(state: string)
		if state == "Began" and handler ~= nil then
			handler()
		end
	end)
end

local currentInteract: (() -> ())? = nil

local function refreshBindings()
	if not controls then
		bindInteract(nil, nil)
		if boundPass then
			studWork().Client.Input.unbind("Carry.pass")
			boundPass = false
		end
		clearHighlight()
		return
	end
	local state = rawState()
	local held, info = State.carrying(state, localUserId())
	if held ~= nil then
		currentInteract = function()
			local id = api.carrying()
			if id ~= nil then
				act("carryDrop", id)
			end
		end
		bindInteract("drop", function()
			if currentInteract then
				currentInteract()
			end
		end)
	else
		local _, id = nearestCarriable()
		if id ~= nil then
			local theirs = State.info(state, id)
			local joining = theirs ~= nil and (theirs.state == "gathering" or theirs.state == "carried")
			currentInteract = function()
				act("carryPickUp", id)
			end
			bindInteract(if joining then "join" else "pickUp", function()
				if currentInteract then
					currentInteract()
				end
			end)
		else
			currentInteract = nil
			bindInteract(nil, nil)
		end
	end

	-- pass: only the sole holder of a min == 1 object
	local def = if info then carriableDef(info.tag) else nil
	local canPass = info ~= nil
		and def ~= nil
		and info.state == "carried"
		and #info.carriers == 1
		and (if def.carriers then def.carriers.min else 1) == 1
	if canPass then
		setHighlight(choosePassTarget())
		if not boundPass then
			boundPass = true
			local UI = ui()
			studWork().Client.Input.bind("Carry.pass", {
				keys = keyCodes(config.bindings.pass.keys),
				gamepad = keyCodes(config.bindings.pass.gamepad),
				touchButton = true,
				title = UI.text("Carry.pass"),
			}, function(s: string)
				if s == "Began" and passTarget ~= nil then
					local id = api.carrying()
					if id ~= nil then
						act("carryHandOff", id, passTarget.UserId)
					end
				end
			end)
		end
	else
		clearHighlight()
		if boundPass then
			studWork().Client.Input.unbind("Carry.pass")
			boundPass = false
		end
	end
end

function api.setControls(enabled: boolean)
	controls = enabled == true
	if started then
		refreshBindings()
	end
end

-- wobble ---------------------------------------------------------------------------------------------------------------

local wobbles: { [string]: any } = {}

local function stepWobble(dt: number)
	local cfg = config.wobble
	if not cfg.enabled then
		return
	end
	local CollectionService = game:GetService("CollectionService")
	local state = rawState()
	for _, id in State.ids(state) do
		local info = State.info(state, id)
		if info ~= nil and info.state == "carried" then
			-- find the streamed-in instance (tolerate one that is streamed out)
			local inst = nil
			for _, candidate in CollectionService:GetTagged(info.tag) do
				if candidate:GetAttribute("CarryObjectId") == id then
					inst = candidate
					break
				end
			end
			local part = if inst == nil
				then nil
				elseif inst:IsA("Model") then inst.PrimaryPart
				elseif inst:IsA("BasePart") then inst
				else nil
			if part ~= nil then
				local w = wobbles[id]
				if w == nil then
					w = {
						spring = Wobble.new(cfg, info.wobbleSeed),
						lastP = nil,
						lastV = nil,
						base = nil,
						written = nil,
					}
					wobbles[id] = w
				end
				-- the replicated CFrame is the base; our own last write is not a new observation
				local cf = part.CFrame
				if w.written == nil or cf ~= w.written then
					w.base = cf
				end
				local base = w.base
				local v = if w.lastP then (base.Position - w.lastP) / dt else Vector3.zero
				local accel = if w.lastV then (v - w.lastV) / dt else Vector3.zero
				w.lastP, w.lastV = base.Position, v
				local lateral = accel:Dot(base.RightVector)
				local angle, phase = Wobble.step(w.spring, lateral, dt)
				for _, fn in table.clone(wobbleListeners) do
					fn(id, angle, phase)
				end
				if inst:IsA("BasePart") then
					local rolled = base * CFrame.Angles(0, 0, math.rad(angle))
					part.CFrame = rolled
					w.written = rolled
				end
			end
		elseif wobbles[id] ~= nil then
			wobbles[id] = nil
		end
	end
end

-- widget ---------------------------------------------------------------------------------------------------------------

local function StatusWidget(props: any)
	local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React")) :: any
	local UI = ui()
	local id, info = State.carrying(props.state, localUserId())
	local viewport, setViewport = React.useState(function(): number
		local camera = (game:GetService("Workspace") :: any).CurrentCamera
		return if camera then camera.ViewportSize.X else 800
	end)
	React.useEffect(function(): (() -> ())?
		local camera = (game:GetService("Workspace") :: any).CurrentCamera
		if camera == nil then
			return nil
		end
		local connection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			setViewport(camera.ViewportSize.X)
		end)
		return function()
			connection:Disconnect()
		end
	end, {})
	if id == nil or info == nil then
		return nil
	end
	local def = carriableDef(info.tag)
	local min = if def and def.carriers then def.carriers.min else 1
	local max = if def and def.carriers then def.carriers.max else 1
	local count = #info.carriers
	local e = React.createElement
	local lines: { any } = {
		e("TextLabel", {
			Text = UI.text("Carry.carrying", { name = info.tag }),
			FontFace = UI.Theme.font("bold"),
			TextSize = UI.Theme.text.body,
			TextColor3 = UI.Theme.color("text"),
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, UI.Theme.text.body + 4),
			TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = 1,
		}),
	}
	if max > 1 then
		local text = if info.state == "gathering"
			then UI.text("Carry.needMore", { count = min - count })
			else UI.text("Carry.slots", { count = count, max = max })
		table.insert(
			lines,
			e("TextLabel", {
				Text = text,
				FontFace = UI.Theme.font("body"),
				TextSize = UI.Theme.text.small,
				TextColor3 = UI.Theme.color("textMuted"),
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, UI.Theme.text.small + 4),
				LayoutOrder = 2,
			})
		)
	end
	local width = math.clamp(viewport * WIDGET_WIDTH_FRACTION, WIDGET_MIN_WIDTH, WIDGET_MAX_WIDTH)
	return e("Frame", {
		BackgroundColor3 = UI.Theme.color("surface"),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = props.layoutOrder,
	}, {
		Corner = e("UICorner", { CornerRadius = UDim.new(0, 10) }),
		Padding = UI.Primitives.padding(8),
		Layout = UI.Primitives.list(Enum.FillDirection.Vertical, 2),
		Lines = React.createElement(React.Fragment, nil, lines),
	})
end

-- the module ---------------------------------------------------------------------------------------------------------

local Carry = {}

Carry.WIDGET_ID = WIDGET_ID
Carry.widget = table.freeze({ slot = "bottom", order = 1, module = "Carry", component = StatusWidget })
Carry.actions = { carryPickUp = true, carryDrop = true, carryHandOff = true }
Carry.api = api

function Carry.init(ctx: any)
	config = ctx.config
end

function Carry.start(_ctx: any)
	started = true
	local UI = ui()
	local _, removals = UI.widgets()
	if removals[WIDGET_ID] == nil then
		UI.registerWidget(WIDGET_ID, Carry.widget)
	end
	local RunService = game:GetService("RunService")
	local sinceRefresh = 0
	RunService.RenderStepped:Connect(function(dt: number)
		stepWobble(dt)
		sinceRefresh += dt
		if sinceRefresh >= REFRESH_SECONDS then
			sinceRefresh = 0
			refreshBindings()
		end
	end)
end

return Carry
