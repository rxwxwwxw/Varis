-- bench: sieve of Eratosthenes to 100k
local max = 100000
local is_prime = {}
for i = 2, max do is_prime[i] = true end
for p = 2, math.floor(math.sqrt(max)) do
  if is_prime[p] then
    for i = p * p, max, p do is_prime[i] = false end
  end
end
local count = 0
for i = 2, max do if is_prime[i] then count = count + 1 end end
assert(count == 9592)
