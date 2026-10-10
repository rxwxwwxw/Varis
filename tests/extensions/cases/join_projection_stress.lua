-- Extension regression: join_projection_stress
relation leftside(2) relation rightside(2)
for i = 1, 20 do for j = 1, 12 do
    fact leftside(i, j) fact rightside(j, i)
end end
assert(count(query {leftside(?x, ?_), rightside(?_, ?x)}) == 20)
assert(count(query {leftside(?x, ?k), rightside(?k, ?y)}) == 20 * 12 * 20)
assert(count(query {leftside(?x, ?k), rightside(?k, ?x)}) == 20 * 12)
