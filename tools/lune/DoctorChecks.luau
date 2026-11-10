--!strict
--[[
	tools/lune/DoctorChecks: pure helpers of tools/doctor (zero requires). Specs: DoctorChecks.spec.luau.

	parseRokit(text)            -> { {name, version} }   from rokit.toml [tools] (`x = "owner/repo@1.2.3"`)
	versionMatches(out, want)   -> boolean               does `<tool> --version` output contain `want`
	                                                     as a whole version token
	parseWally(text)            -> { {alias, realm, index} } index = "<owner>_<name>@<version>" folder
	envKeys(exampleText, envText?) -> { {key, present} }  key names from .env.example; present = the
	                                                     .env has a NON-EMPTY value. Values are never
	                                                     returned (only booleans).
	Results are rows { level = "ok"|"warn"|"fail", item, detail, fix? }.
]]

local Doctor = {}

export type Row = { level: string, item: string, detail: string, fix: string? }

-- Binary name for each rokit tool key (rokit.toml keys are not always the binary name).
Doctor.BINARY = {
	rojo = "rojo",
	wally = "wally",
	selene = "selene",
	StyLua = "stylua",
	lune = "lune",
	blink = "blink",
	["luau-lsp"] = "luau-lsp",
}

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") :: string
end

function Doctor.parseRokit(text: string): { { name: string, version: string } }
	local out = {}
	local inTools = false
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		local l = trim(string.gsub(line, "#.*$", "") :: string)
		local header = string.match(l, "^%[(.-)%]$")
		if header then
			inTools = header == "tools"
		elseif inTools and l ~= "" then
			local name, version = string.match(l, '^([%w_%-]+)%s*=%s*"[^"@]+@([^"]+)"')
			if name and version then
				table.insert(out, { name = name, version = version })
			end
		end
	end
	return out
end

function Doctor.versionMatches(output: string, want: string): boolean
	local escaped = string.gsub(want, "%p", "%%%0")
	-- a version token: not preceded/followed by more version characters
	return string.find(" " .. output .. " ", "[^%w%.]" .. escaped .. "[^%w%.]") ~= nil
end

function Doctor.parseWally(text: string): { { alias: string, realm: string, index: string } }
	local out = {}
	local realm: string? = nil
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		local l = trim(string.gsub(line, "#.*$", "") :: string)
		local header = string.match(l, "^%[(.-)%]$")
		if header then
			realm = if header == "dependencies"
				then "shared"
				elseif header == "server-dependencies" then "server"
				elseif header == "dev-dependencies" then "dev"
				else nil
		elseif realm and l ~= "" then
			local alias, owner, name, version =
				string.match(l, '^([%w_%-]+)%s*=%s*"([^/"]+)/([^@"]+)@=?([^"]+)"')
			if alias then
				table.insert(out, {
					alias = alias,
					realm = realm,
					index = string.lower(owner :: string)
						.. "_"
						.. string.lower(name :: string)
						.. "@"
						.. version,
				})
			end
		end
	end
	return out
end

local function envNames(text: string): { [string]: string }
	-- KEY=VALUE (optionally `export KEY=...`); only used to learn names and emptiness
	local map: { [string]: string } = {}
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		local l = trim(line)
		if l ~= "" and string.sub(l, 1, 1) ~= "#" then
			local key, value = string.match(l, "^export%s+([%a_][%w_]*)%s*=(.*)$")
			if key == nil then
				key, value = string.match(l, "^([%a_][%w_]*)%s*=(.*)$")
			end
			if key then
				local v = trim(value :: string)
				v = string.gsub(v, '^"(.*)"$', "%1") :: string
				v = string.gsub(v, "^'(.*)'$", "%1") :: string
				map[key] = v
			end
		end
	end
	return map
end

function Doctor.envKeys(exampleText: string, envText: string?): { { key: string, present: boolean } }
	local example = envNames(exampleText)
	local env = if envText then envNames(envText) else {}
	local keys = {}
	for k in example do
		table.insert(keys, k)
	end
	table.sort(keys)
	local out = {}
	for _, k in keys do
		local v = env[k]
		table.insert(out, { key = k, present = v ~= nil and v ~= "" })
	end
	return out
end

-- Formats rows; returns (text, failures).
function Doctor.format(rows: { Row }): (string, number)
	local lines = {}
	local failures = 0
	for _, r in rows do
		local tag = if r.level == "ok" then "ok  " elseif r.level == "warn" then "WARN" else "FAIL"
		if r.level == "fail" then
			failures += 1
		end
		local line = string.format("[%s] %-22s %s", tag, r.item, r.detail)
		if r.fix and r.level ~= "ok" then
			line ..= "\n       fix: " .. r.fix
		end
		table.insert(lines, line)
	end
	return table.concat(lines, "\n"), failures
end

return Doctor
