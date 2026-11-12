--!strict
-- Source-level guard; engine geometry is checked by tools/studio/ui-text-fit.luau.
local Checker = {}

export type Issue = { rule: string, path: string, detail: string }
local function issue(out: { Issue }, rule: string, path: string, detail: string)
	table.insert(out, { rule = rule, path = path, detail = detail })
end

local function textBlocks(source: string): { string }
	local blocks = {}
	local pos = 1
	while true do
		local start, finish = string.find(source, 'e%("TextLabel"')
		if not start then
			break
		end
		-- consume the properties table, not nested children (which may contain other labels)
		local brace = string.find(source, "{", finish + 1, true)
		if not brace then
			break
		end
		local depth = 0
		local last = brace
		for i = brace, #source do
			local c = string.sub(source, i, i)
			if c == "{" then
				depth += 1
			elseif c == "}" then
				depth -= 1
				if depth == 0 then
					last = i
					break
				end
			end
		end
		table.insert(blocks, string.sub(source, brace, last))
		source = string.sub(source, last + 1)
		pos += 1
	end
	return blocks
end

function Checker.scan(path: string, source: string, options: any): { Issue }
	local out: { Issue } = {}
	local blocks = textBlocks(source)
	local labelCount = #blocks
	for _ in string.gmatch(source, 'e%("TextButton"') do
		labelCount += 1
	end
	for _ in string.gmatch(source, 'e%("TextBox"') do
		labelCount += 1
	end
	if labelCount > 0 and not options.covered[path] then
		issue(out, "coverage", path, "text-bearing component has no fixture")
	end
	if path ~= "packages/ui/WrappedText.luau" then
		for _, block in blocks do
			if
				string.find(block, "TextWrapped%s*=%s*true")
				and string.find(block, "AutomaticSize%s*=%s*Enum%.AutomaticSize%.[XY][XY]?")
			then
				issue(out, "wrap", path, "wrapped label relies on AutomaticSize Y")
			end
		end
		if
			string.find(source, 'e%("TextButton"')
			and string.find(source, "TextWrapped%s*=%s*true")
			and string.find(source, "AutomaticSize%s*=%s*Enum%.AutomaticSize%.Y")
		then
			issue(out, "wrap", path, "wrapped button relies on AutomaticSize Y")
		end
	end
	if
		string.find(source, "TextTruncate%s*=%s*Enum%.TextTruncate%.[A-Za-z]+")
		and not options.truncation[path]
	then
		issue(out, "truncation", path, "truncated text has no full-text interaction")
	end
	local smallest = options.minTextSize
	for _, viewport in options.viewports do
		local scale = options.scale(viewport.x, viewport.y)
		local modal = if options.modal[path] then options.modalScale else 1
		for _, fixture in options.fixtures[path] or {} do
			local effective = fixture.size * scale * modal
			if effective + 0.001 < smallest then
				issue(
					out,
					"min-size",
					path,
					string.format("%s at %s: %.2f < %.2f", fixture.name, viewport.name, effective, smallest)
				)
			end
			if fixture.width and not fixture.autoWidth then
				local width = fixture.width
				local chars = utf8.len(fixture.text) or #fixture.text
				local need = chars * fixture.size * options.glyphWidth
				if fixture.wrapped then
					local lines = math.ceil(need / width)
					if fixture.height and lines * fixture.size * 1.25 > fixture.height then
						issue(out, "wrap", path, fixture.name .. " fixed-height box cannot hold wrapped text")
					end
				elseif need > width then
					issue(out, "single-line", path, fixture.name .. " exceeds fixed width")
				end
			end
		end
	end
	return out
end

return Checker
