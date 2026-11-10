--!strict
--[[
	Pure formatting helpers for the UI kit (zero dependencies, testable under Lune).

	Format.abbreviate(n, decimals?)  1234 -> "1.2K", 3_400_000 -> "3.4M", 5.6e9 -> "5.6B" ...
		Truncates (never rounds up into the next suffix: 999_999 -> "999.9K"), trims ".0",
		keeps the sign, small non-integers keep one decimal ("0.5"), NaN -> "0", inf -> "inf".
	Format.percent(p)  probability 0..1 -> "12.5%". A non-zero chance never prints as 0%:
		tiny chances get extra significant digits ("0.0012%") and anything below 1e-10 % reads
		"<0.0000000001%". A chance below 1 never prints as "100%".
]]

local Format = {}

local SUFFIXES = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local MAX_PERCENT_DECIMALS = 10

local function trimZeros(s: string): string
	if string.find(s, ".", 1, true) then
		s = string.gsub(s, "0+$", "")
		s = string.gsub(s, "%.$", "")
	end
	return s
end

-- Truncate toward zero to `decimals` places and format.
local function truncated(value: number, decimals: number): string
	local factor = 10 ^ decimals
	local t = math.floor(value * factor + 1e-9) / factor
	return trimZeros(string.format("%." .. decimals .. "f", t))
end

function Format.abbreviate(n: number, decimals: number?): string
	local places = decimals or 1
	if n ~= n then
		return "0"
	end
	if n == math.huge then
		return "inf"
	elseif n == -math.huge then
		return "-inf"
	end
	local sign = if n < 0 then "-" else ""
	local a = math.abs(n)
	if a < 1000 then
		if a == math.floor(a) or a >= 100 then
			return sign .. tostring(math.floor(a))
		end
		local s = truncated(a, places)
		return if s == "0" then "0" else sign .. s
	end
	local tier = math.floor(math.log10(a) / 3 + 1e-12)
	if tier > #SUFFIXES then
		return sign .. string.gsub(string.format("%.2e", a), "e%+?", "e")
	end
	local scaled = a / 1000 ^ tier
	if scaled >= 1000 and tier < #SUFFIXES then
		tier += 1
		scaled /= 1000
	end
	return sign .. truncated(scaled, places) .. SUFFIXES[tier]
end

function Format.percent(p: number): string
	if p ~= p or p <= 0 then
		return "0%"
	end
	if p >= 1 then
		return "100%"
	end
	local pct = p * 100
	local decimals = 2
	if pct < 0.01 then
		-- two significant digits for tiny chances
		decimals = math.ceil(-math.log10(pct)) + 1
	end
	if decimals > MAX_PERCENT_DECIMALS then
		return "<0." .. string.rep("0", MAX_PERCENT_DECIMALS - 1) .. "1%"
	end
	local s = trimZeros(string.format("%." .. decimals .. "f", pct))
	if s == "100" then
		s = "99.99" -- p < 1 must never read as certain
	elseif tonumber(s) == 0 then
		s = trimZeros(string.format("%." .. (decimals + 1) .. "f", pct))
	end
	return s .. "%"
end

return Format
