--!strict
-- Sibling ZIndex order: the panel and all descendants must be above the input sink.
return table.freeze({ backdrop = 50, body = 51, sink = 1, panel = 2, close = 3 })
