--!strict
local Follow = require(game:GetService("ReplicatedStorage").Modules.Companions.client.Follow)
describe("Companion selection", function()
	it("bounds 150 candidates to nearest thirty with deterministic ties", function()
		local candidates = {}
		for owner = 50, 1, -1 do
			for slot = 3, 1, -1 do
				table.insert(candidates, { distance = owner, userId = owner, slot = slot })
			end
		end
		local selected = Follow.select(candidates, 30)
		expect(#selected).toBe(30)
		expect(selected[1].userId).toBe(1)
		expect(selected[1].slot).toBe(1)
		expect(selected[30].userId).toBe(10)
		expect(#Follow.select(candidates, 0)).toBe(0)
	end)
	it("exposes dynamic low detail settings", function()
		Follow.api.setLowDetail(true)
		expect(Follow.api.lowDetail()).toBe(true)
		Follow.api.setLowDetail(false)
		expect(Follow.api.lowDetail()).toBe(false)
	end)
end)

-- Small value/service fakes exercise the real single-loop lifecycle. Engine safety is
-- covered separately; no fake property here is written by production code.
local function vector(x: number, y: number, z: number): any
	local result: any = { X = x, Y = y, Z = z, Magnitude = math.sqrt(x * x + y * y + z * z) }
	return setmetatable(result, {
		__add = function(a: any, b: any)
			return vector(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
		end,
		__sub = function(a: any, b: any)
			return vector(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
		end,
		__unm = function(a: any)
			return vector(-a.X, -a.Y, -a.Z)
		end,
		__mul = function(a: any, b: number)
			return vector(a.X * b, a.Y * b, a.Z * b)
		end,
	})
end
local function frame(position: any): any
	local result: any = { Position = position }
	result.Rotation = { rotation = true }
	function result:Lerp(target: any, alpha: number)
		return frame(self.Position + (target.Position - self.Position) * alpha)
	end
	return setmetatable(result, {
		__mul = function(a: any, b: any)
			return frame(if b.rotation then a.Position else a.Position + b.Position)
		end,
	})
end
local function runtime()
	local heartbeat: any
	local state: any = { modules = { Companions = { extra = { enabled = true, roster = {} } } } }
	local clones, destroyed, rays = 0, 0, 0
	local live, peak = 0, 0
	local tracks = { plays = 0, stops = 0, destroys = 0, ancestryFailures = 0 }
	local effectNodes: { any } = {}
	local scans = 0
	local root: any = {
		Parent = {},
		Position = vector(0, 4, 0),
		Size = vector(2, 2, 2),
		AssemblyLinearVelocity = vector(0, 0, 0),
	}
	root.CFrame = frame(root.Position)
	function root:IsA(name: string)
		return name == "BasePart"
	end
	function root.Parent:FindFirstChildWhichIsA(_name: string)
		return nil
	end
	local character: any = {}
	function character:FindFirstChild(_name: string)
		return root
	end
	local player: any = { Character = character }
	local reduced = false
	local gui: any = { ReducedMotionEnabled = false }
	local localPlayer: any = {}
	function localPlayer:GetAttribute(_name: string)
		return reduced
	end
	local players: any = { LocalPlayer = localPlayer }
	function players:GetPlayerByUserId(_id: number)
		return player
	end
	function players:GetPlayers()
		return { player }
	end
	local camera: any = { CFrame = frame(vector(0, 0, 0)) }
	local world: any = { CurrentCamera = camera }
	function world:Raycast(_a: any, _b: any, _params: any)
		rays += 1
		return nil
	end
	local storage: any = {}
	function storage:FindFirstChild(_name: string)
		return nil
	end
	local visuals: any = {}
	function visuals.placeholder()
		clones += 1
		live += 1
		peak = math.max(peak, live)
		local pivot = frame(vector(0, 0, 0))
		local model: any = {
			Parent = nil,
			Destroying = {
				Connect = function(_self: any, _fn: any)
					return { Disconnect = function() end }
				end,
			},
		}
		function model:FindFirstChildWhichIsA(_name: string, _recursive: boolean)
			return {
				LoadAnimation = function(_self: any, _animation: any)
					if not model.Parent or model.Parent.Parent ~= world then
						tracks.ancestryFailures += 1
						error("Animator must be in Workspace")
					end
					return {
						Play = function()
							tracks.plays += 1
						end,
						Stop = function()
							tracks.stops += 1
						end,
						Destroy = function()
							tracks.destroys += 1
						end,
					}
				end,
			}
		end
		function model:GetDescendants()
			scans += 1
			local descendants: { any } = {
				{
					Name = "Idle",
					IsA = function(_self: any, name: string)
						return name == "Animation"
					end,
				},
			}
			for _, effect in model.effects or {} do
				table.insert(descendants, effect)
			end
			return descendants
		end
		function model:Destroy()
			destroyed += 1
			live -= 1
			self.Parent = nil
		end
		function model:GetPivot()
			return pivot
		end
		function model:PivotTo(value: any)
			pivot = value
		end
		model.effects = {}
		for index, class in
			{ "ParticleEmitter", "Trail", "Beam", "PointLight", "Highlight", "ParticleEmitter" }
		do
			local effect: any = { Parent = model, Enabled = index ~= 6, clears = 0 }
			function effect:IsA(name: string): boolean
				return name == class or name == "Light" and class == "PointLight"
			end
			function effect:Clear()
				self.clears += 1
			end
			table.insert(model.effects, effect)
		end
		effectNodes = model.effects
		return model
	end
	function visuals.sanitize(_model: any, _rig: boolean)
		return true
	end
	function visuals.bounds(_model: any)
		return 3, 4
	end
	function visuals.stats(_model: any)
		return 1, 12, 0
	end
	local env: any = {
		players = players,
		storage = storage,
		workspace = world,
		visuals = visuals,
		state = function()
			return state
		end,
		guiService = gui,
		runService = {
			Heartbeat = {
				Connect = function(_self: any, fn: any)
					heartbeat = fn
				end,
			},
		},
		instance = {
			new = function(_name: string)
				return {}
			end,
		},
		vector3 = { yAxis = vector(0, 1, 0), new = vector },
		cframe = {
			new = function(a: any, b: number?, c: number?)
				return frame(if type(a) == "number" then vector(a, b or 0, c or 0) else vector(a.X, a.Y, a.Z))
			end,
		},
		raycastParams = {
			new = function()
				return {}
			end,
		},
		enum = { RaycastFilterType = { Exclude = "Exclude" } },
	}
	local config =
		table.clone(require(game:GetService("ReplicatedStorage").Modules.Companions.shared.Config).defaults)
	Follow.start({ config = config, gameConfig = { items = { { id = "walker", companions = {} } } } }, env)
	return {
		roster = function(present: boolean)
			state.modules.Companions.extra.roster = if present
				then {
					one = {
						userId = 1,
						equipped = { { uid = "a", itemId = "walker", mutation = "late-loop" } },
					},
				}
				else {}
		end,
		tick = function(dt: number)
			heartbeat(dt)
		end,
		hide = function()
			player.Character = nil
		end,
		show = function()
			player.Character = character
		end,
		enabled = function(value: boolean)
			state.modules.Companions.extra.enabled = value
		end,
		reduced = function(value: boolean)
			reduced = value
		end,
		guiReduced = function(value: boolean)
			gui.ReducedMotionEnabled = value
		end,
		camera = function(value: boolean)
			world.CurrentCamera = if value then camera else nil
		end,
		counts = function()
			return clones, destroyed, rays
		end,
		copies = function(prefix: string)
			local roster = {}
			for owner = 1, 10 do
				local equipped = {}
				for slot = 1, 3 do
					table.insert(equipped, { uid = prefix .. tostring(slot), itemId = "walker" })
				end
				roster[tostring(owner)] = { userId = owner, equipped = equipped }
			end
			state.modules.Companions.extra.roster = roster
		end,
		budget = function()
			return live, peak
		end,
		tracks = tracks,
		effects = function()
			return effectNodes
		end,
		scans = function()
			return scans
		end,
	}
end
describe("Companion renderer lifecycle", function()
	it("culls streamed roots, recreates reappearances, handles ground misses and disables cleanly", function()
		local run = runtime()
		run.roster(true)
		run.tick(0.25)
		local clones, destroyed, rays = run.counts()
		expect(clones).toBe(1)
		expect(destroyed).toBe(0)
		expect(rays).toBe(1)
		expect(run.tracks.plays).toBe(1)
		expect(run.tracks.ancestryFailures).toBe(0)
		local scans = run.scans()
		run.tick(0.01)
		expect(run.scans()).toBe(scans)
		Follow.api.setLowDetail(true)
		for _, effect in run.effects() do
			expect(effect.Enabled).toBe(false)
		end
		expect(run.effects()[1].clears).toBe(1)
		expect(run.effects()[2].clears).toBe(1)
		Follow.api.setLowDetail(false)
		for index, effect in run.effects() do
			expect(effect.Enabled).toBe(index ~= 6)
		end
		run.hide()
		run.tick(0.25)
		clones, destroyed = run.counts()
		expect(destroyed).toBe(1)
		run.show()
		run.tick(0.25)
		clones, destroyed = run.counts()
		expect(clones).toBe(2)
		run.reduced(true)
		run.tick(0.25)
		expect(run.tracks.plays).toBe(2)
		run.reduced(false)
		run.tick(0.25)
		expect(run.tracks.plays).toBe(3)
		run.guiReduced(true)
		run.tick(0.25)
		expect(run.tracks.plays).toBe(3)
		run.guiReduced(false)
		run.tick(0.25)
		expect(run.tracks.plays).toBe(4)
		Follow.api.setLowDetail(true)
		run.tick(0.25)
		expect(run.tracks.plays).toBe(4)
		expect(Follow.api.debugStats().drawn).toBe(1)
		expect(run.tracks.stops > 0).toBe(true)
		run.camera(false)
		run.tick(0.25)
		clones, destroyed = run.counts()
		expect(destroyed).toBe(2)
		run.camera(true)
		run.tick(0.25)
		local connection = Follow.api.registerLook("late-loop", function(model: any)
			local effect: any = { Parent = model, Enabled = true, clears = 0 }
			function effect:IsA(name: string): boolean
				return name == "ParticleEmitter"
			end
			function effect:Clear()
				self.clears += 1
			end
			table.insert(model.effects, effect)
		end)
		run.tick(0.25)
		clones, destroyed = run.counts()
		expect(clones).toBe(4)
		expect(destroyed).toBe(3)
		expect(#run.effects()).toBe(7)
		for _, effect in run.effects() do
			expect(effect.Enabled).toBe(false)
		end
		Follow.api.setLowDetail(false)
		expect(run.effects()[7].Enabled).toBe(true)

		connection:Disconnect()
		run.enabled(false)
		run.tick(0.25)
		expect(Follow.api.debugStats().drawn).toBe(0)
		expect(run.tracks.destroys).toBe(4)
		Follow.api.setLowDetail(false)
	end)
	it("retires a full old selection before allocating its thirty replacements", function()
		local run = runtime()
		run.copies("a")
		run.tick(0.25)
		local live, peak = run.budget()
		expect(live).toBe(30)
		expect(peak).toBe(30)
		run.copies("b")
		run.tick(0.25)
		live, peak = run.budget()
		expect(live).toBe(30)
		expect(peak).toBe(30)
		run.enabled(false)
		run.tick(0.25)
		live, peak = run.budget()
		expect(live).toBe(0)
	end)
end)
