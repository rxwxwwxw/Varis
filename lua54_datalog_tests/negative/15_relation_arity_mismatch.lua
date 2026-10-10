-- EXPECT ERROR: edge is a binary relation, not unary.
relation edge(2)
fact edge(:a)
error("UNEXPECTED SUCCESS: arity mismatch was accepted")
