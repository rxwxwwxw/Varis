-- Extension regression: comparison_nan_constants
relation p(1) fact p(1)
local nan = 0 / 0
reject(function() local q = query {p(?x), ?x ~= nan} end, "NaN")
reject(function() rule bad(?x) :- p(?x), ?x ~= nan end, "NaN")
