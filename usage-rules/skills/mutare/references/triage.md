# Triage: what a survivor says, and what kills it

Each survivor in the human report is headed `file:line:column  [family, delivery]  SURVIVED`.
The column tells apart two mutants on one line whose change reads the same, such as
the two `"id"` literals of `{"id", stored["id"]}` each emptied to `""`.
The family says which kind of change survived. The delivery (`in-place` or
`lifted`) records how Mutare embedded the mutant and says nothing about the test
gap. For a family's exact swap table, run `mix mutare --explain <family>`; this page
records what each family's survivors usually mean in practice.

## By family

| Family | A survivor usually means | A test that kills it |
|---|---|---|
| `relational`, `integer`, `float` | No test sits on the boundary value, or no test pins the constant (a limit, a threshold, a default). | Inputs exactly at the boundary and one step either side. |
| `conditional`, `if_condition` | In the tests, this condition never decides the outcome. In an `a and b and c` chain, some conjunct is never the only one that fails. | An input where this condition alone flips the result. |
| `logical` | No test has operands that disagree, where `and` and `or` give different answers. | One operand true, the other false. |
| `arithmetic` | `+`↔`-` survives when an operand is always 0 in the tests; `*`↔`/` when it is always 1. | Non-trivial operands. |
| `operand_swap` | The tests use equal operands, or the result is insensitive to their order. | Distinct operands whose order matters. |
| `strict_equality` | No test compares an integer with the equal float (`1` against `1.0`). | That comparison, if the distinction is part of the contract. If it isn't, the `===` may be unintentional. |
| `string_byte` | All test strings are ASCII, where `String.length` and `byte_size` agree. | A multi-byte input such as `"héllo"`. |
| `call_removal` | The transform (`sort`, `uniq`, `trim`, `downcase`, `Map.delete`, …) never changes the test input: it is already sorted, unique, trimmed. | Input the transform changes. If no reachable input can be changed, the call is redundant. |
| `collection`, `collection_arity`, `map_keyword`, `string_call`, `numeric`, `map_set`, `integer_call`, `math`, `temporal_order`, `period_boundary`, `mode_swap` | The paired operations agree on the test data: `filter` and `reject` on a list where every element passes, `put` and `put_new` when the key is never already present, `min` and `max` of one element. | Data on which the pair disagrees; `--explain` names the pairs. |
| `default_drop` | The fallback value is never used: the key is always present, the index always in range. | A lookup that misses. If a miss cannot happen, the fallback is dead code. |
| `return_value` | Nothing inspects this return path's value, or the assertions are too loose to tell the replacement apart (`nil`/`:mutare`, `0`/`1`, `""`/`"mutare"`, `[]`/`[:mutare]`). | An assertion on the value with `==` or a pattern match. `refute` accepts `nil` as readily as `false`. |
| `convention` | Tests ignore the tag: `{:ok, v}` and `{:error, v}` both pass, often through `{_, v} = …`. `{:cont, _}`↔`{:halt, _}` survives when no test needs the early stop. | Match the tag, and for `reduce_while` supply input where stopping early matters. |
| `atom` | The atom's identity isn't observed: a status, key, or option that no test compares. | An assertion on the atom, or on behaviour that depends on it. |
| `string`, `charlist`, `string_sigil`, `word_list` | The text isn't asserted, typically message text. | Assert it if the text is part of the contract (a user-facing error). If it isn't, accept the survivor or suppress it with a reason. |
| `regex` | One component of the pattern (a class, an anchor, a quantifier) never decides a match in the tests. `~r/[[:upper:]]/` → `~r//` surviving means no test input lacks an uppercase letter while passing every other check. | An input that fails only because of that component. |
| `map`, `tuple`, `bitstring`, `list` (`empty`) | The collapsed structure is never read. | An assertion on its contents. |
| `alias` | A module passed as a value (a strategy, an adapter, an `is_struct` check) is never invoked or compared in the tests. | A test that goes through that module. |
| `guard_drop` | No test calls with an argument the guard rejects, or the rejected input would behave the same without the guard. | A call with a rejected argument, asserting what should happen (often a different clause's result, or a `FunctionClauseError`). |
| `clause_drop` | The dropped clause's inputs are untested, or a later clause gives the same result for them, which makes the clause redundant. | An input only this clause handles, with an assertion that tells its result from the fallthrough's. |
| `pattern_swap` | The tests use equal values for both swapped positions. | Distinct values in those positions. |
| `pattern_wildcard` | The equality a repeated variable enforces (`def f(x, x)`) is never tested with unequal values. | A call with values that differ. |
| `rescue_type` | The narrowed exception type is never raised in the tests. | A test that triggers that exception. |
| `genserver` | Tests call the server but don't observe the callback's return form, such as whether a reply arrives or the process keeps running. | Assert the reply, and that the process is still alive (or has stopped) afterwards. |
| `bitwise`, `bitstring_spec`, `datetime`, `boolean`, `list` | Same pattern: the test data never exercises the difference. | See `--explain <family>`. |

## Equivalent, or merely hard to kill?

Suppress a survivor only when *no input* can tell the mutant apart from the original.
Mutare already avoids emitting the equivalents it can recognise without context (a
right-hand `* 1`, a `default_drop` whose explicit value equals the default), so what
reaches you needs an argument. Common cases that are truly equivalent:

- A boundary where both branches agree: `if x < 0, do: 0, else: x` under `<` → `<=`.
- `string_byte` on input that is ASCII by construction (hex digests, validated
  identifiers).
- A fallback that construction makes unreachable (a key the same function inserted
  a line earlier), or a transform applied to data that is already in that shape.
  These are also redundant code; removing the code is often the better fix, and the
  user's call to make.

These look equivalent but are not, so kill them instead:

- A mutant that is equivalent *on the data the tests happen to use*, such as
  `div`↔`rem` agreeing on one specific input. Change the data.
- `~r/…/u` → `~r/…/`: the `/u` form raises on invalid UTF-8, so an input exists that
  tells them apart.
- `x + 0.0` → `x - 0.0`: these differ on `-0.0`.
- Anything that differs only under load or timing, such as a timeout literal. Those
  verdicts can vary between runs; `--kill-runs 2` requires every kill to repeat.

## Suppression recipes

```elixir
# one kind of one family, with the reason
if x < 0, do: 0, else: x  # mutare:ignore[relational:<=] both branches return 0 at x = 0

# a whole family on this line
def valid_digest?(d), do: String.length(d) == 64  # mutare:ignore[string_byte] hex, always ASCII

# a region: a literal table the round-trip property test already covers
# mutare:ignore-start covered by the encode/decode round-trip property
def encode(?A), do: ?B
def encode(?B), do: ?C
# mutare:ignore-end
```

A standalone comment applies to the next line. `mix mutare --list-mutators` prints
each family's labels. A label the family doesn't declare is a hard error. An unknown
family name matches nothing, and Mutare warns about the directive as ineffective.
For the full grammar, see `Mutare.Ignore` on HexDocs.

For a *call* not worth testing wherever it appears (`Logger`, telemetry, analytics),
route it instead of annotating each line:

```elixir
# .mutare.exs
call_routes: [{MyApp.Telemetry, :emit, 2, :skip}, {Sentry, :*, :skip}]
```
