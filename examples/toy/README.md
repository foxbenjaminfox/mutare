# Toy example

A standalone mini-project used to demonstrate Mutare. It has **partial test
coverage on purpose**, so running Mutare against it surfaces real survivors.

From the repo root:

```
mix mutare examples/toy
```

Expected (abridged):

```
mutare in examples/toy: 8 mutants across 1 file(s)
...SSS..

lib/toy/cart.ex:21  [arithmetic, in-place]  SURVIVED
-    amount - amount * percent / 100
+    amount + amount * percent / 100
...
mutation score: 62.5%  (5 killed, 3 survived, 8 total)
```

Why those survive:

- `apply_discount/2` is only exercised with `percent: 0`, which zeroes the
  discount term — so `-`/`/` mutations there are indistinguishable from the
  original (**weak test data**).
- `free_shipping?/1` is never tested at/above the threshold, so `>= -> >` slips
  through (**missing boundary test**).
- The `when` guard in `apply_discount/2` is **not** mutated — in-place mutators
  skip guards (that's the lifted mechanism, a later milestone).
