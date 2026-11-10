--!strict
--[[
	Deterministic pure RNG (32-bit LCG, Numerical Recipes constants) for tests and reproducible
	simulations. Production rolls use Random.new(); this exists because Lune has no Random.
	SeededRng.new(seed) -> () -> number in [0, 1).
]]

local SeededRng = {}

local MOD = 4294967296 -- 2^32
local A = 1664525
local C = 1013904223

function SeededRng.new(seed: number): () -> number
	local state = math.floor(math.abs(seed)) % MOD
	return function(): number
		state = (A * state + C) % MOD -- A * state < 2^53, exact in a double
		return state / MOD
	end
end

return SeededRng
