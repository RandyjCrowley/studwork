--!strict
--[[
	Core.Plot. OWNED BY AGENT D (core/d-plot). Public API: Types.PlotAPI (+ init/start).

	Plot models are supplied by the game (see README.md for the full attribute contract):
	- any Model tagged "CorePlot" (CollectionService), also added/removed at runtime
	- slots = BaseParts inside it with string attribute "SlotId"; optional string attribute
	  "SlotTag" restricts a slot to items whose ItemDef.tags contain that tag (e.g. "Shelf")
	- optional numeric attribute "PlotOrder" on the plot (assignment order; else natural Name)
	- optional spawn: a BasePart named "Spawn" or with attribute PlotSpawn = true
	- the service writes attribute OwnerUserId (number) on the plot while it is owned

	Behaviour:
	- assigns the first free plot on Data.onLoaded (deterministic order), sets OwnerUserId,
	  replicates plotName, fires PlotAssigned + onAssigned handlers; queues players when no plot is
	  free (one warning each) and assigns them when a plot frees up / is added
	- frees it on leave (visuals destroyed via the session Trove, attribute cleared, PlotReleased)
	- PlayerData.displayed (slotId -> uid) is the source of truth; visuals are re-rendered from it
	  on assignment, DataLoaded, Rebirthed and every display change; stale entries (uid no longer
	  owned, duplicate uid, slot not on this plot / beyond balance.plot.slotCount) are removed
	  (ItemUndisplayed fired for each)
	- balance.plot.autoDisplay: ItemAdded and items owned before assignment go to the first
	  compatible free slot. ItemRemoved clears the item's slot.
	- visuals = clone of ReplicatedStorage[assetsFolderName or "GameAssets"][def.model] (scripts
	  stripped) or a rarity-coloured placeholder; rarity glow (PointLight) + name billboard; all
	  anchored, CanCollide/CanQuery/CanTouch false, parented to a "CoreDisplays" folder in the plot.
	  Idle bob/spin is left to the client (visuals carry attributes ItemUid/ItemId/Rarity/DisplaySlotId).
	- RequestDisplay / RequestClearDisplay validate strings + ownership; a player can only ever
	  display into their own plot (there is no plot parameter on the wire).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = ReplicatedStorage:WaitForChild("Core")
local RarityTiers = require(Core:WaitForChild("RarityTiers"))
local Types = require(Core:WaitForChild("Types"))
local HandlerList = require(Core:WaitForChild("HandlerList"))
local Trove = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Trove"))
local Slots = require(script.Slots)

local PLOT_TAG = "CorePlot"
local SLOT_ATTRIBUTE = "SlotId"
local SLOT_TAG_ATTRIBUTE = "SlotTag"
local ORDER_ATTRIBUTE = "PlotOrder"
local OWNER_ATTRIBUTE = "OwnerUserId"
local SPAWN_NAME = "Spawn"
local SPAWN_ATTRIBUTE = "PlotSpawn"
local DISPLAY_FOLDER = "CoreDisplays"
local DEFAULT_ASSETS_FOLDER = "GameAssets"

-- engineering constants
local MAX_ID_LENGTH = 64 -- uid / slotId strings from the client
local PLACEHOLDER_SIZE = 2
local VISUAL_LIFT = 0.05 -- studs above the slot surface
local LABEL_HEIGHT = 1.5 -- studs above the visual's top
local LABEL_MAX_DISTANCE = 80
local GLOW_RANGE = 10
local GLOW_BRIGHTNESS = 3
local NEON_MIN_GLOW = 0.5 -- placeholder turns Neon at/above this glowStrength
local SPAWN_LIFT = 3
local SPAWN_OWNERSHIP_HOLD = 0.3 -- seconds the server holds the root after a spawn pivot
local ROOT_WAIT_SECONDS = 5

type Session = {
	plot: Model,
	trove: any, -- Trove: everything owned by this player's plot session
	visuals: { [string]: Instance }, -- slotId -> visual
	folder: Folder,
}

local Plot = {}

local ctx: any = nil
local sessions: { [Player]: Session } = {}
local waiting: { Player } = {} -- loaded players without a plot, FIFO
local warnedWaiting: { [Player]: boolean } = {}
local assignedHandlers = HandlerList.new()

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function plotConfig(): { slotCount: number?, autoDisplay: boolean? }
	local balance = ctx.config.balance
	return (balance and balance.plot) or {}
end

local function validId(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= MAX_ID_LENGTH
end

-- slotId -> part for every slot in the plot (first part wins on duplicate ids).
local function slotParts(plot: Model): { [string]: BasePart }
	local map: { [string]: BasePart } = {}
	for _, d in plot:GetDescendants() do
		if d:IsA("BasePart") then
			local id = d:GetAttribute(SLOT_ATTRIBUTE)
			if type(id) == "string" and id ~= "" and not map[id] then
				map[id] = d
			end
		end
	end
	return map
end

-- Active slot records (sorted, slotCount applied) + the part map.
local function activeSlots(plot: Model): ({ Slots.SlotRecord }, { [string]: BasePart })
	local parts = slotParts(plot)
	local records: { Slots.SlotRecord } = {}
	for id, part in parts do
		local tag = part:GetAttribute(SLOT_TAG_ATTRIBUTE)
		table.insert(records, { id = id, tag = if type(tag) == "string" and tag ~= "" then tag else nil })
	end
	return Slots.limit(records, plotConfig().slotCount), parts
end

local function itemDef(itemId: string): Types.ItemDef?
	return ctx.services.Items.get(itemId)
end

local function tagsOf(instance: Types.ItemInstance?): { string }?
	if instance == nil then
		return nil
	end
	local def = itemDef(instance.itemId)
	return if def then def.tags else nil
end

local function findSpawn(plot: Model): BasePart?
	for _, d in plot:GetDescendants() do
		if d:IsA("BasePart") and (d.Name == SPAWN_NAME or d:GetAttribute(SPAWN_ATTRIBUTE) == true) then
			return d
		end
	end
	return nil
end

local function ownerOf(plot: Model): Player?
	for player, session in sessions do
		if session.plot == plot then
			return player
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Visuals
--------------------------------------------------------------------------------

local function stripAndFreeze(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	local all: { Instance } = root:GetDescendants()
	table.insert(all, root)
	for _, d in all do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
end

local function makeVisual(
	instance: Types.ItemInstance,
	slotId: string,
	slot: BasePart,
	folder: Folder
): Instance
	local def = itemDef(instance.itemId)
	local rarity: Types.RarityTier = if def and RarityTiers.isTier(def.rarity) then def.rarity else "Common"
	local tier = RarityTiers.get(rarity)
	local assets = ReplicatedStorage:FindFirstChild(ctx.config.assetsFolderName or DEFAULT_ASSETS_FOLDER)
	local template = if def and def.model and assets then assets:FindFirstChild(def.model) else nil

	local surface = slot.CFrame * CFrame.new(0, slot.Size.Y / 2 + VISUAL_LIFT, 0)
	local visual: Instance
	local adornee: BasePart? = nil
	local height: number
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		local clone = template:Clone()
		stripAndFreeze(clone)
		if clone:IsA("Model") then
			local _, size = clone:GetBoundingBox()
			height = size.Y
			clone:PivotTo(surface * CFrame.new(0, size.Y / 2, 0))
			adornee = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
		else
			local part = clone :: BasePart
			height = part.Size.Y
			part.CFrame = surface * CFrame.new(0, part.Size.Y / 2, 0)
			adornee = part
		end
		visual = clone
	else
		local part = Instance.new("Part")
		part.Size = Vector3.one * PLACEHOLDER_SIZE
		part.CFrame = surface * CFrame.new(0, PLACEHOLDER_SIZE / 2, 0)
		part.Color = Color3.fromHex(tier.color)
		part.Material = if tier.glowStrength >= NEON_MIN_GLOW
			then Enum.Material.Neon
			else Enum.Material.SmoothPlastic
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		stripAndFreeze(part)
		height = PLACEHOLDER_SIZE
		adornee = part
		visual = part
	end

	if adornee then
		-- Highlight has a ~31-per-client limit (6 plots x 8 slots exceeds it), so the rarity glow
		-- is a PointLight scaled by glowStrength (Common = 0 = no light).
		if tier.glowStrength > 0 then
			local light = Instance.new("PointLight")
			light.Color = Color3.fromHex(tier.glow)
			light.Brightness = GLOW_BRIGHTNESS * tier.glowStrength
			light.Range = GLOW_RANGE
			light.Shadows = false
			light.Parent = adornee
		end

		local gui = Instance.new("BillboardGui")
		gui.Name = "ItemLabel"
		gui.Adornee = adornee
		gui.Size = UDim2.fromOffset(160, 28)
		gui.StudsOffsetWorldSpace = Vector3.new(0, height / 2 + LABEL_HEIGHT, 0)
		gui.MaxDistance = LABEL_MAX_DISTANCE
		gui.LightInfluence = 0
		gui.ResetOnSpawn = false
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.Text = if def then def.name else instance.itemId
		label.TextColor3 = Color3.fromHex(tier.color)
		label.TextStrokeTransparency = 0.4
		label.Parent = gui
		gui.Parent = visual
	end

	visual.Name = "Display_" .. slotId
	visual:SetAttribute(SLOT_ATTRIBUTE, nil) -- a cloned template must never look like a slot
	visual:SetAttribute("ItemUid", instance.uid)
	visual:SetAttribute("ItemId", instance.itemId)
	visual:SetAttribute("Rarity", rarity)
	visual:SetAttribute("DisplaySlotId", slotId)
	visual.Parent = folder
	return visual
end

-- Brings the session's visuals in line with PlayerData.displayed.
local function render(player: Player)
	local session = sessions[player]
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if session == nil or data == nil then
		return
	end
	local slots, parts = activeSlots(session.plot)
	local active: { [string]: boolean } = {}
	for _, s in slots do
		active[s.id] = true
	end
	for slotId, visual in session.visuals do
		local uid = data.displayed[slotId]
		if
			uid == nil
			or not active[slotId]
			or visual:GetAttribute("ItemUid") ~= uid
			or visual.Parent == nil
		then
			session.visuals[slotId] = nil
			session.trove:Remove(visual) -- removes + destroys
		end
	end
	for slotId, uid in data.displayed do
		local instance = data.inventory[uid]
		local part = parts[slotId]
		if active[slotId] and part and instance and not session.visuals[slotId] then
			local ok, visual = pcall(makeVisual, instance, slotId, part, session.folder)
			if ok then
				session.visuals[slotId] = session.trove:Add(visual)
			else
				warn("[Core.Plot] could not build visual for " .. instance.itemId .. ": " .. tostring(visual))
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Data reconciliation
--------------------------------------------------------------------------------

local function removeStale(player: Player)
	local session = sessions[player]
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if session == nil or data == nil then
		return
	end
	local stale = Slots.stale(data.displayed, data.inventory, (activeSlots(session.plot)))
	if #stale == 0 then
		return
	end
	local removed: { { slotId: string, uid: string } } = {}
	ctx.services.Data.update(player, function(d: Types.PlayerData)
		for _, slotId in stale do
			local uid = d.displayed[slotId]
			if uid ~= nil then
				d.displayed[slotId] = nil
				table.insert(removed, { slotId = slotId, uid = uid })
			end
		end
	end)
	for _, r in removed do
		ctx.signals.ItemUndisplayed:Fire(player, r.uid, r.slotId)
	end
end

local function autoDisplayAll(player: Player)
	if not plotConfig().autoDisplay then
		return
	end
	local session = sessions[player]
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if session == nil or data == nil then
		return
	end
	local items: { Types.ItemInstance } = {}
	for _, instance in data.inventory do
		table.insert(items, instance)
	end
	table.sort(items, function(a, b)
		if a.acquiredAt ~= b.acquiredAt then
			return a.acquiredAt < b.acquiredAt
		end
		return a.uid < b.uid
	end)
	local pending: { Slots.PendingItem } = {}
	for _, instance in items do
		table.insert(pending, { uid = instance.uid, tags = tagsOf(instance) })
	end
	for _, step in Slots.planAuto((activeSlots(session.plot)), data.displayed, pending) do
		Plot.display(player, step.uid, step.slotId)
	end
end

-- "Re-read everything": DataLoaded/assignment and Rebirthed.
local function reconcile(player: Player)
	removeStale(player)
	render(player)
	autoDisplayAll(player)
end

--------------------------------------------------------------------------------
-- Spawn
--------------------------------------------------------------------------------

local function moveToSpawn(player: Player, character: Model)
	local session = sessions[player]
	if session == nil or findSpawn(session.plot) == nil then
		return
	end
	local root = character:WaitForChild("HumanoidRootPart", ROOT_WAIT_SECONDS)
	-- re-check: the session / character may have changed while waiting
	if root == nil or not root:IsA("BasePart") or sessions[player] ~= session or character.Parent == nil then
		return
	end
	local spawnPart = findSpawn(session.plot)
	if spawnPart == nil then
		return
	end
	local rootPart: BasePart = root
	local target = spawnPart.CFrame * CFrame.new(0, spawnPart.Size.Y / 2 + SPAWN_LIFT, 0)
	-- take network ownership briefly so the client's stale physics can't undo the pivot
	local tookOwnership = pcall(function()
		rootPart:SetNetworkOwner(nil)
	end)
	character:PivotTo(target)
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	if tookOwnership then
		task.delay(SPAWN_OWNERSHIP_HOLD, function()
			if rootPart:IsDescendantOf(game) then
				pcall(function()
					rootPart:SetNetworkOwnershipAuto()
				end)
			end
		end)
	end
end

--------------------------------------------------------------------------------
-- Assignment
--------------------------------------------------------------------------------

local function pickFreePlot(): Model?
	local candidates: { Model } = {}
	local records: { Slots.PlotRecord } = {}
	for _, inst in CollectionService:GetTagged(PLOT_TAG) do
		if inst:IsA("Model") and inst:IsDescendantOf(game) then
			local order = inst:GetAttribute(ORDER_ATTRIBUTE)
			table.insert(candidates, inst)
			table.insert(records, {
				name = inst.Name,
				order = if type(order) == "number" then order else nil,
				-- an OwnerUserId set by someone else (game code) also counts as taken
				owned = ownerOf(inst) ~= nil or inst:GetAttribute(OWNER_ATTRIBUTE) ~= nil,
			})
		end
	end
	local index = Slots.pickPlot(records)
	return if index then candidates[index] else nil
end

local function assign(player: Player): boolean
	if sessions[player] ~= nil or player.Parent ~= Players then
		return true
	end
	if not ctx.services.Data.isLoaded(player) then
		return false
	end
	local plot = pickFreePlot()
	if plot == nil then
		return false
	end
	local trove = Trove.new()
	local folder = Instance.new("Folder")
	folder.Name = DISPLAY_FOLDER
	folder.Parent = plot
	trove:Add(folder)
	local session: Session = { plot = plot, trove = trove, visuals = {}, folder = folder }
	sessions[player] = session
	warnedWaiting[player] = nil
	plot:SetAttribute(OWNER_ATTRIBUTE, player.UserId)
	trove:Add(function()
		if plot:GetAttribute(OWNER_ATTRIBUTE) == player.UserId then
			plot:SetAttribute(OWNER_ATTRIBUTE, nil)
		end
	end)
	trove:Connect(player.CharacterAdded, function(character: Model)
		moveToSpawn(player, character)
	end)
	ctx.setReplicated(player, "plotName", plot.Name)
	ctx.signals.PlotAssigned:Fire(player, plot)
	assignedHandlers:fire(player, plot)
	reconcile(player)
	local character = player.Character
	if character then
		task.spawn(moveToSpawn, player, character)
	end
	return true
end

-- Tries to assign every waiting player (FIFO). Warns once per player while no plot is free.
local function drainQueue()
	local i = 1
	while i <= #waiting do
		local player = waiting[i]
		if player.Parent ~= Players or sessions[player] ~= nil or assign(player) then
			table.remove(waiting, i)
		else
			if not warnedWaiting[player] then
				warnedWaiting[player] = true
				warn(
					string.format(
						"[Core.Plot] no free plot tagged %q for %s; queued until one frees up",
						PLOT_TAG,
						player.Name
					)
				)
			end
			i += 1
		end
	end
end

local function enqueue(player: Player)
	if sessions[player] == nil and not table.find(waiting, player) then
		table.insert(waiting, player)
	end
	drainQueue()
end

local function release(player: Player)
	local session = sessions[player]
	if session then
		sessions[player] = nil
		session.trove:Destroy()
		ctx.setReplicated(player, "plotName", nil)
		ctx.signals.PlotReleased:Fire(player, session.plot)
	end
end

local function onPlayerRemoving(player: Player)
	local index = table.find(waiting, player)
	if index then
		table.remove(waiting, index)
	end
	warnedWaiting[player] = nil
	local hadPlot = sessions[player] ~= nil
	release(player)
	if hadPlot then
		drainQueue()
	end
end

local function onPlotRemoved(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	local player = ownerOf(inst)
	if player then
		release(player)
		if player.Parent == Players then
			enqueue(player) -- moves to another plot when one is free
		end
	end
	drainQueue()
end

--------------------------------------------------------------------------------
-- Console (Studio only)
--------------------------------------------------------------------------------

local function describePlot(userId: any): string
	local id = tonumber(userId)
	local target: Player? = if id then Players:GetPlayerByUserId(id) else Players:GetPlayers()[1]
	if target == nil then
		return "plot: no player"
	end
	local lines: { string } = {}
	local session = sessions[target]
	if session == nil then
		local state = if table.find(waiting, target) then "queued, no free plot" else "data not loaded"
		table.insert(lines, string.format("%s: no plot (%s)", target.Name, state))
	else
		local data: Types.PlayerData? = ctx.services.Data.get(target)
		local slots = activeSlots(session.plot)
		table.insert(
			lines,
			string.format(
				"%s -> %s (%d active slots, spawn=%s)",
				target.Name,
				session.plot.Name,
				#slots,
				tostring(findSpawn(session.plot) ~= nil)
			)
		)
		for _, slot in slots do
			local uid = if data then data.displayed[slot.id] else nil
			local instance = if data and uid then data.inventory[uid] else nil
			table.insert(
				lines,
				string.format(
					"  %s%s: %s",
					slot.id,
					if slot.tag then " [" .. slot.tag .. "]" else "",
					if instance then instance.itemId .. " (" .. instance.uid .. ")" else "-"
				)
			)
		end
	end
	table.insert(lines, string.format("waiting players: %d", #waiting))
	return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function Plot.init(context: any)
	ctx = context
end

function Plot.start()
	CollectionService:GetInstanceAddedSignal(PLOT_TAG):Connect(function()
		task.defer(drainQueue) -- let the game finish building/parenting the model
	end)
	CollectionService:GetInstanceRemovedSignal(PLOT_TAG):Connect(onPlotRemoved)

	-- onLoaded also replays for players already loaded before start()
	ctx.services.Data.onLoaded(function(player: Player)
		if sessions[player] then
			reconcile(player)
		else
			enqueue(player)
		end
	end)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	ctx.signals.ItemAdded:Connect(function(player: Player, instance: Types.ItemInstance)
		if plotConfig().autoDisplay and sessions[player] then
			Plot.display(player, instance.uid)
		end
	end)
	ctx.signals.ItemRemoved:Connect(function(player: Player, instance: Types.ItemInstance)
		Plot.clearDisplay(player, instance.uid)
	end)
	ctx.signals.Rebirthed:Connect(function(player: Player)
		reconcile(player)
	end)

	ctx.net.handle("RequestDisplay", function(player: Player, uid: any, slotId: any)
		if not validId(uid) or (slotId ~= nil and not validId(slotId)) then
			return
		end
		Plot.display(player, uid, slotId)
	end)
	ctx.net.handle("RequestClearDisplay", function(player: Player, uid: any)
		if not validId(uid) then
			return
		end
		Plot.clearDisplay(player, uid)
	end)

	if ctx.isStudio then
		ctx.console.register("plot", "plot [userId]: plot assignment + slot occupancy", function(userId: any)
			local text = describePlot(userId)
			print(text)
			return text
		end)
	end
end

function Plot.get(player: Player): Model?
	local session = sessions[player]
	return if session then session.plot else nil
end

-- Current owner of a plot (for games' touch / prompt checks), nil when free or not a plot.
function Plot.owner(plot: Model): Player?
	if typeof(plot) ~= "Instance" or not plot:IsA("Model") then
		return nil
	end
	return ownerOf(plot)
end

function Plot.slots(player: Player): { string }
	local session = sessions[player]
	local list: { string } = {}
	if session then
		for _, slot in (activeSlots(session.plot)) do
			table.insert(list, slot.id)
		end
	end
	return list
end

function Plot.display(player: Player, uid: string, slotId: string?): (boolean, string?)
	if not validId(uid) then
		return false, Slots.NOT_OWNED
	end
	if slotId ~= nil and not validId(slotId) then
		return false, Slots.NO_SLOT
	end
	local session = sessions[player]
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if session == nil or data == nil then
		return false, Slots.NO_PLOT
	end
	local target, reason = Slots.validateDisplay({
		slots = (activeSlots(session.plot)),
		displayed = data.displayed,
		owned = data.inventory,
		uid = uid,
		slotId = slotId,
		itemTags = tagsOf(data.inventory[uid]),
	})
	if target == nil then
		return false, reason
	end
	local chosen: string = target
	local wrote = false
	ctx.services.Data.update(player, function(d: Types.PlayerData)
		-- re-check against the live table
		if
			d.displayed[chosen] == nil
			and d.inventory[uid] ~= nil
			and Slots.isDisplayed(d.displayed, uid) == nil
		then
			d.displayed[chosen] = uid
			wrote = true
		end
	end)
	if not wrote then
		return false, Slots.SLOT_TAKEN
	end
	render(player)
	ctx.signals.ItemDisplayed:Fire(player, uid, chosen)
	return true, nil
end

function Plot.clearDisplay(player: Player, uid: string): boolean
	if type(uid) ~= "string" then
		return false
	end
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if data == nil or Slots.isDisplayed(data.displayed, uid) == nil then
		return false
	end
	local cleared: { string } = {}
	ctx.services.Data.update(player, function(d: Types.PlayerData)
		for id, shown in d.displayed do
			if shown == uid then
				d.displayed[id] = nil
				table.insert(cleared, id)
			end
		end
	end)
	if #cleared == 0 then
		return false
	end
	render(player)
	for _, id in cleared do
		ctx.signals.ItemUndisplayed:Fire(player, uid, id)
	end
	return true
end

function Plot.onAssigned(handler: (player: Player, plot: Model) -> ()): Types.Connection
	return assignedHandlers:add(handler)
end

return Plot
