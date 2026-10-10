-- Extension regression: negative_unsafe_guard
relation p(1)
rule bad(?x) :- p(?x), where (?y > 0)
