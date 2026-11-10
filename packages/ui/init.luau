--!strict
--[[
	Shared UI kit (React-lua). OWNED BY AGENT F (core/f-ui). Required as ReplicatedStorage.UI.
	Games import components from here and never edit this package. See README.md.

	Components (React function components): Button, Panel, ItemCard, RarityBadge, Toast,
	ToastHost, Modal, CurrencyCounter, OddsTable, AutoScale.
	Pure helpers: Format (abbreviate / percent), Odds (rows), ToastQueue, Responsive. Theme.
]]

local UI = {}

UI.Theme = require(script.Theme)
UI.Format = require(script.Format)
UI.Odds = require(script.Odds)
UI.ToastQueue = require(script.ToastQueue)
UI.Responsive = require(script.Responsive)
UI.Primitives = require(script.Primitives)

UI.Button = require(script.Button)
UI.Panel = require(script.Panel)
UI.ItemCard = require(script.ItemCard)
UI.RarityBadge = require(script.RarityBadge)
UI.Toast = require(script.Toast)
UI.ToastHost = require(script.ToastHost)
UI.Modal = require(script.Modal)
UI.CurrencyCounter = require(script.CurrencyCounter)
UI.OddsTable = require(script.OddsTable)
UI.AutoScale = require(script.AutoScale)

return UI
