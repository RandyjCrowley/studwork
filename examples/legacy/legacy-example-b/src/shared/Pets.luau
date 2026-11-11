-- Pets: every pet, and the egg's weights (the higher the weight, the more common).
return {
	pets = {
		puppy = { name = "Puppy", rarity = "Common", coinsPerSecond = 1 },
		kitten = { name = "Kitten", rarity = "Common", coinsPerSecond = 1 },
		fox = { name = "Fox", rarity = "Rare", coinsPerSecond = 4 },
		owl = { name = "Owl", rarity = "Rare", coinsPerSecond = 5 },
		dragon = { name = "Dragon", rarity = "Legendary", coinsPerSecond = 25 },
	},
	egg = {
		gemCost = 50,
		weights = { puppy = 40, kitten = 40, fox = 9, owl = 9, dragon = 2 },
	},
	maxPets = 10,
	maxPetsWithPass = 20,
	maxEquipped = 3,
}
