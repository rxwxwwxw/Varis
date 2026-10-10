-- EXPECT ERROR: ?x is never grounded by a positive relation atom.
relation room(1)
relation invalid(1)
fact room(:a)
rule invalid(?x) :- not room(?x)
error("UNEXPECTED SUCCESS: unsafe rule was accepted")
