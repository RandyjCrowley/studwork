--!strict
local Layout = {}
function Layout.available(
	height: number,
	keyboardVisible: boolean,
	keyboardTop: number,
	keyboardHeight: number
): number
	if not keyboardVisible then
		return height
	end
	local top = if keyboardTop > 0 then keyboardTop else height - keyboardHeight
	return math.clamp(top, 1, height)
end
function Layout.touch(minimum: number, responsiveMinimum: number, fitMinimum: number): number
	return math.ceil(minimum / (responsiveMinimum * 0.8 * fitMinimum))
end
function Layout.step(value: number, direction: number, def: any): number
	local n = math.floor((value - def.min) / def.step + 0.5) + direction
	local last = math.floor((def.max - def.min) / def.step + 0.000001)
	return math.clamp(def.min + math.clamp(n, 0, last) * def.step, def.min, def.max)
end
return Layout
