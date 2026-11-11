--!strict
--[[
	The Roblox side of the framework server runtime (framework internal). Every engine service the
	framework services touch goes through this table, so the services themselves stay testable
	(the Lune harness and the multi-server sim pass their own platform, or Platform.inert()).

	platform = {
	  isStudio, now() (unix s), clock() (os.clock), spawn(fn, ...), delay(s, fn), wait(s?), guid(),
	  encode(value) -> string          JSON (live: HttpService:JSONEncode; console `data dump`),
	  isPlayer(p) (in the game), players = { list(), byUserId(id) }, kick(p, msg),
	  events                           generated Blink server module (framework.blink), or nil
	  marketplace = { setProcessReceipt(fn), getProcessReceipt() -> (readable, fn?) (optional; the
	                  §7.1 runtime owner check), decision(name) -> Enum, ownsPass(userId, id),
	                  onPassPurchaseFinished(fn(player, id, purchased)) }
	  policyLookup(player) -> PolicyInfo
	  analytics = { funnel(p, index, name), economy(p, flow, currency, amount, ending, type, sku?),
	                custom(p, name, value, fields?) }   fields: { [string]: string } -> customFields
	  makeSync(hooks) -> replication transport (Replication.luau)
	  makeStore(gameId) -> Data store (Store.luau)
	  makeShared(gameId) -> shared-store backend (SharedStore.luau; ctx.data.shared). Optional:
	                                   without it the runtime uses SharedStore.memory()
	  installConsole(run(...) -> string)
	  gameModule() -> ModuleRef?       the game's implicit module (§7, C4): live, the definition at
	                                   ReplicatedStorage.GameModule.module (games/<g>/modules/<gameId>)
	  bind(rt)                         PlayerAdded/Removing, Heartbeat, BindToClose
	}
]]

local SharedStore = require(script.Parent.SharedStore)
local Store = require(script.Parent.Store)
local Legacy = require(script.Parent.Legacy)

local Platform = {}

