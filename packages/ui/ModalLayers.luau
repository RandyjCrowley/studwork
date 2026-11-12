--!strict
-- UI.Modal's ZIndex layers. Under ZIndexBehavior.Sibling (required; the kit's ScreenGuis use it)
-- the panel and all its descendants are above the input sink. The close button stays above the
-- backdrop too, so it shows and works even in a Global ScreenGui (as in v1.6.1), where the panel's
-- own contents can't (UI.Modal warns there).
return table.freeze({ backdrop = 50, body = 51, sink = 1, panel = 2, close = 60 })
