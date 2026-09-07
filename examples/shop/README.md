# Shop example

The big one — a small **multi-module** shop (no dependencies) written to do two
things the other examples don't:

1. **Exercise every built-in mutator family.** Across six files it triggers all
   44 — from `arithmetic` and `regex` to `genserver`, `bitstring_spec`,
   `pattern_swap`, and `rescue_type`. (`mix mutare examples/shop --dry-run` lists
   every mutant, grouped by file, without compiling or running anything.)
2. **Show the `.mutare.exs` config surface** — choosing mutators, leaving a
   macro's argument raw, and suppressing known-equivalent mutants with
   `# mutare:ignore`.

```
examples/shop/
├── .mutare.exs            # mutator selection + a call_routes: entry (the config tour)
├── lib/shop/
│   ├── cart.ex            # lists, maps, tuples, Enum rewrites, pattern families
│   ├── pricing.ex         # the operator/number families + the ignore directives
│   ├── inventory.ex       # bitwise, Integer, MapSet, a guard, a try/rescue, apply/3
│   ├── catalog.ex         # strings, sigils, regex, calendar + bitstring literals
│   ├── query.ex           # a one-macro query DSL (stands in for Ecto.Query)
│   ├── search.ex          # uses the DSL — the call_routes: target
│   └── server.ex          # a GenServer (the genserver family)
└── test/shop/             # a deliberately good-but-imperfect suite
```

From the repo root:

```
mix mutare examples/shop
```

Expected (abridged — 28 survivors across four files):

```
mutare in examples/shop: 287 mutants across 6 file(s)

lib/shop/catalog.ex:18  [regex, in-place]  SURVIVED
-    String.match?(sku, ~r/^[A-Z]{3}-\d{4}$/)
+    String.match?(sku, ~r/[A-Z]{3}-\d{4}$/)

lib/shop/cart.ex:23  [operand_swap, in-place]  SURVIVED
-      {:ok, %{cart | lines: lines ++ [line]}}
+      {:ok, %{cart | lines: [line] ++ lines}}

lib/shop/inventory.ex:41  [guard_drop, lifted]  SURVIVED
-  def code_size(sku) when is_binary(sku) do
+  def code_size(sku) do
...
mutation score: 89.9%  (250 killed, 28 survived, 5 no-coverage, 4 ignored, 287 total)
```

## The config tour (`.mutare.exs`)

This is the example's real subject — open
[`.mutare.exs`](.mutare.exs) and read it alongside this.

- **`mutators: [:builtins]`** runs the whole catalogue (the default, spelled out).
  The file shows the forms for narrowing it (`[:arithmetic, :relational]`,
  `[{:builtins, except: [:regex]}]`, or adding your own module).
- **`call_routes: [{Shop.Query, :matching, [:expression, :raw]}]`** leaves the second
  argument of the `matching/2` query macro as written. `lib/shop/search.ex` writes
  `matching(products, row.price <= budget)` — a query *expression*, not runtime
  code. Leaving it raw drops `search.ex` from 11 mutants to 4. **Comment that line
  out and re-run** to watch the `relational`/`conditional` mutants on the query
  conditions reappear — the dependency-free version of `{Ecto.Query, :from, :skip}`.
- **`# mutare:ignore`** lives in the source, not the config. `lib/shop/pricing.ex`
  carries all three flavours — run `mix mutare examples/shop --list-ignores` to
  see them:
  - `# mutare:ignore[pattern_swap]` on `mid_price/1` — a midpoint is symmetric in
    its `{low, high}` endpoints, so the swap is genuinely equivalent.
  - `# mutare:ignore[math]` on `popularity/1` — `:math.log` → `log2`/`log10` only
    rescales a number used for *ranking*, so the base is irrelevant.
  - `# mutare:ignore[strict_equality:==]` on `native_currency?/1` — a *variant
    qualifier*: atoms compare identically under `==` and `===`, so suppress only
    that relaxation. Each carries a free-text reason, surfaced in the report.

  These four mutants (two for `math`) show up as `ignored` and drop out of the
  score's denominator.

## A tour of the survivors

The 28 survivors span the codebase; a representative handful:

- **Regex anchors and class edges (`catalog.ex:18`).** `valid_sku?` uses
  `~r/^[A-Z]{3}-\d{4}$/`, but the suite only tries one valid SKU and one obviously
  invalid one — so dropping the `^`/`$` anchors (a SKU embedded in junk would now
  match) or shrinking the `[A-Z]` class to `[A-Y]` all survive. **Untested
  format edges.**
- **List order (`cart.ex:23`).** `lines ++ [line]` → `[line] ++ lines` prepends
  instead of appends. Every test adds to a one-line cart, so order is never
  observed. **Weak test data.**
- **A removable guard (`inventory.ex:41`).** `def code_size(sku) when is_binary(sku)`
  is only ever called with a binary, so deleting the guard changes nothing the
  suite sees. **Untested precondition.**
- **An unused default (`cart.ex:37`).** `Map.get(stock, line.sku, 0)` — the `0`
  fallback is never hit, because every test SKU is present in the stock map, so
  dropping it (or changing it) survives. **Untested missing-key path.**
- **A narrowed rescue (`inventory.ex:50`).** `rescue e in [ArgumentError,
  FunctionClauseError]` → just `[ArgumentError]`. Only an `ArgumentError` is ever
  raised in a test, so dropping the second type is invisible. **Untested failure mode.**
- **Boundaries again (`pricing.ex:57`).** `if amount >= 100.0` survives `>= 99.0`,
  `>= 101.0`, and `> 100.0` — the premium tier is never tested *at* its threshold.
  The same lesson [`calc`](../calc/) opens with, one module deeper.

And **5 no-coverage**: `Cart.add/3`'s `{:error, :cart_full}` branch (line 20) is
never reached — no test fills a cart to its limit — so its mutants can't be
killed and are left out of the score, exactly like the report says.

Plenty more is **pinned**: the bitwise masks, `Integer.mod`, the `MapSet` union,
the GenServer's reply tags, the catalog's bitstrings and calendar math, and the
whole of `search.ex`'s pipeline are all killed by the tests that do exist.
