--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Screen = require(ReplicatedStorage.Modules.Companions.client.Screen)
local Model = require(ReplicatedStorage.Modules.Companions.client.ScreenModel)
local Responsive = require(ReplicatedStorage.UI.Responsive)
local ModalFit = require(ReplicatedStorage.UI.ModalFit)

describe("Companions screen integration boundary", function()
	it("registers without calling a runtime facade during boot", function()
		local registered, widgets = {}, {}
		local UI = {
			screens = {
				get = function()
					return nil
				end,
			},
			registerScreen = function(name, component)
				registered[name] = component
			end,
			widgets = function()
				return {}, {}
			end,
			registerWidget = function(id, spec)
				widgets[id] = spec
			end,
		}
		Screen.init({ config = { slots = 3 }, gameConfig = { items = {} } })
		Screen.register(UI)
		expect(type(registered.Companions)).toBe("function")
		expect(widgets["Companions.open"].slot).toBe("topCenter")
		expect(widgets["Companions.open"].order).toBe(30)
	end)
	it("preserves game screen and widget replacements and removals", function()
		local function forbidden()
			error("override replaced")
		end
		for _, removed in { false, true } do
			Screen.register({
				screens = {
					get = function()
						return forbidden
					end,
				},
				registerScreen = forbidden,
				widgets = function()
					return if removed then {} else { ["Companions.open"] = {} },
						if removed then { ["Companions.open"] = false } else {}
				end,
				registerWidget = forbidden,
			})
		end
	end)
	it("keeps touch targets at least 44 physical pixels on phone and desktop", function()
		for _, viewport in { { 667, 375 }, { 375, 667 }, { 1920, 1080 } } do
			local scale = Responsive.scale(viewport[1], viewport[2])
			local layout = Model.layout(Responsive.touchTarget(44))
			local width, height = viewport[1] / scale, viewport[2] / scale
			local fit = ModalFit.fitScale(
				math.clamp(width * layout.width, 320, 640),
				math.min(height * layout.height, 560),
				width,
				height
			)
			expect(layout.target * scale * fit >= 44).toBe(true)
			expect(layout.rowHeight >= layout.cardHeight + layout.target).toBe(true)
		end
	end)
end)
