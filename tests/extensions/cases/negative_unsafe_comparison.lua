-- Extension regression: negative_unsafe_comparison
relation p(1)
rule bad(?x) :- p(?x), ?y == 1
