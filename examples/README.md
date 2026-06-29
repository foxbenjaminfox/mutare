# Examples

Each subdirectory is a **standalone mini-project** — its own `mix.exs`, source,
and test suite — used as a target for Mutare. Clone the repo and run any of them
from the root, no setup required (they have no dependencies):

```
mix mutare examples/calc      # start here
mix mutare examples/auth
mix mutare examples/stats
mix mutare examples/text
mix mutare examples/shop      # the comprehensive one
```

Every example has **partial test coverage on purpose**, so each run surfaces
real survivors. The point isn't the score — it's *what the survivors teach*. Each
project's `README.md` walks through its survivors and the test-quality gap behind
each one. They're ordered here from the very simple to the quite complex:

| Example | Domain | What it demonstrates |
| --- | --- | --- |
| [`calc`](calc/) | Shipping cost | **The 30-second introduction.** One function, one survivor: the canonical off-by-one boundary (`>= 50` → `> 50`) that survives because no test sits on the line. |
| [`auth`](auth/) | Sign-in policy | Boolean validation: a length boundary, all-ASCII test data (`String.length` vs `byte_size`), character-class checks that are never the deciding factor, in-place vs lifted (`when` guard) mutants, and an untested helper (no-coverage). |
| [`stats`](stats/) | Numeric aggregation | Collection-shaped mutators (`sort`/`reverse`/arity), an untested empty-input clause, a *coincidental equivalent* (`div`/`rem`), commutative vs non-commutative pattern swaps, and a guard with no boundary test. |
| [`text`](text/) | Text formatting | String/Regex literals: a regex *range boundary* (`[a-z]` vs `[a-y]`), a removable no-op transform, an off-by-one truncation length, and a guard never approached near its threshold. |
| [`shop`](shop/) | A multi-module shop | **The comprehensive one.** Exercises *every* built-in mutator family across six files, and tours the `.mutare.exs` config surface — choosing mutators, skipping a macro's arguments (`macro_routes:`), and suppressing known-equivalent mutants with `# mutare:ignore`. |

The lessons compound: the same handful of gaps — **missing boundary tests**,
**weak test data**, **untested branches**, and **coincidental equivalents** — is
what mutation testing is built to find, whether in a four-line function or a
six-module application.
