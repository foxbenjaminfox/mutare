defmodule Mutare.Mutators.ModeSwap do
  @moduledoc """
  Replaces mode and unit atoms in supported standard-library calls. Each replacement is valid for that function and argument position.

  ## Time and calendar units

    * `DateTime.add/3,4`, `DateTime.diff/3`, and the corresponding `NaiveDateTime` and `Time` calls: replace the trailing time unit with an adjacent unit.
    * `DateTime.truncate/2`, `NaiveDateTime.truncate/2`, and `Time.truncate/2`: replace `:microsecond`, `:millisecond`, or `:second` with an adjacent precision.
    * `System.system_time/1`, `System.monotonic_time/1`, `System.os_time/1`, and both unit arguments of `System.convert_time_unit/3`: replace the clock unit. `:native` changes to `:second`.
    * `DateTime.from_unix/2,3`, `DateTime.from_unix!/2,3`, and `DateTime.to_unix/2`: replace the timestamp unit.
    * `DateTime.shift/2,3`, `NaiveDateTime.shift/2`, `Time.shift/2`, and `Date.shift/2`: replace each duration key with an adjacent valid unit while retaining its amount. `Time` accepts only time units and `Date` only date units. `:microsecond` is excluded because its value has a different shape.
    * `Date.day_of_week/2`, `Date.beginning_of_week/2`, and `Date.end_of_week/2`: replace the starting weekday with an adjacent day. `:default` changes to `:tuesday`.

  ## String and encoding modes

    * `String.upcase/2`, `String.downcase/2`, and `String.capitalize/2`: `:greek` and `:turkic` change to `:default`. `:default` and `:ascii` are not exchanged.
    * `String.normalize/2`: exchange `:nfc` with `:nfd`, and `:nfkc` with `:nfkd`.
    * `DateTime.to_iso8601/2,3` and the corresponding `NaiveDateTime`, `Time`, and `Date` calls: exchange `:extended` and `:basic`.
    * `URI.encode_query/2` and `URI.decode_query/3`: exchange `:www_form` and `:rfc3986`.

  ## Sort modes

  For `Enum.sort/2`, `Enum.sort_by/3`, and `List.keysort/3`, the mutator exchanges `:asc` and `:desc`. It also changes the direction in `{:asc | :desc, module}` tuples. A literal module sorter, such as `Enum.sort(values, Date)`, becomes `{:desc, Date}`. Variables and function sorters are not wrapped.

  ## Keyword option modes

    * The `case:` option for `Base.encode16/2`, `Base.decode16/2`, `Base.decode16!/2`, and the corresponding Base32 and hex Base32 functions exchanges `:upper` and `:lower`. `:mixed` is unchanged.
    * The `return:` option for `Regex.scan/3` and `Regex.run/3` exchanges `:index` and `:binary`.
    * The `on:` option for `Regex.split/3` changes `:first` and `:all` to `:none`; `:none`, `:all_but_first`, and `:all_names` change to `:first`. Lists of capture references are unchanged.

  Ordered sets use adjacent replacements, so a position produces at most two mutants. Unrecognized atoms and values of other types are ignored.

  This family is enabled by default. It matches aliased and piped calls and locates the option at its effective argument position. Because it rewrites the whole call, overlapping `Mutare.Mutators.AtomLiteral` and `Mutare.Mutators.AliasLiteral` leaf mutants are removed.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutators.Helpers

  # Ordered magnitude ladders. A swap is to the adjacent finer/coarser member *within
  # the same ladder*, so the replacement is always legal for that function (truncate
  # rejects :minute; add/diff accept it) and the change is always observable.
  @truncate_ladder [:microsecond, :millisecond, :second]
  @calendar_ladder [:nanosecond, :microsecond, :millisecond, :second, :minute, :hour, :day]
  @system_ladder [:nanosecond, :microsecond, :millisecond, :second]

  # `shift`'s `Duration` units, by magnitude. `:microsecond` is deliberately absent — its
  # amount is a `{count, precision}` tuple, so a swap to/from an integer-valued unit would
  # only raise. `Time.shift` accepts no date component, so its ladder is the time-only tail;
  # `Date.shift` accepts no time component, so its ladder is the complementary date-only tail
  # (a swap can never reach `:hour`, which `Date.shift` would reject).
  @duration_ladder [:second, :minute, :hour, :day, :week, :month, :year]
  @duration_time_ladder [:second, :minute, :hour]
  @duration_date_ladder [:day, :week, :month, :year]

  # Unordered mode sets: one curated, behaviourally-distinct sibling per member.
  # Casing: only the exotic locale modes are swapped — `:greek`/`:turkic` → `:default`.
  # `:default` ↔ `:ascii` is deliberately absent: that swap rarely changes behaviour
  # (it only diverges on non-ASCII input the test must already exercise), so it tended
  # to survive as a low-signal equivalent rather than expose a real gap.
  @case_modes %{greek: [:default], turkic: [:default]}
  @norm_forms %{nfc: [:nfd], nfd: [:nfc], nfkc: [:nfkd], nfkd: [:nfkc]}
  # Sort direction: the `:asc`/`:desc` shorthand accepted by `sort`/`sort_by`/`keysort`.
  @order_modes %{asc: [:desc], desc: [:asc]}
  # ISO 8601 rendering format (a lone positional atom): the separator-laden `:extended`
  # vs the compact `:basic` — a string-shape change any `to_iso8601` assertion catches.
  @iso_format %{extended: [:basic], basic: [:extended]}
  # Keyword-option value sets (the atom is the *value* of a named option key). Base16/Base32
  # `case:` toggles the rendering casing / accepted input; the decoders' `:mixed` is
  # deliberately absent (it accepts both cases — a swap from it only narrows on already-tested
  # input, the `:default` ↔ `:ascii` trap). Regex's `return:` flips index tuples vs substrings.
  @base_case %{upper: [:lower], lower: [:upper]}
  @regex_return %{index: [:binary], binary: [:index]}
  # `Regex.split`'s `on:` selects which captures are split points. Swap across the only
  # axis observable on any matching input — whether the whole match splits: the
  # whole-match modes `:first`/`:all` → `:none`, and the rest → `:first` (the default).
  @regex_on %{
    first: [:none],
    all: [:none],
    none: [:first],
    all_but_first: [:first],
    all_names: [:first]
  }

  # Week-start day (`Date.day_of_week`/`beginning_of_week`/`end_of_week`'s `starting_on`): an
  # ordered ladder of weekdays, so a swap moves the week's start to an adjacent day — a result
  # any assertion on the computed boundary/index catches. `:default` is an alias for `:monday`,
  # so — like `System`'s `:native` — it maps to a concrete neighbour (`:tuesday`) rather than
  # to its own meaning (which would be an equivalent no-op).
  @weekday_ladder [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday]
  # URL query encoding (`URI.encode_query`/`decode_query`'s trailing `encoding`): the
  # space-as-`+` `:www_form` vs the percent-encoded `:rfc3986`, a query-string shape change
  # (`"a+b"` vs `"a%20b"`) any assertion on the encoded/decoded string catches.
  @uri_encoding %{www_form: [:rfc3986], rfc3986: [:www_form]}

  # The Base16/Base32 family — all carry the `case:` option in their trailing options list.
  @base_funs [
    :encode16,
    :decode16,
    :decode16!,
    :encode32,
    :decode32,
    :decode32!,
    :hex_encode32,
    :hex_decode32,
    :hex_decode32!
  ]

  # The stdlib calls whose mode/unit argument we swap, grouped by their shared
  # `{mode_positions, group}` value — so the value is written once and a signature can't
  # drift from its siblings (and adding a calendar type, arity, or Base variant is one line
  # in the right group). `@rules` (the `{alias_path, function, effective_arity}` =>
  # `{positions, group}` lookup the matcher reads) is *derived* from this below. Positions
  # are *effective* (pipe-independent); `visible_index/2` maps them to the node's own arg
  # list. Most rules carry one position; `convert_time_unit` has two.
  @rule_groups [
    # Time-unit precision — `truncate`'s 3-member slice of the calendar ladder.
    {{[1], :truncate},
     [{[:DateTime], :truncate, 2}, {[:NaiveDateTime], :truncate, 2}, {[:Time], :truncate, 2}]},
    # Calendar add/diff — the trailing unit atom (only `DateTime` has the `/4` arity).
    {{[2], :calendar},
     [
       {[:DateTime], :add, 3},
       {[:DateTime], :add, 4},
       {[:DateTime], :diff, 3},
       {[:NaiveDateTime], :add, 3},
       {[:NaiveDateTime], :diff, 3},
       {[:Time], :add, 3},
       {[:Time], :diff, 3}
     ]},
    # `shift` — the duration unit is a keyword list at position 1, not a lone atom. `Time`
    # and `Date` get the time-only / date-only ladders (each rejects the other's units).
    {{[1], :duration},
     [{[:DateTime], :shift, 2}, {[:DateTime], :shift, 3}, {[:NaiveDateTime], :shift, 2}]},
    {{[1], :duration_time}, [{[:Time], :shift, 2}]},
    {{[1], :duration_date}, [{[:Date], :shift, 2}]},
    # System clock unit at position 0; `convert_time_unit` reads both unit positions.
    {{[0], :system},
     [{[:System], :system_time, 1}, {[:System], :monotonic_time, 1}, {[:System], :os_time, 1}]},
    {{[1, 2], :system}, [{[:System], :convert_time_unit, 3}]},
    # Unix-timestamp conversions take the same `System.time_unit` at position 1; the `/3`
    # arities add a trailing `Calendar`, so the unit stays at 1.
    {{[1], :system},
     [
       {[:DateTime], :from_unix, 2},
       {[:DateTime], :from_unix, 3},
       {[:DateTime], :from_unix!, 2},
       {[:DateTime], :from_unix!, 3},
       {[:DateTime], :to_unix, 2}
     ]},
    # ISO 8601 rendering format — a lone positional atom (`:extended` ↔ `:basic`). `/1` has no
    # format arg; the optional trailing `offset` on `DateTime`'s `/3` keeps the format at 1.
    {{[1], :iso_format},
     [
       {[:DateTime], :to_iso8601, 2},
       {[:DateTime], :to_iso8601, 3},
       {[:NaiveDateTime], :to_iso8601, 2},
       {[:Time], :to_iso8601, 2},
       {[:Date], :to_iso8601, 2}
     ]},
    # Unicode casing / normalization form.
    {{[1], :case_mode},
     [{[:String], :upcase, 2}, {[:String], :downcase, 2}, {[:String], :capitalize, 2}]},
    {{[1], :norm_form}, [{[:String], :normalize, 2}]},
    # Sort direction shorthand — the sorter is the trailing positional argument.
    {{[1], :order}, [{[:Enum], :sort, 2}]},
    {{[2], :order}, [{[:Enum], :sort_by, 3}, {[:List], :keysort, 3}]},
    # Keyword-option modes — the atom is the *value* of a named key in the trailing options
    # list. `{:kw, [key: set]}` declares which key(s) to read and which value set to swap.
    {{[1], {:kw, [case: :base_case]}}, for(f <- @base_funs, do: {[:Base], f, 2})},
    {{[2], {:kw, [return: :regex_return]}}, [{[:Regex], :scan, 3}, {[:Regex], :run, 3}]},
    # `Regex.split/3`'s `on:` selects which captures are split points.
    {{[2], {:kw, [on: :regex_on]}}, [{[:Regex], :split, 3}]},
    # Week-start day — the `starting_on` weekday atom (`:monday`…`:sunday`, `:default`). The
    # `/1` arities default it (no atom to swap), like `to_iso8601/1`.
    {{[1], :weekday},
     [{[:Date], :day_of_week, 2}, {[:Date], :beginning_of_week, 2}, {[:Date], :end_of_week, 2}]},
    # URL query encoding — the trailing `encoding` atom (`:www_form` ↔ `:rfc3986`).
    # `encode_query/2` carries it at position 1; on `decode_query/3` it is the third argument
    # (`encode_query/1`/`decode_query/2` default it).
    {{[1], :uri_encoding}, [{[:URI], :encode_query, 2}]},
    {{[2], :uri_encoding}, [{[:URI], :decode_query, 3}]}
  ]

  # The flat lookup the matcher reads: `{alias_path, function, effective_arity}` =>
  # `{mode_positions, group}`, derived by flattening each group's signature list.
  @rules for {spec, sigs} <- @rule_groups, sig <- sigs, into: %{}, do: {sig, spec}

  @impl Mutare.Mutator
  def name, do: :mode_swap

  # A probe atom that belongs to no ladder or mode set: `swaps/2` returns `[]` for it on every
  # *covered* group, but the raising catch-all fires for an uncovered one — the discriminator
  # `uncovered_swap_groups/0` relies on.
  @drift_probe :__mutare_drift_probe__

  @doc false
  # Drift guard for the `@rule_groups` ↔ `swaps/2` pairing, which has no *structural* compile-time
  # guarantee: the swap-set keys any rule group routes to `swaps/2` that have *no* matching clause
  # (so they would hit the raising catch-all when a real mutant exercises them). Empty in a healthy
  # module — `__assert_swap_coverage__/2` (an `@after_compile` hook) makes a non-empty result a
  # **compile** error, turning "added a `@rule_groups` entry, forgot its `swaps/2` clause" from a
  # latent runtime `ArgumentError` into a failed build (the `ModeSwap` suite asserts it too).
  @spec uncovered_swap_groups() :: [atom()]
  def uncovered_swap_groups, do: Enum.reject(swap_group_keys(), &swaps_defined?/1)

  @after_compile {__MODULE__, :__assert_swap_coverage__}

  @doc false
  # Fail the build on drift, checked at compile time rather than only under the test suite. Two ways
  # the `@rule_groups`/`swaps/2` contract can break: a routed group with no clause (the common slip),
  # and — subtler — a `swaps/2` catch-all softened so it no longer raises, which would silently
  # defeat `swaps_defined?/1`'s probe. Both are caught here.
  def __assert_swap_coverage__(_env, _bytecode) do
    unless catch_all_raises?() do
      raise "ModeSwap drift guard defunct: the swaps/2 catch-all no longer raises for an " <>
              "undefined group, so swaps_defined?/1 can no longer detect a missing clause."
    end

    case uncovered_swap_groups() do
      [] ->
        :ok

      groups ->
        raise "ModeSwap: @rule_groups route to swap group(s) with no swaps/2 clause: " <>
                "#{inspect(groups)} — add the clause(s) or fix the table."
    end
  end

  # The swap-set keys every `@rule_groups` entry routes to `swaps/2`: a plain group atom, or the
  # value-set atoms of a `{:kw, [key: set]}` group (whose `keyword_value_swaps/2` calls
  # `swaps(set, value)`). Derived from `@rule_groups` so it can't drift from the table.
  defp swap_group_keys do
    @rule_groups
    |> Enum.flat_map(fn
      {{_positions, {:kw, specs}}, _sigs} -> Keyword.values(specs)
      {{_positions, group}, _sigs} -> [group]
    end)
    |> Enum.uniq()
  end

  # Whether `group` has a real `swaps/2` clause: a covered group returns `[]` for the probe atom,
  # an uncovered one raises from the catch-all.
  defp swaps_defined?(group) do
    swaps(group, @drift_probe)
    true
  rescue
    ArgumentError -> false
  end

  # Whether the `swaps/2` catch-all still raises for a group with no clause — the property
  # `swaps_defined?/1` depends on. A healthy module raises here; a catch-all softened to return
  # `[]` would not, silently defeating the guard, which `__assert_swap_coverage__/2` rejects.
  defp catch_all_raises? do
    swaps(:__mutare_undefined_group__, @drift_probe)
    false
  rescue
    ArgumentError -> true
  end

  @impl Mutare.Mutator
  def mutate(node, %{pipe_mode: pipe_mode}) do
    with {:ok, {positions, group}, {_module, fun, args, rebuild}} <-
           Helpers.lookup_resolved_arity(node, pipe_mode, @rules),
         [_ | _] = sites <- swap_sites(args, positions, group, pipe_mode) do
      # `rebuild` keeps the same function and written alias, swapping only args. Each site
      # carries the replacement *arg node* — a fresh mode-atom literal, or (for `shift`) the
      # duration keyword list with one unit key swapped.
      Enum.map(sites, fn {vis, arg} -> rebuild.(fun, List.replace_at(args, vis, arg)) end)
    else
      _ -> :skip
    end
  end

  # The `{visible_index, replacement_arg_node}` pairs this rule yields — one per legal
  # swap at each mode position. A position that yields no swap (a non-mode-atom, an
  # unrecognised atom, a non-keyword-list duration, or the piped value itself) contributes
  # none.
  defp swap_sites(args, positions, group, pipe_mode) do
    for pos <- positions,
        vis = Mutare.Mutator.visible_index(pos, pipe_mode),
        vis != nil,
        replacement <- position_swaps(group, Enum.at(args, vis)) do
      {vis, replacement}
    end
  end

  # The replacement *arg nodes* for the swaps at one position. An atom-position group reads
  # a single mode atom and emits one fresh atom literal per ladder neighbour; a duration
  # group (`shift`) reads a `unit: amount` keyword list and emits one rebuilt list per
  # (unit key, neighbour) — `mode_atom` generalised from a lone positional atom to the keys
  # of a duration keyword list.
  defp position_swaps(group, arg) when group in [:duration, :duration_time, :duration_date],
    do: duration_swaps(group, arg)

  defp position_swaps(:order, arg), do: order_swaps(arg)

  defp position_swaps({:kw, specs}, arg), do: keyword_value_swaps(specs, arg)

  defp position_swaps(group, arg),
    do: for(atom <- mode_atom(arg), new_atom <- swaps(group, atom), do: AST.literal(new_atom))

  # A keyword-option mode: the atom sits as the *value* of a named option key in the
  # trailing options list (the value-side mirror of `shift`'s keyword *keys*). `specs` is a
  # list of `{key, set}` — for each pair whose key matches, read its value atom and emit one
  # rebuilt list per legal sibling, the key kept and the value replaced. A missing key, a
  # non-atom value, or an unrecognised value contributes nothing.
  defp keyword_value_swaps(specs, arg) do
    case keyword_list(arg) do
      nil ->
        []

      {pairs, rewrap} ->
        for {key, set} <- specs,
            {{k, v}, i} <- Enum.with_index(pairs),
            mode_atom(k) == [key],
            value <- mode_atom(v),
            new_value <- swaps(set, value) do
          rewrap.(List.replace_at(pairs, i, {k, AST.literal(new_value)}))
        end
    end
  end

  # `:order` (the sort direction) accepts the lone `:asc`/`:desc` shorthand, a
  # `{:asc | :desc, module}` tuple (the per-sort comparison-module form), or a bare module.
  # A shorthand/tuple has its direction swapped (the tuple keeps its module); a bare module
  # is wrapped descending (see `bare_module_swaps/1`). A sorter fun / variable yields nothing.
  defp order_swaps(arg) do
    case order_target(arg) do
      nil -> bare_module_swaps(arg)
      {dir, rebuild} -> for new <- swaps(:order, dir), do: rebuild.(AST.literal(new))
    end
  end

  # A **bare module** in the sorter position is the ascending default — `Enum.sort(xs, Date)`
  # is exactly `{:asc, Date}` — so the one non-equivalent order mutation is to wrap it
  # descending, `{:desc, Date}`, letting order-dependence be tested even on a module-keyed
  # sort with no direction atom present. Restricted to a literal module **alias**: a variable
  # or fun sorter might hold `:asc` or a comparator fun, which a `{:desc, _}` wrap would reject
  # at runtime. The module node is reused verbatim, re-homed under a fresh `:desc` in a 2-tuple
  # (`{:__block__, [], [{dir, mod}]}`, matching Sourceror's parsed shape), so the build compiles.
  defp bare_module_swaps({:__aliases__, _meta, _parts} = mod),
    do: [{:__block__, [], [{AST.literal(:desc), mod}]}]

  defp bare_module_swaps(_arg), do: []

  # The direction atom of an `:order` argument plus a closure that rebuilds the argument
  # around a replacement direction node — identity for the lone shorthand, or the 2-tuple
  # (preserving its `:__block__` wrapper and module) for the `{dir, module}` form.
  defp order_target({:__block__, meta, [{dir_node, mod}]}) do
    case mode_atom(dir_node) do
      [dir] -> {dir, fn new -> {:__block__, meta, [{new, mod}]} end}
      [] -> nil
    end
  end

  defp order_target(arg) do
    case mode_atom(arg) do
      [dir] -> {dir, & &1}
      [] -> nil
    end
  end

  # `shift`'s duration argument is a keyword list `[unit: amount, …]` — the trailing-keyword
  # sugar (a *bare* list) or an explicit `[…]` (a `:__block__`-wrapped list, e.g. when
  # `shift/3`'s opts follow). For each swappable unit *key*, emit the list rebuilt with that
  # one key swapped to a ladder neighbour, its amount kept. A non-keyword-list duration (a
  # `%Duration{}` struct, a variable) yields nothing.
  defp duration_swaps(group, arg) do
    case keyword_list(arg) do
      nil ->
        []

      {pairs, rewrap} ->
        for {{key, value}, i} <- Enum.with_index(pairs),
            unit <- mode_atom(key),
            new_unit <- swaps(group, unit) do
          rewrap.(List.replace_at(pairs, i, {duration_key(new_unit), value}))
        end
    end
  end

  # The `{key, value}` pairs of a keyword-list argument (a `shift` duration or an options
  # list), plus a closure that restores the argument's shape (a bare list — the trailing-
  # keyword sugar — or a `:__block__`-wrapped explicit `[…]`); `nil` if the argument is not
  # a keyword list. Shared by the duration-key swaps and the keyword-option value swaps.
  defp keyword_list({:__block__, meta, [inner]}) when is_list(inner) do
    with pairs when pairs != nil <- keyword_pairs(inner),
         do: {pairs, fn new -> {:__block__, meta, [new]} end}
  end

  defp keyword_list(list) when is_list(list) do
    with pairs when pairs != nil <- keyword_pairs(list), do: {pairs, & &1}
  end

  defp keyword_list(_arg), do: nil

  defp keyword_pairs(list) when is_list(list) and list != [] do
    if Enum.all?(list, &match?({_k, _v}, &1)), do: list, else: nil
  end

  defp keyword_pairs(_list), do: nil

  # A fresh `unit:` keyword key — `format: :keyword` so Sourceror renders `second:` (not
  # `:second =>`), and fresh meta so it carries no stale token (the clean-meta rule).
  defp duration_key(unit), do: {:__block__, [format: :keyword], [unit]}

  # The legal sibling atoms for a swap. Ladders return the adjacent neighbour(s);
  # the System-only `:native` maps to a concrete unit; mode sets are a lookup.
  defp swaps(:truncate, atom), do: neighbours(@truncate_ladder, atom)
  defp swaps(:calendar, atom), do: neighbours(@calendar_ladder, atom)
  defp swaps(:system, :native), do: [:second]
  defp swaps(:system, atom), do: neighbours(@system_ladder, atom)
  defp swaps(:duration, unit), do: neighbours(@duration_ladder, unit)
  defp swaps(:duration_time, unit), do: neighbours(@duration_time_ladder, unit)
  defp swaps(:duration_date, unit), do: neighbours(@duration_date_ladder, unit)
  defp swaps(:case_mode, atom), do: Map.get(@case_modes, atom, [])
  defp swaps(:norm_form, atom), do: Map.get(@norm_forms, atom, [])
  defp swaps(:order, atom), do: Map.get(@order_modes, atom, [])
  defp swaps(:iso_format, atom), do: Map.get(@iso_format, atom, [])
  defp swaps(:base_case, atom), do: Map.get(@base_case, atom, [])
  defp swaps(:regex_return, atom), do: Map.get(@regex_return, atom, [])
  defp swaps(:regex_on, atom), do: Map.get(@regex_on, atom, [])
  # `:default` (≡ `:monday`) maps to a concrete neighbour, mirroring `System`'s `:native`.
  defp swaps(:weekday, :default), do: [:tuesday]
  defp swaps(:weekday, atom), do: neighbours(@weekday_ladder, atom)
  defp swaps(:uri_encoding, atom), do: Map.get(@uri_encoding, atom, [])

  # A `@rules` group with no swap-set clause above is a programming error — a new rule
  # added without its `swaps/2` entry. Fail loudly at analysis time rather than with an
  # opaque FunctionClauseError. **Load-bearing**: `swaps_defined?/1` / `catch_all_raises?/0`
  # rely on this clause raising `ArgumentError`; softening it to return `[]` defeats the drift
  # guard, which `__assert_swap_coverage__/2` catches at compile time.
  defp swaps(group, _atom),
    do: raise(ArgumentError, "ModeSwap: no swap-set defined for group #{inspect(group)}")

  # The members of `ladder` immediately finer and coarser than `atom` (each, if it
  # exists). `Enum.at` with a guarded non-negative index — a bare `i - 1` would wrap
  # to the list's tail at index 0.
  defp neighbours(ladder, atom) do
    case Enum.find_index(ladder, &(&1 == atom)) do
      nil ->
        []

      i ->
        prev = if i > 0, do: [Enum.at(ladder, i - 1)], else: []
        next = if i < length(ladder) - 1, do: [Enum.at(ladder, i + 1)], else: []
        prev ++ next
    end
  end

  # The atom carried by an argument node, if it is an atom literal (in a one-element list,
  # for the comprehensions above). `true`/`false`/`nil` are never mode atoms.
  defp mode_atom(node) do
    case AST.literal_value(node) do
      {:ok, a} when is_atom(a) and a not in [true, false, nil] -> [a]
      _ -> []
    end
  end
end
