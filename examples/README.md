# Examples

Each subdirectory is a **standalone mini-project** — its own `mix.exs`, source,
and test suite — used as a target for Mutare. Run any of them from the repo root:

```
mix mutare examples/auth
mix mutare examples/stats
mix mutare examples/text
```

Every example has **partial test coverage on purpose**, so each run surfaces
real survivors. The point isn't the score — it's *what the survivors teach*. Each
project's `README.md` walks through its survivors and the test-quality gap behind
each one.

| Example | Domain | What it demonstrates |
| --- | --- | --- |
| [`auth`](auth/) | Sign-in policy | Boolean validation: the `and`/`or` seams between rules, length boundaries, regex character-class checks, in-place vs lifted (`when` guard) mutants, and an untested helper (no-coverage). |
| [`stats`](stats/) | Numeric aggregation | Collection-shaped mutators (`sort`/`reverse`/arity), an untested empty-input clause, a *coincidental equivalent*, and a guard with no boundary test. |
| [`text`](text/) | Text formatting | String/Regex literals: an off-by-one truncation boundary, a removable no-op transform, and a guard never approached near its threshold. |

The lessons compound: the same handful of gaps — **missing boundary tests**,
**weak test data**, **untested branches**, and **coincidental equivalents** — is
what mutation testing is built to find.
