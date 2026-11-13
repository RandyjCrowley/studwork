--!strict
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local State = require(script.Parent.State)
local Math = require(script.Parent.Parent.shared.FollowMath)
local Looks = require(script.Parent.Parent.shared.Looks)
local Visuals = require(script.Parent.Visuals)
local registry = Looks.new()
local low = false
local entries: { [string]: any } = {}
local stats = {
	drawn = 0,
	candidates = 0,
	culled = 0,
	parts = 0,
	estimatedTriangles = 0,
	unknownMeshParts = 0,
	lowDetail = false,
}
local function effectsOf(model: Instance): { any }
	local effects = {}
	for _, node in model:GetDescendants() do
		if
			node:IsA("ParticleEmitter")
			or node:IsA("Trail")
			or node:IsA("Beam")
			or node:IsA("Light")
			or node:IsA("Highlight")
			or node:IsA("Smoke")
			or node:IsA("Fire")
			or node:IsA("Sparkles")
		then
			local effect: any = node
			table.insert(effects, {
				node = effect,
				enabled = effect.Enabled,
				clear = node:IsA("ParticleEmitter") or node:IsA("Trail"),
			})
		end
	end
	return effects
end
local function setEffects(effects: { any }, disabled: boolean)
	for _, effect in effects do
		if effect.node.Parent ~= nil then
			effect.node.Enabled = if disabled then false else effect.enabled
			if disabled and effect.clear then
				effect.node:Clear()
			end
		end
	end
