--!strict
local Layout = {}
function Layout.input(value: string): string
	if #value <= 64 then
		return value
	end
	return string.sub(value, 1, (utf8.offset(value, 0, 65) or 65) - 1)
end
function Layout.available(height: number, visible: boolean, top: number, keyboardHeight: number): number
	if not visible then
		return height
	end
	return math.clamp(if top > 0 then top else height - keyboardHeight, 1, height)
end
function Layout.touch(minimum: number, responsiveMinimum: number, fitMinimum: number): number
	return math.ceil(minimum / (responsiveMinimum * 0.8 * fitMinimum))
end
function Layout.result(value: any): string?
	local allowed = {
		ok = true,
		invalid = true,
		expired = true,
		not_yet = true,
		already_used = true,
		limit_reached = true,
		not_eligible = true,
		try_later = true,
	}
	return if type(value) == "string" and allowed[value] then value else nil
end
return Layout
