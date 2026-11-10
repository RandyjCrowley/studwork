--!strict
--[[
	Core.Plot. OWNED BY AGENT D (core/d-plot). Public API: Types.PlotAPI.

	PHASE 0 STUB. Plot models are supplied by the game: any Model tagged "CorePlot"
	(CollectionService). Slots are BaseParts inside it with a string attribute "SlotId".
	- assigns the first free plot on DataLoaded (sets attribute OwnerUserId), frees it on leave
	- re-displays PlayerData.displayed on load; auto-displays new items if balance.plot.autoDisplay
	- display = clone of ReplicatedStorage[assetsFolderName][def.model] or a rarity-coloured
	  placeholder Part, parented to the slot
	- RequestDisplay / RequestClearDisplay handlers check ownership
	Agent D: Trove clean-up, slot tags/filters (e.g. "Shelf"), PlotLayout math, spawn point,
	ownership checks for touch/prompt interactions, tests.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RarityTiers = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("RarityTiers"))
local Types = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Types"))
local HandlerList = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("HandlerList"))

local PLOT_TAG = "CorePlot"
local SLOT_ATTRIBUTE = "SlotId"

local Plot = {}

local ctx: any = nil
local plotOf: { [Player]: Model? } = {}
local visuals: { [Player]: { [string]: Instance }? } = {} -- slotId -> visual
local assignedHandlers = HandlerList.new()

local function slotParts(plot: Model): { [string]: BasePart }
	local map: { [string]: BasePart } = {}
	for _, d in plot:GetDescendants() do
		if d:IsA("BasePart") then
			local id = d:GetAttribute(SLOT_ATTRIBUTE)
			if type(id) == "string" then
				map[id] = d
			end
		end
	end
	return map
end

local function makeVisual(instance: Types.ItemInstance, slot: BasePart): Instance
	local def = ctx.services.Items.get(instance.itemId)
	local folderName = ctx.config.assetsFolderName or "GameAssets"
	local assets = ReplicatedStorage:FindFirstChild(folderName)
	local template = def and def.model and assets and assets:FindFirstChild(def.model)
	local visual: Instance
	if template and template:IsA("Model") then
		local clone = template:Clone()
		clone:PivotTo(slot.CFrame * CFrame.new(0, slot.Size.Y / 2 + 1.5, 0))
		visual = clone
	else
		local part = Instance.new("Part")
		part.Size = Vector3.new(2, 2, 2)
		part.Anchored = true
		part.CanCollide = false
		part.CFrame = slot.CFrame * CFrame.new(0, slot.Size.Y / 2 + 1, 0)
		part.Color = Color3.fromHex(RarityTiers.get(if def then def.rarity else "Common").color)
		part.Material = Enum.Material.SmoothPlastic
		visual = part
	end
	visual.Name = "Display_" .. instance.uid
	visual:SetAttribute("ItemUid", instance.uid)
	visual.Parent = slot
	return visual
end

local function render(player: Player)
	local plot = plotOf[player]
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if plot == nil or data == nil then
		return
	end
	local slots = slotParts(plot)
	local current: { [string]: Instance } = visuals[player] or {}
	visuals[player] = current
	for slotId, visual in current do
		if data.displayed[slotId] == nil or visual:GetAttribute("ItemUid") ~= data.displayed[slotId] then
			visual:Destroy()
			current[slotId] = nil
		end
	end
	for slotId, uid in data.displayed do
		local slot = slots[slotId]
		local instance = data.inventory[uid]
		if slot and instance and not current[slotId] then
			current[slotId] = makeVisual(instance, slot)
		end
	end
end

local function release(player: Player)
	local plot = plotOf[player]
	if plot then
		local current = visuals[player]
		if current then
			for _, visual in current do
				visual:Destroy()
			end
		end
		plot:SetAttribute("OwnerUserId", nil)
		ctx.signals.PlotReleased:Fire(player, plot)
	end
	plotOf[player] = nil
	visuals[player] = nil
end

