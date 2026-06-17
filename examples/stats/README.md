# Stats example

A standalone mini-project computing **summary statistics** over a list of
numbers — mean, median, top-N, clamp. The code is dense with `Enum`/`List`
calls, so it exercises the collection-shaped mutators (Collection,
CollectionArity, CallRemoval) and the boundaries they expose.

From the repo root:

```
mix mutare examples/stats
```

Expected (abridged):

```
mutare in examples/stats: 47 mutants across 1 file(s)

lib/stats/series.ex:18  [clause_drop, lifted]  SURVIVED
-  def median([]), do: nil

lib/stats/series.ex:23  [arithmetic, in-place]  SURVIVED
-    mid = div(count, 2)
+    mid = rem(count, 2)

lib/stats/series.ex:38  [relational, lifted]  SURVIVED
-  def clamp(value, low, high) when low <= high do
+  def clamp(value, low, high) when low < high do
...
mutation score: 91.5%  (43 killed, 4 survived, 47 total)
```

Why those survive:

- **The empty-series clause is droppable (`clause_drop` on `median([])`).**
  `median/1` is never called with `[]`, so deleting its base clause is
  undetectable. An **untested input branch** — the empty list is a documented
  case with no test behind it.
- **`div(count, 2)` → `rem(count, 2)` is a *coincidental equivalent* here.** A
  passing test only kills a mutant that changes an *observed value*, and on both
  fixtures the two operators happen to land on the same median: counts 3 and 4
  give `div`/`rem` of `1`/`1` and `2`/`0`, and at those indices the answer is
  identical. A 5-element series (`div(5,2) = 2` but `rem(5,2) = 1`) would pick a
  different middle and kill it — a reminder that **which data you test matters as
  much as how many cases.**
- **The `clamp` guard (`low <= high` → `low < high`, and → `true`).** `clamp/3`
  is tested inside the range and past each end, but never with `low == high`, and
  never with an *invalid* range (`low > high`) — so neither the boundary nor the
  guard's protective role is verified. **Missing boundary / missing
  precondition test.**

For contrast, `top/2` is **pinned hard**: its fixture is unsorted with
duplicates, so dropping the sort, reversing it (`Enum.reverse` acts on the
*unsorted* input, not the sorted one), or flipping `:desc` all change the result
— every one of those mutants is killed.
