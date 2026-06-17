# Text example

A standalone mini-project of **text-formatting helpers** — slug, word count,
excerpt. Built around String and Regex literals, it shows the survivors a
transformation-heavy suite usually misses: an off-by-one in the truncation
length, a guard whose boundary is never approached, and a separator that only
matters for inputs the tests never feed in.

From the repo root:

```
mix mutare examples/text
```

Expected (abridged):

```
mutare in examples/text: 30 mutants across 1 file(s)

lib/text/format.ex:15  [call_removal, in-place]  SURVIVED
-    |> String.trim()
+    |> Function.identity()

lib/text/format.ex:27  [relational, in-place]  SURVIVED
-    if String.length(text) <= max do
+    if String.length(text) < max do

lib/text/format.ex:26  [relational, lifted]  SURVIVED
-  def excerpt(text, max) when max > 0 do
+  def excerpt(text, max) when max >= 0 do
...
mutation score: 80.0%  (24 killed, 6 survived, 30 total)
```

Why those survive:

- **`String.trim()` is removable in `slugify` (`call_removal`).** The only
  fixture, `"Hello, World!"`, has no surrounding whitespace, so the trim is
  already a no-op — deleting it changes nothing. The transform only earns its
  keep on input the test never supplies. **Untested input shape.**
- **The truncation boundary (`<= max` → `< max`).** `excerpt/2` is tested well
  below the limit (a 5-char string, `max: 20`) and well above it (`max: 9`), but
  never with a string whose length is *exactly* `max` — the one input that tells
  `<=` from `<`. A **missing boundary test**.
- **The `max > 0` guard (→ `>= 0`, → `> 1`, → `> -1`, → `true`).** Every call
  passes a comfortably-positive `max`, so the guard is never exercised near its
  threshold; its exact cut-off (and whether it's even needed) is unverified.
  Four survivors all pointing at the same gap — **the guard's boundary is never
  approached.**

For contrast, the slug is **pinned** where it counts: dropping `String.downcase`,
swapping it for `upcase`, emptying the `~r/[^a-z0-9]+/` class, or swapping it for
`~r/mutare/` all change the output for `"Hello, World!"`, so each of those is
killed.
