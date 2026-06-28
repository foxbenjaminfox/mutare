# Stats example

A standalone mini-project computing **summary statistics** over a list of
numbers — mean, median, top-N, midrange, spread, clamp. The code is dense with
`Enum`/`List` calls and destructured pairs, so it exercises the
collection-shaped mutators (Collection, CollectionArity, CallRemoval) and
PatternSwap, and the boundaries they expose.

From the repo root:

```
mix mutare examples/stats
```

Expected (abridged):

```
mutare in examples/stats: 76 mutants across 1 file(s)

lib/stats/series.ex:21  [clause_drop, lifted]  SURVIVED
-  def median([]), do: nil

lib/stats/series.ex:26  [arithmetic, in-place]  SURVIVED
-    mid = div(count, 2)
+    mid = rem(count, 2)

lib/stats/series.ex:47  [pattern_swap, in-place]  SURVIVED
-    {low, high} = Enum.min_max(values)
+    {high, low} = Enum.min_max(values)
...
mutation score: 93.4%  (71 killed, 5 survived, 76 total)
```

Why those survive:

- **The empty-series clause is droppable (`clause_drop` on `median([])`).**
  `median/1` is never called with `[]`, so deleting its base clause is
  undetectable. An **untested input branch** — the empty list is a documented
  case with no test behind it. (`mean/1`, `midrange/1`, and `spread/1` each have
  an empty-list test, so *their* base clauses are killed; `median([])` is the one
  that was forgotten — exactly the asymmetry mutation testing is good at exposing.)
- **`div(count, 2)` → `rem(count, 2)` is a *coincidental equivalent* here.** A
  passing test only kills a mutant that changes an *observed value*, and on both
  fixtures the two operators happen to land on the same median: counts 3 and 4
  give `div`/`rem` of `1`/`1` and `2`/`0`, and at those indices the answer is
  identical. A 5-element series (`div(5,2) = 2` but `rem(5,2) = 1`) would pick a
  different middle and kill it — a reminder that **which data you test matters as
  much as how many cases.**
- **The `{low, high}` swap in `midrange/1` (`pattern_swap`).** The destructured
  pair feeds a *commutative* `+`, so swapping the bindings to `{high, low}` can't
  change the average — a textbook survivor. The *identical* swap in `spread/1`
  feeds a non-commutative `-`, so an asymmetric fixture negates the result and
  kills it: the contrast between the two is the lesson.
- **The `clamp` guard (`low <= high` → `low < high`, and → `true`).** `clamp/3`
  is tested inside the range and past each end, but never with `low == high`, and
  never with an *invalid* range (`low > high`) — so neither the boundary nor the
  guard's protective role is verified. **Missing boundary / missing
  precondition test.**

For contrast, `top/2` is **pinned hard**: its fixture is unsorted with
duplicates, so dropping the sort, reversing it (`Enum.reverse` acts on the
*unsorted* input, not the sorted one), or flipping `:desc` all change the result
— every one of those mutants is killed.
