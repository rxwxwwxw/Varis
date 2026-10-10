-- Extension regression: negative_unsafe_negation
relation p(1) relation q(1)
rule bad(?x) :- p(?x), not q(?y)