local function assign(player: Player)
	for _, plot in CollectionService:GetTagged(PLOT_TAG) do
		if plot:IsA("Model") and plot:GetAttribute("OwnerUserId") == nil then
			plot:SetAttribute("OwnerUserId", player.UserId)
			plotOf[player] = plot
			ctx.setReplicated(player, "plotName", plot.Name)
			ctx.signals.PlotAssigned:Fire(player, plot)
			assignedHandlers:fire(player, plot)
			render(player)
			-- items granted before the plot existed (starter items) get auto-displayed now
			local plotConfig = ctx.config.balance.plot
			if plotConfig and plotConfig.autoDisplay then
				for _, instance in ctx.services.Inventory.list(player) do
					Plot.display(player, instance.uid)
				end
			end
			return
		end
	end
	warn("[Core.Plot] no free plot tagged " .. PLOT_TAG .. " for " .. player.Name)
end

function Plot.init(context: any)
	ctx = context
end

function Plot.start()
	ctx.services.Data.onLoaded(function(player: Player)
		assign(player)
	end)
	Players.PlayerRemoving:Connect(release)
	ctx.signals.ItemAdded:Connect(function(player: Player, instance: Types.ItemInstance)
		local plotConfig = ctx.config.balance.plot
		if plotConfig and plotConfig.autoDisplay then
			Plot.display(player, instance.uid)
		end
	end)
	ctx.signals.ItemRemoved:Connect(function(player: Player, instance: Types.ItemInstance)
		Plot.clearDisplay(player, instance.uid)
	end)
	ctx.signals.Rebirthed:Connect(function(player: Player)
		render(player)
	end)
	ctx.net.handle("RequestDisplay", function(player: Player, uid: string, slotId: string?)
		Plot.display(player, uid, slotId)
	end)
	ctx.net.handle("RequestClearDisplay", function(player: Player, uid: string)
		Plot.clearDisplay(player, uid)
	end)
end

function Plot.get(player: Player): Model?
	return plotOf[player]
end

function Plot.owner(plot: Model): Player?
	local id = plot:GetAttribute("OwnerUserId")
	return if type(id) == "number" then Players:GetPlayerByUserId(id) else nil
end

function Plot.slots(player: Player): { string }
	local plot = plotOf[player]
	local list = {}
	if plot then
		for id in slotParts(plot) do
			table.insert(list, id)
		end
		table.sort(list)
	end
	return list
end

function Plot.display(player: Player, uid: string, slotId: string?): (boolean, string?)
	local plot = plotOf[player]
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if plot == nil or data == nil then
		return false, "no_plot"
	end
	if data.inventory[uid] == nil then
		return false, "not_owned"
	end
	for _, shown in data.displayed do
		if shown == uid then
			return false, "already_displayed"
		end
	end
	local target = slotId
	if target == nil then
		for _, id in Plot.slots(player) do
			if data.displayed[id] == nil then
				target = id
				break
			end
		end
	end
	if target == nil or not slotParts(plot)[target] then
		return false, "no_slot"
	end
	if data.displayed[target] ~= nil then
		return false, "slot_taken"
	end
	local chosen = target :: string
	ctx.services.Data.update(player, function(d: Types.PlayerData)
		d.displayed[chosen] = uid
	end)
	render(player)
	ctx.signals.ItemDisplayed:Fire(player, uid, chosen)
	return true, nil
end

function Plot.clearDisplay(player: Player, uid: string): boolean
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if data == nil then
		return false
	end
	local found: string? = nil
	for slotId, shown in data.displayed do
		if shown == uid then
			found = slotId
		end
	end
	if found == nil then
		return false
	end
	local slotId = found :: string
	ctx.services.Data.update(player, function(d: Types.PlayerData)
		d.displayed[slotId] = nil
	end)
	render(player)
	ctx.signals.ItemUndisplayed:Fire(player, uid, slotId)
	return true
end

function Plot.onAssigned(handler: (player: Player, plot: Model) -> ()): Types.Connection
	return assignedHandlers:add(handler)
end

return Plot
