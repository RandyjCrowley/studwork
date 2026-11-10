--!nocheck
-- tools/lune/json-get <file> <dotted.path>: print one value from a JSON file (used by tools/publish).
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local file, path = process.args[1], process.args[2]
if file == nil or path == nil then
	print("usage: json-get <file> <dotted.path>")
	process.exit(1)
end
local value = serde.decode("json", fs.readFile(file))
for key in string.gmatch(path, "[^%.]+") do
	if type(value) ~= "table" then
		value = nil
		break
	end
	value = value[key]
end
if value == nil then
	stdio.ewrite("json-get: " .. path .. " not found in " .. file .. "\n")
	process.exit(1)
end
if type(value) == "number" and math.floor(value) == value then
	print(string.format("%d", value))
else
	print(tostring(value))
end
