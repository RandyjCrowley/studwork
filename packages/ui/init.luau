--!strict
--[[
	Shared UI kit (React-lua). OWNED BY AGENT F (core/f-ui).

	PHASE 0 STUB: exports the Theme only. Agent F adds Button, Panel, ItemCard, RarityBadge,
	Toast, Modal, CurrencyCounter, OddsTable (mobile first, themed from the palette).
	Games import components from here and never edit this package.
]]

local UI = {}

UI.Theme = require(script.Theme)

return UI
