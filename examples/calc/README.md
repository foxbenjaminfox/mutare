# Calc example

The smallest example — **one function, one survivor**. Start here: the whole run
fits on a screen, and every line of output points at the same missing test.

`Calc.total/1` adds shipping to an order subtotal: free once the subtotal reaches
$50, a flat $5 otherwise. The suite checks one order on each side of the
threshold — which *feels* complete.

From the repo root:

```
mix mutare examples/calc
```

Expected:

```
mutare in examples/calc: 9 mutants across 1 file(s)

lib/calc.ex:17  [relational, in-place]  SURVIVED
-    shipping = if subtotal >= @free_shipping_over, do: 0, else: @flat_fee
+    shipping = if subtotal > @free_shipping_over, do: 0, else: @flat_fee

mutation score: 88.9%  (8 killed, 1 survived, 9 total)
```

Eight of the nine mutants die: break the arithmetic (`+` → `-`), force the
condition to a constant (`if true` / `if false`), or replace the body with a
sentinel, and one of the two tests notices. One mutant survives.

**The survivor: `>= 50` → `> 50`.** The two operators differ on exactly one
input — a subtotal of *precisely* 50. The suite checks 80 (free) and 20 (flat),
so it never visits the boundary, and widening the comparison by one is invisible.
This is the canonical mutation-testing finding: a **missing boundary test**.

To kill it, test the boundary itself:

```elixir
test "an order exactly at the threshold ships free" do
  assert Calc.total(50) == 50
end
```

Add that and the run goes to **100.0% (9 killed, 0 survived)** — the survivor is
gone, and so is the real gap it stood for. That's the whole loop: a survivor is a
precise, located test you haven't written yet.

When this clicks, read [`auth`](../auth/) next — the same idea over branch-heavy
validation logic.
