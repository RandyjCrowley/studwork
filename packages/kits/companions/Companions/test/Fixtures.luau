--!strict
local Fixtures = {}
function Fixtures.model(): Model
	local model = Instance.new("Model")
	model.Name = "CompanionFixture"
	local part = Instance.new("Part")
	part.Name = "Body"
	part.Size = Vector3.new(2, 2, 2)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Parent = model
	model.PrimaryPart = part
	return model
end
Fixtures.items = {
	{ id = "walker", name = "Walker", rarity = "Common", companions = { movement = "walk" } },
	{ id = "hopper", name = "Hopper", rarity = "Rare", companions = { movement = "hop" } },
	{ id = "flyer", name = "Flyer", rarity = "Rare", companions = { movement = "fly" } },
}
return Fixtures
