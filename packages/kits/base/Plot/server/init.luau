--!strict
--[[
	Plot: the base kit's server module (core-v1.3.0 module API). README.md has the full
	attribute contract.

	Plot models are supplied by the game:
	- any Model tagged config.plotTag (default "CorePlot", CollectionService), added/removed at
	  runtime too
	- slots = BaseParts inside it with string attribute "SlotId"; optional "SlotTag" restricts a
	  slot to items whose ItemDef.tags contain that tag
	- optional numeric attribute "PlotOrder" (assignment order; else natural Name)
	- optional spawn: a BasePart named "Spawn" or with attribute PlotSpawn = true
	- Plot writes attribute OwnerUserId on the plot while it is owned

	Data: section "plot" = { displayed = { [slotId]: uid } } (v1.2 shape), written only here.
	Dependencies: Inventory (hard: ownership, item instances, signals.ItemAdded and
	extensions.onItemRemoved, which clears a slot INSIDE the removing tx), Items (optional: tags,
	names, models), Rarity (optional: tier colours via tiers()), Rebirth (optional:
	extensions.resetStep clears `displayed` inside Rebirth's tx, signals.Rebirthed re-renders).

	api (PHASE1-CONTRACT): get, owner, display, clearDisplay, slots, onAssigned, displayed
	signals: ItemDisplayed(player, uid, slotId), ItemUndisplayed(player, uid, slotId) (v1.2),
	DisplayCleared(player, slotId), PlotAssigned(player, plot), PlotReleased(player, plot)
	replicated extra: plotName
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Trove"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))
local Items = require(Modules:WaitForChild("Items"):WaitForChild("module"))
local Rarity = require(Modules:WaitForChild("Rarity"):WaitForChild("module"))
local Rebirth = require(Modules:WaitForChild("Rebirth"):WaitForChild("module"))
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))
local SignalTable = require(script.SignalTable)
local Slots = require(script.Slots)
local SlotCache = require(script.SlotCache)

local DEFAULT_PLOT_TAG = "CorePlot"
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
local NEON_MIN_GLOW = 0.5 -- placeholder turns Neon at/above this glow strength
local SPAWN_LIFT = 3
local SPAWN_OWNERSHIP_HOLD = 0.3 -- seconds the server holds the root after a spawn pivot
local ROOT_WAIT_SECONDS = 5
local NEUTRAL_RGB = { 201, 207, 217 } -- no Rarity module: untiered look

type Session = {
	plot: Model,
	trove: any, -- Trove: everything owned by this player's plot session
	visuals: { [string]: Instance }, -- slotId -> visual
	folder: Folder,
	slots: SlotCache.SlotCache,
}

type Look = { id: string, color: Color3, glow: Color3, strength: number }

local Plot = {}

local ctx: any = nil
local signals = SignalTable.new()
local sessions: { [Player]: Session } = {}
local waiting: { Player } = {} -- loaded players without a plot, FIFO
local warnedWaiting: { [Player]: boolean } = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function plotConfig(): any
	local cfg = ctx.config.plot
	return if type(cfg) == "table" then cfg else {}
end

local function plotTag(): string
	local tag = ctx.config.plotTag
	return if type(tag) == "string" and tag ~= "" then tag else DEFAULT_PLOT_TAG
end

local function validId(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= MAX_ID_LENGTH
end

local function displayedOf(player: any): { [string]: string }?
	if not ctx.data.isLoaded(player) then
		return nil
	end
	local section = ctx.data.get(player)
	return if section and type(section.displayed) == "table" then section.displayed else {}
end

-- uid -> frozen ItemInstance (Inventory's read view)
local function ownedOf(player: any): { [string]: any }
	local map = {}
	for _, instance in ctx.deps[Inventory].list(player) do
		map[instance.uid] = instance
	end
	return map
end

local function ownedInTx(tx: any): { [string]: any }
	local map = {}
	for _, instance in ctx.depsTx[Inventory].list(tx) do
		map[instance.uid] = instance
	end
	return map
end

-- slotId -> part for every slot in the plot (first part wins on duplicate ids, in pre-order).
-- Never walks the CoreDisplays folder (visuals are not slots).
local function slotParts(plot: Model): { [string]: BasePart }
	local map: { [string]: BasePart } = {}
	local function walk(parent: Instance)
		for _, d in parent:GetChildren() do
			if d.Name == DISPLAY_FOLDER and d:IsA("Folder") and parent == plot then
				continue
			end
			if d:IsA("BasePart") then
				local id = d:GetAttribute(SLOT_ATTRIBUTE)
				if type(id) == "string" and id ~= "" and not map[id] then
					map[id] = d
				end
			end
			walk(d)
		end
	end
	walk(plot)
	return map
end

local function slotTagOf(part: any): string?
	local tag = (part :: BasePart):GetAttribute(SLOT_TAG_ATTRIBUTE)
	return if type(tag) == "string" and tag ~= "" then tag else nil
end

local function activeSlots(session: Session): ({ Slots.SlotRecord }, { [string]: BasePart })
	return session.slots:get(plotConfig().slotCount)
end

-- Invalidates the session's slot cache when slot parts outside CoreDisplays change.
local function watchSlots(session: Session)
	local plot, folder, cache = session.plot, session.folder, session.slots
	local function check(d: Instance, deferAgain: boolean)
		local isPart = d:IsA("BasePart")
		local slotId = if isPart then d:GetAttribute(SLOT_ATTRIBUTE) else nil
		if SlotCache.isSlotChange(isPart, slotId, d == folder or d:IsDescendantOf(folder)) then
			cache:invalidate()
			if deferAgain then
				-- DescendantRemoving fires before the part leaves; drop a scan made in between
				task.defer(function()
					cache:invalidate()
				end)
			end
		end
	end
	session.trove:Connect(plot.DescendantAdded, function(d: Instance)
		check(d, false)
	end)
	session.trove:Connect(plot.DescendantRemoving, function(d: Instance)
		check(d, true)
	end)
end

local function itemDef(itemId: string): any
	if not ctx.isEnabled(Items) then
		return nil -- Items is optional: items are untagged and labelled with their id
	end
	return ctx.deps[Items].get(itemId)
end

local function tagsOf(instance: any): { string }?
	if instance == nil then
		return nil
	end
	local def = itemDef(instance.itemId)
	return if def then def.tags else nil
end

local function hex(value: any, fallback: Color3): Color3
	if type(value) == "string" then
		local ok, color = pcall(Color3.fromHex, value)
		if ok then
			return color
		end
	end
	return fallback
end

-- The rarity look of a tier id, from the optional Rarity module's ordered tier list.
local function lookOf(tierId: any): Look
	local NEUTRAL = Color3.fromRGB(NEUTRAL_RGB[1], NEUTRAL_RGB[2], NEUTRAL_RGB[3])
	if ctx.isEnabled(Rarity) then
		local ok, tiers = pcall(ctx.deps[Rarity].tiers)
		if ok and type(tiers) == "table" then
			for i, tier in tiers do
				if type(tier) == "table" and tier.id == tierId then
					local strength = if type(tier.glowStrength) == "number"
						then tier.glowStrength
						elseif #tiers > 1 then (i - 1) / (#tiers - 1)
						else 0
					local color = hex(tier.color, NEUTRAL)
					return { id = tier.id, color = color, glow = hex(tier.glow, color), strength = strength }
				end
			end
			local first = tiers[1]
			if type(first) == "table" and type(first.id) == "string" then
				local color = hex(first.color, NEUTRAL)
				return { id = first.id, color = color, glow = hex(first.glow, color), strength = 0 }
			end
		end
	end
	return {
		id = if type(tierId) == "string" then tierId else "Common",
		color = NEUTRAL,
		glow = NEUTRAL,
		strength = 0,
	}
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

local function makeVisual(instance: any, slotId: string, slot: BasePart, folder: Folder): Instance
	local def = itemDef(instance.itemId)
	local look = lookOf(if def then def.rarity else nil)
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
		part.Color = look.color
		part.Material = if look.strength >= NEON_MIN_GLOW
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
		-- Highlight has a ~31-per-client limit, so the rarity glow is a PointLight scaled by the
		-- tier's glow strength (none for the lowest tier).
		if look.strength > 0 then
			local light = Instance.new("PointLight")
			light.Color = look.glow
			light.Brightness = GLOW_BRIGHTNESS * look.strength
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
		label.TextColor3 = look.color
		label.TextStrokeTransparency = 0.4
		label.Parent = gui
		gui.Parent = visual
	end

	visual.Name = "Display_" .. slotId
	visual:SetAttribute(SLOT_ATTRIBUTE, nil) -- a cloned template must never look like a slot
	visual:SetAttribute("ItemUid", instance.uid)
	visual:SetAttribute("ItemId", instance.itemId)
	visual:SetAttribute("Rarity", look.id)
	visual:SetAttribute("DisplaySlotId", slotId)
	visual.Parent = folder
	return visual
end

-- Brings the session's visuals in line with the saved `displayed`.
local function render(player: Player)
	local session = sessions[player]
	local displayed = displayedOf(player)
	if session == nil or displayed == nil then
		return
	end
	local owned = ownedOf(player)
	local slots, parts = activeSlots(session)
	local active: { [string]: boolean } = {}
	for _, s in slots do
		active[s.id] = true
	end
	for slotId, visual in session.visuals do
		local uid = displayed[slotId]
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
	for slotId, uid in displayed do
		local instance = owned[uid]
		local part = parts[slotId]
		if active[slotId] and part and instance and not session.visuals[slotId] then
			local ok, visual = pcall(makeVisual, instance, slotId, part, session.folder)
			if ok then
				session.visuals[slotId] = session.trove:Add(visual)
			else
				ctx.log.warn("could not build visual for " .. instance.itemId .. ": " .. tostring(visual))
			end
		end
	end
end

local function fireCleared(player: Player, removed: { { slotId: string, uid: string } })
	for _, r in removed do
		signals.ItemUndisplayed:Fire(player, r.uid, r.slotId)
	end
end

--------------------------------------------------------------------------------
-- Data reconciliation
--------------------------------------------------------------------------------

local function removeStale(player: Player)
	local session = sessions[player]
	local displayed = displayedOf(player)
	if session == nil or displayed == nil then
		return
	end
	local stale = Slots.stale(displayed, ownedOf(player), (activeSlots(session)))
	if #stale == 0 then
		return
	end
	local removed: { { slotId: string, uid: string } } = {}
	ctx.data.update(player, function(section: any)
		for _, slotId in stale do
			local uid = section.displayed[slotId]
			if uid ~= nil then
				section.displayed[slotId] = nil
				table.insert(removed, { slotId = slotId, uid = uid })
			end
		end
	end)
	fireCleared(player, removed)
end

local function autoDisplayAll(player: Player)
	if not plotConfig().autoDisplay then
		return
	end
	local session = sessions[player]
	local displayed = displayedOf(player)
	if session == nil or displayed == nil then
		return
	end
	local items = table.clone(ctx.deps[Inventory].list(player))
	table.sort(items, function(a: any, b: any)
		if a.acquiredAt ~= b.acquiredAt then
			return a.acquiredAt < b.acquiredAt
		end
		return a.uid < b.uid
	end)
	local pending: { Slots.PendingItem } = {}
	for _, instance in items do
		table.insert(pending, { uid = instance.uid, tags = tagsOf(instance) })
	end
	for _, step in Slots.planAuto((activeSlots(session)), displayed, pending) do
		Plot.api.display(player, step.uid, step.slotId)
	end
end

-- "Re-read everything": on load / assignment and after a rebirth.
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
	for _, inst in CollectionService:GetTagged(plotTag()) do
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
	if not ctx.data.isLoaded(player) then
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
	local session: Session = {
		plot = plot,
		trove = trove,
		visuals = {},
		folder = folder,
		slots = SlotCache.new(function()
			return slotParts(plot)
		end, slotTagOf, Slots.limit),
	}
	session.slots:get(plotConfig().slotCount) -- build the slot map once at assignment
	watchSlots(session)
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
	ctx.replicate.set(player, "plotName", plot.Name)
	signals.PlotAssigned:Fire(player, plot)
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
				ctx.log.warn(
					string.format(
						"no free plot tagged %q for %s; queued until one frees up",
						plotTag(),
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
		ctx.replicate.set(player, "plotName", nil)
		signals.PlotReleased:Fire(player, session.plot)
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
		local displayed = displayedOf(target) or {}
		local owned = ownedOf(target)
		local slots = activeSlots(session)
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
			local uid = displayed[slot.id]
			local instance = if uid then owned[uid] else nil
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
-- Lifecycle
--------------------------------------------------------------------------------

function Plot.init(context: any)
	ctx = context
	signals.ItemDisplayed = ctx.signals.new("ItemDisplayed")
	signals.ItemUndisplayed = ctx.signals.new("ItemUndisplayed")
	signals.DisplayCleared = ctx.signals.new("DisplayCleared")
	signals.PlotAssigned = ctx.signals.new("PlotAssigned")
	signals.PlotReleased = ctx.signals.new("PlotReleased")
	signals.ItemUndisplayed:Connect(function(player: any, _uid: any, slotId: any)
		signals.DisplayCleared:Fire(player, slotId)
	end)

	-- Economy (optional) earns from displayed items when config.Economy.income.source =
	-- "displayed": Plot is the provider (Economy.extensions.displayedSource, §8 direction: Plot
	-- optional = { Economy }), and invalidates Economy's cached rate on every display change.
	-- Phase 1 integration glue; replaces the Economy compat adapter's shim over the bridged Plot.
	if ctx.isEnabled(Economy) then
		local invalidate = ctx.depsExt[Economy].displayedSource(function(player: any): any
			return displayedOf(player) or table.freeze({})
		end)
		for _, name in { "ItemDisplayed", "ItemUndisplayed", "DisplayCleared" } do
			signals[name]:Connect(function(player: any)
				invalidate(player)
			end)
		end
	end

	-- An item left the inventory: clear its slot inside the removing tx (§8, inverted).
	ctx.depsExt[Inventory].onItemRemoved(function(tx: any, player: any, instance: any)
		local section = ctx.section(tx)
		local removed: { { slotId: string, uid: string } } = {}
		for slotId, uid in section.displayed do
			if uid == instance.uid then
				section.displayed[slotId] = nil
				table.insert(removed, { slotId = slotId, uid = uid })
			end
		end
		if #removed > 0 then
			tx.after(function()
				render(player)
				fireCleared(player, removed)
			end)
		end
	end)

	-- Rebirth (optional): clear `displayed` inside Rebirth's single tx (§8). Every slot, unless
	-- config.plot.keepDisplayedOnRebirth, and always the uids that left the inventory.
	if ctx.isEnabled(Rebirth) then
		ctx.depsExt[Rebirth].resetStep("Plot", function(tx: any, _player: any)
			local section = ctx.section(tx)
			Slots.resetDisplayed(
				{ displayed = section.displayed, inventory = ownedInTx(tx) },
				plotConfig().keepDisplayedOnRebirth == true
			)
		end)
	end

	ctx.console.register("show", function(_player: any, userId: any): string
		if not ctx.isStudio then
			return "plot show is Studio-only"
		end
		return describePlot(userId)
	end, "plot show [userId]: plot assignment + slot occupancy (Studio)")
end

function Plot.start(_context: any)
	local tag = plotTag()
	CollectionService:GetInstanceAddedSignal(tag):Connect(function()
		task.defer(drainQueue) -- let the game finish building/parenting the model
	end)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(onPlotRemoved)

	ctx.data.onLoaded(function(player: Player)
		if sessions[player] then
			reconcile(player)
		else
			enqueue(player)
		end
	end)
	ctx.lifecycle.onPlayerRemoving(onPlayerRemoving)

	ctx.deps[Inventory].signals.ItemAdded:Connect(function(player: Player, instance: any)
		if plotConfig().autoDisplay and sessions[player] then
			Plot.api.display(player, instance.uid)
		end
	end)
	if ctx.isEnabled(Rebirth) then
		ctx.deps[Rebirth].signals.Rebirthed:Connect(function(player: Player)
			reconcile(player)
		end)
	end

	ctx.net.handle("RequestDisplay", function(player: Player, uid: any, slotId: any)
		if not validId(uid) or (slotId ~= nil and not validId(slotId)) then
			return
		end
		Plot.api.display(player, uid, slotId)
	end)
	ctx.net.handle("RequestClearDisplay", function(player: Player, uid: any)
		if not validId(uid) then
			return
		end
		Plot.api.clearDisplay(player, uid)
	end)
end

--------------------------------------------------------------------------------
-- api
--------------------------------------------------------------------------------

Plot.api = {
	signals = signals,

	get = function(player: Player): Model?
		local session = sessions[player]
		return if session then session.plot else nil
	end,

	-- Current owner of a plot (for games' touch / prompt checks), nil when free or not a plot.
	owner = function(plot: Model): Player?
		if typeof(plot) ~= "Instance" or not plot:IsA("Model") then
			return nil
		end
		return ownerOf(plot)
	end,

	slots = function(player: Player): { string }
		local session = sessions[player]
		local list: { string } = {}
		if session then
			for _, slot in (activeSlots(session)) do
				table.insert(list, slot.id)
			end
		end
		return list
	end,

	-- PHASE1-CONTRACT: frozen slotId -> uid map (empty when not loaded).
	displayed = function(player: Player): { [string]: string }
		return displayedOf(player) or table.freeze({})
	end,

	display = function(player: Player, uid: string, slotId: string?): (boolean, string?)
		if not validId(uid) then
			return false, Slots.NOT_OWNED
		end
		if slotId ~= nil and not validId(slotId) then
			return false, Slots.NO_SLOT
		end
		local session = sessions[player]
		local displayed = displayedOf(player)
		if session == nil or displayed == nil then
			return false, Slots.NO_PLOT
		end
		local owned = ownedOf(player)
		-- cheap ownership / duplicate checks before any slot lookup
		local early = Slots.precheck(owned, displayed, uid)
		if early ~= nil then
			return false, early
		end
		local target, reason = Slots.validateDisplay({
			slots = (activeSlots(session)),
			displayed = displayed,
			owned = owned,
			uid = uid,
			slotId = slotId,
			itemTags = tagsOf(owned[uid]),
		})
		if target == nil then
			return false, reason
		end
		local chosen: string = target
		local wrote = false
		ctx.data.update(player, function(section: any)
			if section.displayed[chosen] == nil and Slots.isDisplayed(section.displayed, uid) == nil then
				section.displayed[chosen] = uid
				wrote = true
			end
		end)
		if not wrote then
			return false, Slots.SLOT_TAKEN
		end
		render(player)
		signals.ItemDisplayed:Fire(player, uid, chosen)
		return true, nil
	end,

	-- Never requires ownership: it also runs after the item left the inventory.
	clearDisplay = function(player: Player, uid: string): boolean
		if type(uid) ~= "string" then
			return false
		end
		local displayed = displayedOf(player)
		if displayed == nil or Slots.isDisplayed(displayed, uid) == nil then
			return false
		end
		local removed: { { slotId: string, uid: string } } = {}
		ctx.data.update(player, function(section: any)
			for id, shown in section.displayed do
				if shown == uid then
					section.displayed[id] = nil
					table.insert(removed, { slotId = id, uid = uid })
				end
			end
		end)
		if #removed == 0 then
			return false
		end
		render(player)
		fireCleared(player, removed)
		return true
	end,

	onAssigned = function(handler: (player: Player, plot: Model) -> ()): any
		return signals.PlotAssigned:Connect(handler)
	end,
}

return Plot
