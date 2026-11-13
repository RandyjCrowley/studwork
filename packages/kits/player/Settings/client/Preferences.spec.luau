local Preferences = require(script.Parent.Preferences)
describe("accessibility preferences", function()
	it("maps all exposed platform text enum names without treating them as numbers", function()
		expect(Preferences.textScale("platform", "Enum.PreferredTextSize.Medium")).toBe(1)
		expect(Preferences.textScale("platform", "Enum.PreferredTextSize.Large")).toBe(1.15)
		expect(Preferences.textScale("platform", "Enum.PreferredTextSize.Larger")).toBe(1.35)
		expect(Preferences.textScale("platform", "Enum.PreferredTextSize.Largest")).toBe(1.5)
		expect(Preferences.textScale("standard", "Enum.PreferredTextSize.Largest")).toBe(1)
	end)
	it("applies attributes and group gain, reads current defaults and disconnects listeners", function()
		local listeners, attrs, groups = {}, {}, {}
		local disconnected = 0
		local player = {
			SetAttribute = function(_, id, value)
				attrs[id] = value
			end,
		}
		local gui = {
			ReducedMotionEnabled = true,
			PreferredTextSize = "Largest",
			GetPropertyChangedSignal = function(_, id)
				return {
					Connect = function(_, fn)
						listeners[id] = fn
						return {
							Disconnect = function()
								disconnected += 1
							end,
						}
					end,
				}
			end,
		}
		local sounds = {
			FindFirstChild = function(_, name)
				return groups[name]
			end,
		}
		local p = Preferences.new({
			player = player,
			gui = gui,
			sounds = sounds,
			audio = { musicGroup = "Music", effectsGroup = "Effects" },
			refreshDefault = function() end,
			createGroup = function()
				local group = {
					IsA = function(_, class)
						return class == "SoundGroup"
					end,
				}
				return setmetatable(group, {
					__newindex = function(t, k, v)
						rawset(t, k, v)
						if k == "Parent" then
							groups[t.Name] = t
						end
					end,
				})
			end,
		})
		expect(p.default({ id = "reduceMotion", default = false })).toBe(true)
		p.apply("effectsVolume", 0.3)
		expect(groups.Effects.Volume).toBe(0.3)
		expect(attrs.CoreEffectsGroup).toBe("Effects")
		p.apply("uiScale", 0.8)
		expect(attrs.CoreUIScale).toBe(0.8)
		p.apply("textSize", "platform")
		expect(attrs.CoreTextScale).toBe(1.5)
		gui.PreferredTextSize = "Medium"
		listeners.PreferredTextSize()
		expect(attrs.CoreTextScale).toBe(1)
		p.destroy()
		expect(disconnected).toBe(2)
	end)
end)
