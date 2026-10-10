-- Deck configuration (§9). The exploration hub shows everything that is
-- available; the market draws a random, non-repeating selection of wares;
-- conversation shows a few topics at a time.
deck :default { draw = 12, replacement = true }
deck :market  { draw = 3,  replacement = false }
deck :talk    { draw = 4,  replacement = true }
deck :ending  { draw = 1,  replacement = true }
