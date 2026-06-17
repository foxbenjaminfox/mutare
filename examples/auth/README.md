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
mutare in examples/auth: 43 mutants across 1 file(s)

lib/auth/policy.ex:19  [relational, in-place]  SURVIVED
-    String.length(password) >= @min_length and
+    String.length(password) > @min_length and

lib/auth/policy.ex:37  [regex, in-place]  SURVIVED
-  defp has_upper?(password), do: String.match?(password, ~r/[A-Z]/)
+  defp has_upper?(password), do: String.match?(password, ~r//)

lib/auth/policy.ex:39  [return_value, in-place]  SURVIVED
-  defp has_digit?(password), do: String.match?(password, ~r/[0-9]/)
+  defp has_digit?(password), do: :mutare
...
mutation score: 86.8%  (33 killed, 5 survived, 5 no-coverage, 43 total)
```

Why those survive (or skip):

- **The length boundary (`>= @min_length` → `>`).** The suite only ever checks a
  clearly-long password (`"Secret123"`) and a clearly-short one (`"Ab1"`); no
  password of length 7 vs 8 is ever compared, so widening the comparison by one
  is invisible. A **missing boundary test**.
- **The character-class checks (`~r/[A-Z]/` → `~r//`).** An empty regex matches
  *any* string, so each of `has_upper?`/`has_lower?`/`has_digit?` becomes
  "always true". The only weak password in the suite, `"Ab1"`, is rejected on
  *length* before the classes matter — so no test ever isolates a long password
  that is missing exactly one class. Three survivors, one per class.
- **`has_digit?` forced to a truthy sentinel (`return_value` → `:mutare`).** The
  return-value mutant replaces the body with a non-`nil`/non-`false` value. Since
  `has_digit?` is only ever *true* on the happy path, and the failing test fails
  earlier, the substitution is never observed. (The matching `nil`/`false`
  variant *is* killed — it breaks the happy path.)
- **`attempts_left/1` has no test at all** (the 5 no-coverage skips). The
  coverage probe sees no test touch its line and leaves its mutants out of the
  score's denominator — they can never be killed, so they don't drag the number.

For contrast, `normalize_email/1` is **pinned down**: its fixture has both
surrounding whitespace and mixed case, so dropping either `String` call — or
swapping `downcase` for `upcase` — changes the result and is killed.
