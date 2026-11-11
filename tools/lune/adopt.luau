--!nocheck
--[[
	tools/lune/adopt (StudWork v1.6.0): the Lune side of tools/adopt --audit / --from-place / --verify
	(docs/framework/adopting.md §1). v1.6.0 contract stub: agent A replaces this file.
]]
local process = require("@lune/process")
print("tools/adopt " .. tostring(process.args[1]) .. ": not implemented yet")
process.exit(1)
