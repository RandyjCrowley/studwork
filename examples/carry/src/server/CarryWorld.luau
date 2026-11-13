--!strict
--[[
	The Carry demo's world pieces (owner: the Carry builder): a carriable crate, a 2-carrier heavy couch,
	a delivery zone and a kill-plane test drop (a crate on a ledge past the ground's edge: carry it off
	the end and drop it; it falls into the void and Carry returns it). Parts are tagged with
	CollectionService; the tags are the keys in config.Carry.carriables (BalanceCarry.luau) and the
	module's default delivery tag. All numbers are in Tuning.carry.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Tuning = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"):WaitForChild("Tuning"))

local CarryWorld = {}

local function box(
	folder: Folder,
	name: string,
	spec: { size: { number }, position: { number } },
	color: string,
	tag: string?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	p.Size = Vector3.new(spec.size[1], spec.size[2], spec.size[3])
	p.Position = Vector3.new(spec.position[1], spec.position[2], spec.position[3])
	p.Color = Color3.fromHex(color)
	if tag ~= nil then
		CollectionService:AddTag(p, tag)
	end
	p.Parent = folder
	return p
end

function CarryWorld.build(folder: Folder)
	local t = Tuning.carry
	box(folder, "DemoCrate", t.crate, t.colors.crate, "DemoCrate")
	box(folder, "DemoCouch", t.couch, t.colors.couch, "DemoCouch")

	-- the delivery zone: a see-through, non-colliding box (its box is what Carry tests against)
	local zone = box(folder, "DeliveryZone", t.zone, t.colors.zone, "CarryDelivery")
	zone.CanCollide = false
	zone.CanQuery = false
	zone.Transparency = t.zoneTransparency

	-- the kill-plane test drop
	box(folder, "VoidLedge", t.ledge, t.colors.ledge)
	box(folder, "DemoVoidCrate", t.voidCrate, t.colors.voidCrate, "DemoVoidCrate")
end

return CarryWorld
