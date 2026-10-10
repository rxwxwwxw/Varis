-- EXPECT ERROR: negative recursion prevents stratification.
relation domain(1)
relation a(1)
relation b(1)
fact domain(:x)
rule a(?x) :- domain(?x), not b(?x)
rule b(?x) :- domain(?x), not a(?x)
error("UNEXPECTED SUCCESS: unstratified rules were accepted")
