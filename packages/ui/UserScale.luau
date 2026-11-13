--!strict
-- Shared local-player scale convention; malformed attributes preserve the default.
local UserScale = {}
function UserScale.preference(value: any): number
	return if type(value) == "number" and value == value and value >= 0.8 and value <= 1.2 then value else 1
end
function UserScale.combined(responsive: number, value: any): number
	return responsive * UserScale.preference(value)
end
return UserScale
