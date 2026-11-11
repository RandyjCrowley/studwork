-- stand-in for the DataStore2 library (the audit only reads the calls)
return setmetatable({}, {
	__call = function()
		return {}
	end,
})
