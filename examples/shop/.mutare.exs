# Mutare reads this file automatically when you run `mix mutare examples/shop`.
# It exists to show the three knobs you reach for most often.
[
  # 1. WHICH MUTATORS RUN. `:builtins` is every built-in family — the default,
  #    spelled out here so this demo exercises the whole catalogue. To narrow it:
  #
  #      mutators: [:arithmetic, :relational]          # just these two
  #      mutators: [{:builtins, except: [:regex]}]     # all but one
  #      mutators: [:builtins, MyApp.Mutators.Custom]  # all, plus your own
  mutators: [:builtins],

  # 2. MACRO ARGUMENTS TO LEAVE RAW. `Shop.Query.matching/2` (lib/shop/query.ex)
  #    is a query DSL — like `Ecto.Query.from/2`. Its second argument is a query
  #    expression, not ordinary runtime code, so mutating inside it is noise (or
  #    worse, uncompilable). `[:expression, :skip]` mutates the first argument
  #    normally and leaves the second raw. (Comment this out and re-run to see
  #    the relational/condition mutants it suppresses in lib/shop/search.ex.)
  macro_routes: [
    {Shop.Query, :matching, [:expression, :skip]}
  ]

  # 3. KNOWN-EQUIVALENT MUTANTS are suppressed at the source with
  #    `# mutare:ignore` comments — see lib/shop/pricing.ex and lib/shop/cart.ex.
]
