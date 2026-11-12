--!strict
--[[
	Pure text-fit rules for the UI kit (v1.3.0, playtest finding: with a wider
	display font such as LuckiestGuy the action-bar text "Upgrade income (50)" overflowed its
	button). Text must fit its box for ANY theme font:

	  - auto-width text (a Button with no size): the button's minimum width is the text's measured
	    width in the real font (TextService:GetTextBoundsAsync) plus padding and icon, so it can
	    never be narrower than its text. With the default font this equals the automatic width, so
	    the default look is unchanged (TextFit.spec golden test).
	  - fixed-width text (a `size` was given, a table cell): TextScaled with a UITextSizeConstraint
	    whose MaxTextSize is the theme size, so the text renders at the theme size when it fits and
	    shrinks (down to MIN_TEXT_SIZE) when it doesn't.

	TextFit.fixedLabel(maxSize, minSize?) -> { TextScaled = true, TextSize, MinTextSize, MaxTextSize }
	TextFit.autoLabel(size)     -> { TextScaled = false, TextSize }   (unchanged from v1.2)
	TextFit.buttonMinWidth(textWidth, opts) -> number   opts: { padding, iconWidth?, gap?, minWidth }
]]

local TextFit = {}

-- Smallest size fixed-width text may shrink to (readable on a phone).
TextFit.MIN_TEXT_SIZE = 9

export type LabelFit = {
	TextScaled: boolean,
	TextSize: number,
	MinTextSize: number?,
	MaxTextSize: number?,
}

-- minSize: optional floor (the theme's text.min token); defaults to MIN_TEXT_SIZE.
function TextFit.fixedLabel(maxSize: number, minSize: number?): LabelFit
	local floor = if type(minSize) == "number" and minSize > 0 then minSize else TextFit.MIN_TEXT_SIZE
	return {
		TextScaled = true,
		TextSize = maxSize,
		MinTextSize = math.min(floor, maxSize),
		MaxTextSize = maxSize,
	}
end

function TextFit.autoLabel(size: number): LabelFit
	return { TextScaled = false, TextSize = size }
end

-- Width a button needs to show `textWidth` px of text: both paddings, the icon and the gap,
-- never below opts.minWidth (the touch target). Rounded up to whole pixels.
function TextFit.buttonMinWidth(
	textWidth: number,
	opts: { padding: number, iconWidth: number?, gap: number?, minWidth: number }
): number
	if type(textWidth) ~= "number" or textWidth ~= textWidth or textWidth < 0 or textWidth == math.huge then
		return opts.minWidth
	end
	local icon = opts.iconWidth or 0
	local gap = if icon > 0 then (opts.gap or 0) else 0
	return math.max(opts.minWidth, math.ceil(textWidth + 2 * opts.padding + icon + gap))
end

return table.freeze(TextFit)