-- Inert platform: no engine at all (unit tests that don't need one). Nothing is ever "in game".
function Platform.inert(overrides: any?): any
	local p: any = {
		isStudio = false,
		now = os.time,
		clock = os.clock,
		spawn = function(fn: any, ...: any)
			local co = coroutine.create(fn)
			local ok, err = coroutine.resume(co, ...)
			if not ok then
				warn("[StudWork] spawned thread failed: " .. tostring(err))
			end
		end,
		delay = function(_s: number, _fn: any) end,
		wait = function(_s: number?) end,
		guid = function(): string
			return tostring(math.random(1, 2 ^ 30))
		end,
		isPlayer = function(_p: any): boolean
			return true
		end,
		players = {
			list = function(): { any }
				return {}
			end,
			byUserId = function(_id: number): any
				return nil
			end,
		},
		kick = function(player: any, msg: string)
			pcall(function()
				player:Kick(msg)
			end)
		end,
		events = nil,
		marketplace = {
			setProcessReceipt = function(_fn: any) end,
			decision = function(name: string): any
				return name
			end,
			ownsPass = function(_u: number, _id: number): boolean
				return false
			end,
			onPassPurchaseFinished = function(_fn: any) end,
		},
		policyLookup = function(_player: any): any
			return { ArePaidRandomItemsRestricted = false }
		end,
		analytics = {
			funnel = function() end,
			economy = function() end,
			custom = function() end,
		},
		makeSync = function(hooks: any): any
			return {
				subscribe = function(player: any, _state: any)
					hooks.sent(player)
				end,
				set = function(_player: any, _state: any) end,
				remove = function(_player: any) end,
				flush = function() end,
			}
		end,
		makeStore = function(_gameId: string): any
			return Store.memory()
		end,
		makeShared = function(_gameId: string): any
			return SharedStore.memory()
		end,
		installConsole = function(_run: any) end,
	}
	for k, v in overrides or {} do
		p[k] = v
	end
	return p
end

function Platform.live(): any
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local HttpService = game:GetService("HttpService")
	local MarketplaceService = game:GetService("MarketplaceService")
	local PolicyService = game:GetService("PolicyService")
	local AnalyticsService = game:GetService("AnalyticsService")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerStorage = game:GetService("ServerStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local isStudio = RunService:IsStudio()
	local events = require(script.Parent.Net.Generated) :: any

	local function isPlayer(p: any): boolean
		return typeof(p) == "Instance" and p:IsA("Player") and p.Parent == Players
	end

	local p: any = {
		isStudio = isStudio,
		now = os.time,
		clock = os.clock,
		spawn = task.spawn,
		delay = task.delay,
		wait = task.wait,
		guid = function(): string
			return HttpService:GenerateGUID(false)
		end,
		-- JSON for the Studio console (`data dump`): the engine's encoder
		encode = function(value: any): string
			return HttpService:JSONEncode(value)
		end,
		isPlayer = isPlayer,
		players = {
			list = function(): { any }
				return Players:GetPlayers()
			end,
			byUserId = function(id: number): any
				return Players:GetPlayerByUserId(id)
			end,
		},
		kick = function(player: any, msg: string)
			if isPlayer(player) then
				player:Kick(msg)
			end
		end,
		events = events,
		marketplace = {
			setProcessReceipt = function(fn: any)
				MarketplaceService.ProcessReceipt = fn
			end,
			-- ProcessReceipt is a write-only callback on the engine ("you can only set the callback
			-- value, get is not available"): pcall'd, so the Shop check sees (false) and reports
			-- itself unavailable instead of erroring. If a future engine allows reading it, the
			-- check becomes live with no other change.
			getProcessReceipt = function(): (boolean, any)
				local ok, current = pcall(function(): any
					return (MarketplaceService :: any).ProcessReceipt
				end)
				if ok and type(current) == "function" then
					return true, current
				end
				return false, nil
			end,
			decision = function(name: string): any
				return if name == "PurchaseGranted"
					then Enum.ProductPurchaseDecision.PurchaseGranted
					else Enum.ProductPurchaseDecision.NotProcessedYet
			end,
			ownsPass = function(userId: number, id: number): boolean
				return MarketplaceService:UserOwnsGamePassAsync(userId, id)
			end,
			onPassPurchaseFinished = function(fn: any)
				MarketplaceService.PromptGamePassPurchaseFinished:Connect(fn)
			end,
		},
		policyLookup = function(player: any): any
			return PolicyService:GetPolicyInfoForPlayerAsync(player)
		end,
		analytics = {
			funnel = function(player: any, index: number, name: string)
				AnalyticsService:LogOnboardingFunnelStepEvent(player, index, name)
			end,
			economy = function(
				player: any,
				flow: string,
				currency: string,
				amount: number,
				ending: number,
				kind: string,
				sku: string?
			)
				local flowType = if flow == "Source"
					then Enum.AnalyticsEconomyFlowType.Source
					else Enum.AnalyticsEconomyFlowType.Sink
				AnalyticsService:LogEconomyEvent(player, flowType, currency, amount, ending, kind, sku)
			end,
			custom = function(player: any, name: string, value: number, fields: { [string]: string }?)
				if fields == nil then
					AnalyticsService:LogCustomEvent(player, name, value)
					return
				end
				-- customFields: up to 3 string values, keyed CustomField01..03, in sorted key order
				local keys = {}
				for k in fields do
					table.insert(keys, k)
				end
				table.sort(keys)
				local custom: { [string]: string } = {}
				local slots = { "CustomField01", "CustomField02", "CustomField03" }
				for i, k in keys do
					if i > #slots then
						break
					end
					custom[(Enum.AnalyticsCustomFieldKeys :: any)[slots[i]].Name] = `{k}={fields[k]}`
				end
				AnalyticsService:LogCustomEvent(player, name, value, custom)
			end,
		},
		makeSync = function(hooks: any): any
			local Packages = ReplicatedStorage:WaitForChild("Packages")
			local Charm = require(Packages:WaitForChild("Charm")) :: any
			local CharmSync = require(Packages:WaitForChild("CharmSync")) :: any
			local atoms: { [any]: any } = {}
			local subscribed: { [any]: boolean } = {}
			CharmSync.config.interval = -1 -- flushed by Replication.step
			CharmSync.server.connect(function(player: any, payloads: any)
				if isPlayer(player) and atoms[player] ~= nil then
					events.StateSync.Fire(player, payloads)
					hooks.sent(player)
				end
			end)
			local function keyOf(player: any): string
				return tostring(player.UserId)
			end
			return {
				subscribe = function(player: any, state: any)
					local atom = atoms[player]
					if atom == nil then
						atom = Charm.atom(state)
						atoms[player] = atom
					else
						atom(state)
					end
					if subscribed[player] then
						CharmSync.server.removeSignalsFromClient(player, keyOf(player))
					end
					CharmSync.server.addSignalsToClient(player, { [keyOf(player)] = atom })
					subscribed[player] = true
				end,
				set = function(player: any, state: any)
					local atom = atoms[player]
					if atom ~= nil then
						atom(state)
					end
				end,
				remove = function(player: any)
					if subscribed[player] then
						CharmSync.server.removeClient(player)
					end
					atoms[player] = nil
					subscribed[player] = nil
				end,
				flush = function()
					CharmSync.server.flush()
				end,
			}
		end,
		makeStore = function(gameId: string): any
			return Store.profileStore({
				gameId = gameId,
				isStudio = isStudio,
				serverPackages = ServerStorage:WaitForChild("ServerPackages"),
				wait = task.wait,
				clock = os.clock,
				spawn = task.spawn,
				log = warn,
				isPlayer = isPlayer,
			})
		end,
		-- ctx.data.shared: one framework-owned DataStore (the only DataStore outside Data)
		makeShared = function(gameId: string): any
			local name = "StudWorkShared_" .. tostring(gameId) .. (if isStudio then "_Studio" else "")
			return SharedStore.dataStore(game:GetService("DataStoreService"), name, {
				isStudio = isStudio,
				log = warn,
			})
		end,
		-- (added in v1.6.0, adopting.md §3) a game's OLD stores, read-only (Legacy.readOnly)
		makeLegacy = function(): any
			return Legacy.readOnly(game:GetService("DataStoreService"), { log = warn })
		end,
		gameModule = function(): any
			local folder = ReplicatedStorage:FindFirstChild("GameModule")
			local def = folder and folder:FindFirstChild("module")
			if def == nil or not def:IsA("ModuleScript") then
				return nil
			end
			return (require :: any)(def)
		end,
		installConsole = function(run: (...any) -> string)
			local bindable = Instance.new("BindableFunction")
			bindable.Name = "StudWorkConsole"
			bindable.OnInvoke = run
			local root = ServerScriptService:FindFirstChild("Framework")
			bindable.Parent = root or ServerScriptService
		end,
	}

	function p.bind(rt: any)
		Players.PlayerAdded:Connect(function(player: any)
			rt.playerAdded(player)
		end)
		Players.PlayerRemoving:Connect(function(player: any)
			rt.playerRemoving(player)
		end)
		for _, player in Players:GetPlayers() do
			task.spawn(rt.playerAdded, player)
		end
		RunService.Heartbeat:Connect(function(dt: number)
			rt.tick(dt)
		end)
		game:BindToClose(function()
			rt.shutdown()
		end)
		MarketplaceService.PromptGamePassPurchaseFinished:Connect(
			function(player: any, gamePassId: number, wasPurchased: boolean)
				rt.passPurchased(player, gamePassId, wasPurchased)
			end
		)
	end

	return p
end

return Platform
