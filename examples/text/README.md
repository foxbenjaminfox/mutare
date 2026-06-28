# Text example

A standalone mini-project of **text-formatting helpers** — slug, word count,
excerpt. Built around String and Regex literals, it shows the survivors a
transformation-heavy suite usually misses: the exact edges of a regex character
class, an off-by-one in a truncation length, and a transform that only matters
for inputs the tests never feed in.

From the repo root:

```
mix mutare examples/text
```

Expected (abridged):

```
mutare in examples/text: 42 mutants across 1 file(s)

lib/text/format.ex:18  [call_removal, in-place]  SURVIVED
-    |> String.trim()
+    |> Elixir.Function.identity()

lib/text/format.ex:19  [regex, in-place]  SURVIVED
-    |> String.replace(~r/[^a-z0-9]+/, "-")
+    |> String.replace(~r/[^a-{0-9]+/, "-")

lib/text/format.ex:30  [relational, in-place]  SURVIVED
-    if String.length(text) <= max do
+    if String.length(text) < max do
...
mutation score: 88.1%  (37 killed, 5 survived, 42 total)
```

Why those survive:

- **The regex *range boundary* (`[^a-z0-9]` → `[^a-{0-9]`, → `` [^`-z0-9] ``).**
  This is the headline. The suite proves that separators collapse to a hyphen and
  that `a`, `z`, `0`, `9` are kept — so shrinking the class (`a-z` → `a-y`) or
  growing it into a realistic neighbour (`0-9` → `0-:`, i.e. keeping a colon) is
  caught. What survives is the class growing into a character no slug input ever
  contains: a backtick (just below `a`) or a brace (just above `z`). The mutant
  changes the class by one code point, and *no test exercises that exact edge* —
  the regex twin of [`calc`](../calc/)'s `>= 50` → `> 50`. Two survivors, both
  near-equivalent; pinning the rest took one fixture with characters sitting on
  the class boundaries.
- **`String.trim()` is removable in `slugify` (`call_removal`).** Neither fixture
  has surrounding whitespace, so the trim is already a no-op — deleting it changes
  nothing. The transform only earns its keep on input the test never supplies.
  **Untested input shape.**
- **The truncation boundary (`<= max` → `< max`).** `excerpt/2` is tested well
  below the limit (a 5-char string, `max: 20`) and well above it (`max: 9`), but
  never with a string whose length is *exactly* `max` — the one input that tells
  `<=` from `<`. A **missing boundary test**.
- **`String.length` → `byte_size` (same line).** Every fixture is ASCII, where one
  character is one byte, so the two agree. A multi-byte string near the limit
  would tell them apart. **Weak (all-ASCII) test data** — the same gap
  [`auth`](../auth/) shows on its length check.

For contrast, the slug is **pinned** where it counts: dropping `String.downcase`,
swapping it for `upcase`, emptying the `~r/[^a-z0-9]+/` class, or swapping it for
`~r/mutare/` all change the output, so each of those is killed — as is
`word_count/1`, whose fixture has four plainly-separated words.