end
local Follow = {}
-- Selection is independent of rendering, so distant copies never allocate clones.
function Follow.select(candidates: { any }, maxDrawn: number): { any }
	table.sort(candidates, function(a, b)
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		if a.userId ~= b.userId then
			return a.userId < b.userId
		end
		return a.slot < b.slot
	end)
	local selected = {}
	for i = 1, math.min(maxDrawn, #candidates) do
		table.insert(selected, candidates[i])
	end
	return selected
end
local function destroy(entry: any)
	for _, track in entry.tracks do
		pcall(function()
			track:Stop()
			track:Destroy()
		end)
	end
	entry.model:Destroy()
end
local function clear()
	for key, entry in entries do
		destroy(entry)
		entries[key] = nil
	end
end
function Follow.init(_ctx: any) end
function Follow.start(ctx: any, injected: any?)
	local env = injected or {}
	local Players = env.players or Players
	local Storage = env.storage or RS
	local RunService = env.runService or game:GetService("RunService")
	local GuiService = env.guiService or game:GetService("GuiService")
	local stateOf = env.state or function()
		return require(RS:WaitForChild("Framework")).Client.state()
	end
	local Workspace = env.workspace or workspace
	local Instance = env.instance or Instance
	local CFrame = env.cframe or CFrame
	local Vector3 = env.vector3 or Vector3
	local RaycastParams = env.raycastParams or RaycastParams
	local Enum = env.enum or Enum
	local Visuals = env.visuals or Visuals

	local config = ctx.config
	local items: { [string]: any } = {}
	for _, def in ctx.gameConfig.items or {} do
		items[def.id] = def
	end
	local folder = Instance.new("Folder")
	folder.Name = "CompanionVisuals"
	folder.Parent = Workspace
	local elapsed, clock = 0, 0
	local excludes: { Instance } = { folder }
	RunService.Heartbeat:Connect(function(dt: number)
		clock += dt
		elapsed += dt
		local state = stateOf()
		if not State.enabled(state) then
			clear()
			stats.drawn = 0
			return
		end
		local reduced = Players.LocalPlayer:GetAttribute("CoreReducedMotion") == true
			or GuiService.ReducedMotionEnabled
		if elapsed >= 1 / config.selectionHz then
			elapsed = 0
			excludes = { folder }
			for _, player in Players:GetPlayers() do
				if player.Character then
					table.insert(excludes, player.Character)
				end
			end
			local candidates = {}
			local camera = Workspace.CurrentCamera
			if camera then
				for _, owner in State.roster(state) do
					local player = Players:GetPlayerByUserId(owner.userId)
					local character = if player then player.Character else nil
					local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
					if root and root:IsA("BasePart") then
						local distance = (root.Position - camera.CFrame.Position).Magnitude
						if distance <= config.drawDistance then
							for slot, copy in owner.equipped do
								if items[copy.itemId] then
									table.insert(candidates, {
										key = tostring(owner.userId) .. ":" .. copy.uid,
										userId = owner.userId,
										slot = slot,
										count = #owner.equipped,
										copy = copy,
										root = root,
										distance = distance,
									})
								end
							end
						end
					end
				end
			end
			stats.candidates = #candidates
			local selected = Follow.select(candidates, config.maxDrawn)
			stats.culled = #candidates - #selected
			local keep = {}
			for _, candidate in selected do
				keep[candidate.key] = true
			end
			-- Retire the prior selection before allocating any replacement geometry.
			for key, entry in entries do
				if not keep[key] then
					destroy(entry)
					entries[key] = nil
				end
			end
			for _, candidate in selected do
				local key = candidate.key
				local def = items[candidate.copy.itemId]
				local assets = Storage:FindFirstChild(config.assetsFolderName)
				local template = if assets and def.model then assets:FindFirstChild(def.model) else nil
				local signature = candidate.copy.itemId .. ":" .. (candidate.copy.mutation or "")
				local entry = entries[key]
				if
					entry
					and (
						entry.version ~= registry.version()
						or entry.template ~= template
						or entry.signature ~= signature
					)
				then
					destroy(entry)
					entries[key] = nil
					entry = nil
				end
				if not entry then
					local model: any = if template
							and (template:IsA("Model") or template:IsA("BasePart"))
						then template:Clone()
						else Visuals.placeholder()
					Visuals.sanitize(model, true)
					local _, originalTriangles = Visuals.stats(model)
					local destroyed = false
					local connection = model.Destroying:Connect(function()
						destroyed = true
					end)
					registry.applyLook(model, def, candidate.copy.mutation)
					connection:Disconnect()
					local ok, valid = pcall(Visuals.sanitize, model, true)
					if destroyed or not ok or not valid then
						model:Destroy()
						model = Visuals.placeholder()
					end
					local effects = effectsOf(model)
					setEffects(effects, low)
					model.Parent = folder
					local tracks = {}
					local animator = model:FindFirstChildWhichIsA("Animator", true)
					if animator then
						for _, animation in model:GetDescendants() do
							if animation:IsA("Animation") then
								local loaded, track = pcall(function()
									return animator:LoadAnimation(animation)
								end)
								if loaded then
									tracks[animation.Name] = track
								end
							end
						end
					end
					local parts, triangles, unknown = Visuals.stats(model)
					if template and def.companions and def.companions.triangles then
						triangles = def.companions.triangles + math.max(0, triangles - originalTriangles)
					end
					entry = {
						effects = effects,
						parts = parts,
						triangles = triangles,
						unknown = unknown,
						model = model,
						template = template,
						signature = signature,
						version = registry.version(),
						tracks = tracks,
						elapsed = 0,
						first = true,
					}
					entries[key] = entry
				end
				entry.candidate = candidate
			end
		end
		stats.drawn, stats.parts, stats.estimatedTriangles, stats.unknownMeshParts = 0, 0, 0, 0
		stats.lowDetail = low
		for _, entry in entries do
			local c = entry.candidate
			local root = c.root
			if root.Parent == nil then
				continue
			end
			stats.drawn += 1
			stats.parts += entry.parts
			stats.estimatedTriangles += entry.triangles
			stats.unknownMeshParts += entry.unknown
			entry.elapsed += dt
			if entry.elapsed < 1 / Math.rate(c.distance, config, low) then
				continue
			end
			local step = entry.elapsed
			entry.elapsed = 0
			local def = items[c.copy.itemId]
			local fields = def.companions or {}
			local movement = fields.movement or "walk"
			local target = root.CFrame
				* CFrame.new(Math.formation(c.slot, c.count, config.spacing, config.behind))
			local position = target.Position
			if movement == "walk" or movement == "hop" then
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				params.FilterDescendantsInstances = excludes
				params.RespectCanCollide = true
				local hit = Workspace:Raycast(
					position + Vector3.yAxis * config.groundProbeUp,
					-Vector3.yAxis * (config.groundProbeUp + config.groundProbeDown),
					params
				)
				local humanoid = root.Parent:FindFirstChildWhichIsA("Humanoid")
				local ground = if hit
					then hit.Position.Y
					else root.Position.Y - root.Size.Y / 2 - (if humanoid then humanoid.HipHeight else 0)
				local center, height = Visuals.bounds(entry.model)
				position = Vector3.new(position.X, Math.ground(ground, center, height), position.Z)
			else
				position += Vector3.yAxis * (fields.hoverHeight or config.hoverHeight)
			end
			local speed = root.AssemblyLinearVelocity.Magnitude
			position += Math.motion(
				movement,
				clock,
				speed,
				config.idleSpeed,
				reduced,
				low,
				config.bobHeight,
				config.bobHz,
				config.hopHeight
			)
			local goal = CFrame.new(position) * target.Rotation
			local current = entry.model:GetPivot()
			local snap = entry.first
				or entry.root ~= root
				or Math.snap(current.Position, position, config.teleportDistance)
			entry.model:PivotTo(
				if snap then goal else current:Lerp(goal, Math.alpha(step, config.followSpeed))
			)
			entry.first = false
			entry.root = root
			local animation = if reduced or low
				then ""
				elseif speed > config.idleSpeed then fields.moveAnimation or "Move"
				else fields.idleAnimation or "Idle"
			if entry.animation ~= animation then
				for name, track in entry.tracks do
					if name == animation then
						track:Play()
					else
						track:Stop()
					end
				end
				entry.animation = animation
			end
		end
	end)
end
Follow.api = {
	setLowDetail = function(enabled: boolean)
		local nextLow = enabled == true
		if low == nextLow then
			return
		end
		low = nextLow
		for _, entry in entries do
			setEffects(entry.effects, low)
		end
	end,
	lowDetail = function(): boolean
		return low
	end,
	debugStats = function()
		return table.clone(stats)
	end,
	registerLook = registry.registerLook,
	applyLook = registry.applyLook,
}
return Follow
