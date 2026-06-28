# Auth example

A standalone mini-project modelling **account sign-in policy** — password
strength and lockout. Branch-heavy validation like this is where suites reliably
test the happy path and a couple of obvious failures, then stop. Mutare turns
each of the gaps that leaves into a concrete survivor.

From the repo root:

```
mix mutare examples/auth
```

Expected (abridged):

```
mutare in examples/auth: 56 mutants across 1 file(s)

lib/auth/policy.ex:24  [relational, in-place]  SURVIVED
-    String.length(password) >= @min_length and
+    String.length(password) > @min_length and

lib/auth/policy.ex:24  [string_byte, in-place]  SURVIVED
-    String.length(password) >= @min_length and
+    Elixir.Kernel.byte_size(password) >= @min_length and

lib/auth/policy.ex:62  [regex, in-place]  SURVIVED
-  defp has_upper?(password), do: String.match?(password, ~r/[[:upper:]]/)
+  defp has_upper?(password), do: String.match?(password, ~r//)
...
mutation score: 83.7%  (41 killed, 8 survived, 7 no-coverage, 56 total)
```

Why those survive (or skip):

- **The length boundary (`>= @min_length` → `>`).** The suite only ever checks a
  clearly-long password (`"Secret123"`) and a clearly-short one (`"Ab1"`); no
  password of length 7 vs 8 is ever compared, so widening the comparison by one
  is invisible. A **missing boundary test** — the same gap [`calc`](../calc/)
  shows in miniature.
- **`String.length` → `byte_size` (the same line).** Both count 8 for every
  password in the suite, because every fixture is plain ASCII, where one
  character is one byte. A password with an accented letter near the threshold
  (`"Sécret1"` — 7 graphemes, 8 bytes) would tell grapheme-length from
  byte-length apart; nothing in the suite does. **Weak (all-ASCII) test data.**
- **The character-class checks (`~r/[[:upper:]]/` → `~r//`, and → `~r/[^...]/`).**
  An empty regex matches *any* string and a negated class matches the complement,
  so each of `has_upper?`/`has_lower?`/`has_digit?` becomes "always true" or
  "inverted". The only weak password in the suite, `"Ab1"`, is rejected on
  *length* before the classes ever matter — so no test isolates a long password
  missing exactly one class. Two survivors per class, all the same gap: nothing
  proves a character class is actually *required*. A test like
  `refute strong_password?("lowercase123")` (long, but no upper-case) closes it.
- **`attempts_left/1` has no test at all** (the 7 no-coverage skips). The
  coverage probe sees no test touch its line and leaves its mutants out of the
  score's denominator — they can never be killed, so they don't drag the number.

For contrast, two things are **pinned down**. `normalize_email/1`'s fixture has
both surrounding whitespace and mixed case, so dropping either `String` call — or
swapping `downcase` for `upcase` — changes the result and is killed. And the
`{email, password}` destructure in `authorize/2`'s `with` chain is mutated by
PatternSwap into `{password, email}`; the test's email (`"ada@example.com"`)
isn't itself a strong password, so the swapped roles change the outcome and that
mutant dies too.

> The character-class checks here use POSIX classes (`[[:upper:]]`), so each
> regex has a small, focused set of mutants. For the regex *range-boundary*
> lesson — `[a-z]` vs `[a-y]` — see [`text`](../text/).
