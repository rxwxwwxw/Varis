-- Extension regression: negative_self_negation
relation p(1) relation q(1)
rule q(?x) :- p(?x), not q(?x)
