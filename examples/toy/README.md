# Toy example

A standalone mini-project used to demonstrate Mutare. It has **partial test
coverage on purpose**, so running Mutare against it surfaces real survivors.

From the repo root:

```
mix mutare examples/toy
```

Expected (abridged):

```
mutare in examples/toy: 13 mutants across 1 file(s)
.-..SS.SS.S..

lib/toy/cart.ex:20  [relational, lifted]  SURVIVED
-  def apply_discount(amount, percent) when percent >= 0 and percent <= 100 do
+  def apply_discount(amount, percent) when percent >= 0 and percent < 100 do

lib/toy/cart.ex:26  [relational, in-place]  SURVIVED
-    subtotal >= @free_shipping_threshold
+    subtotal > @free_shipping_threshold
...
mutation score: 58.3%  (7 killed, 5 survived, 1 no-coverage, 13 total)
```

The `-` in the progress line is a **no-coverage** skip, and it's excluded from
the score's denominator (13 − 1 = 12).

Why those survive (or skip):

- `apply_discount/2` is only exercised with `percent: 0`, which zeroes the
  discount term — so `-`/`/` mutations there are indistinguishable from the
  original (**weak test data**).
- The `when` guard in `apply_discount/2` is mutated via **function lifting**
  (`[lifted]`): a `case` can't live in a guard, so Mutare duplicates the clause
  and dispatches. Its bounds (`>= 0`, `<= 100`) are never tested away from the
  `percent: 0` happy path, so the widening mutants survive (**missing boundary
  tests**).
- `free_shipping?/1` is never tested at/above the threshold, so `>= -> >` slips
  through (**missing boundary test**).
- `late_fee/1` has **no test at all**, so its mutant is on a line no test runs.
  The coverage probe marks it **no-coverage** and skips it (it can never be
  killed, so it doesn't drag the score).
