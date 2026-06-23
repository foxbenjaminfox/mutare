defmodule Mutare.Mutators.ModeSwap do
  @moduledoc """
  Swap a **mode / unit atom** drawn from a closed set, in a known argument position
  of a known stdlib function, for a sibling of the same set. Asks the question the
  literal mutators can't reach: does any test actually depend on the *granularity*,
  *unit*, or *mode* this call was given?

  Unlike a literal swap this is **semantic** — it needs to know the function and which
  of its arguments is the mode atom — so it is table-driven on `{module, fun, arity}`,
  the sibling of `Mutare.Mutators.{Collection,StringCall,MapKeyword,CallRemoval}`. Where
  those swap the *function name* or drop an *argument*, this swaps an *option value*.

  ## What it mutates

  Time units (the richest vein — `truncate`'s 3-member set is just a slice of the
  calendar ladder, which recurs across `add`/`diff` on every calendar type and the
  `System` clock):

    * `DateTime.add/3,4`, `DateTime.diff/3`, and the `NaiveDateTime`/`Time` twins —
      the trailing unit (`:second` → `:millisecond` / `:minute`, an adjacent neighbour
      on the magnitude ladder)
    * `DateTime.truncate/2`, `NaiveDateTime.truncate/2`, `Time.truncate/2` — the
      precision (`:microsecond` ↔ `:millisecond` ↔ `:second`)
    * `System.system_time/1`, `System.monotonic_time/1`, `System.os_time/1`,
      `System.convert_time_unit/3` (both unit positions) — the clock unit, with the
      `System`-only `:native` mapped to a concrete `:second`
    * `DateTime.from_unix/2,3`, `DateTime.from_unix!/2,3`, `DateTime.to_unix/2` — the
      Unix-timestamp unit, the same `System.time_unit` set (so `:native` → `:second`);
      the optional trailing `Calendar` on the `/3` arities leaves the unit at position 1
    * `DateTime.shift/2,3`, `NaiveDateTime.shift/2`, `Time.shift/2`, `Date.shift/2` — the
      **duration units**. Unlike the others, the unit isn't a lone positional atom but the
      *keys* of a keyword list of `unit: amount` pairs (`shift(dt, minute: 10, day: -1)`).
      This is the generalisation of `mode_atom`: each *key* is a duration unit on a ladder
      (`:second`…`:year`; `Time` is time-only — `:second`…`:hour`; `Date` is date-only —
      `:day`…`:year`, since `Date.shift` rejects any time unit), so each swappable key is
      moved to an adjacent neighbour independently (`minute:` → `second:`/`hour:`), its
      amount kept. (`:microsecond` is excluded — its amount is a `{count, precision}`
      tuple, incompatible with the integer-valued units, so swapping its key would only
      ever raise. The amounts themselves still mutate via `Mutare.Mutators.Literal`.)

  Unicode modes:

    * `String.upcase/2`, `String.downcase/2`, `String.capitalize/2` — the casing mode,
      swapping only the exotic locale modes back to the default (`:greek` → `:default`,
      `:turkic` → `:default`). `:default` ↔ `:ascii` is *not* swapped: it only diverges
      on non-ASCII input (which a test exercising the call must already cover), so it
      tended to survive as a low-signal equivalent rather than expose a real gap.
    * `String.normalize/2` — the normalization form (`:nfc` ↔ `:nfd`, `:nfkc` ↔ `:nfkd`,
      toggling composition while preserving compatibility)

  Sort order:

    * `Enum.sort/2` (sorter at arg 1), `Enum.sort_by/3` and `List.keysort/3` (sorter at
      arg 2) — the `:asc` ↔ `:desc` direction, a reversal that any test asserting on the
      result's *order* must catch. Both the lone shorthand atom and the `{:asc | :desc,
      module}` tuple (the per-sort comparison-module form) are swapped — in the tuple only
      the direction flips, the module is kept. A custom sorter fun is not a direction atom,
      so it contributes nothing for free. `Enum.min_by/max_by` look similar but reject the
      shorthand (they read the atom as a comparison module), so they are deliberately absent.

  ISO 8601 rendering:

    * `DateTime.to_iso8601/2,3` and the `NaiveDateTime`/`Time`/`Date` `to_iso8601/2` twins —
      the positional `format` atom, `:extended` ↔ `:basic` (the separator-laden
      `2020-01-01T00:00:00Z` vs the compact `20200101T000000Z`), a string-shape change any
      `to_iso8601` assertion catches. `/1` defaults the format (no atom to swap); on
      `DateTime`'s `/3` the trailing `offset` keeps the format at position 1.

  Calendar week start:

    * `Date.day_of_week/2`, `Date.beginning_of_week/2`, `Date.end_of_week/2` — the
      `starting_on` weekday (`:monday` … `:sunday`), an ordered ladder swapped to an
      adjacent day, so a US-style `:sunday` week start moves to `:saturday`/`:monday` (a
      different computed boundary or index any assertion catches). `:default` ≡ `:monday`,
      so — like `System`'s `:native` — it maps to a concrete neighbour (`:tuesday`), never
      its own meaning. The `/1` arities default the day (no atom to swap).

  URL query encoding:

    * `URI.encode_query/2`, `URI.decode_query/3` — the trailing `encoding`,
      `:www_form` ↔ `:rfc3986` (space-as-`+` vs percent-encoded `%20`), a query-string
      shape change. `encode_query/1` / `decode_query/2` default the encoding.

  Keyword-option modes (the atom is the *value* of a named option key — the value-side
  mirror of `shift`'s keyword *keys*):

    * `Base.encode16/2`, `decode16/2`, `decode16!/2` and the Base32 family
      (`encode32/2`, `decode32/2`, `decode32!/2`, `hex_encode32/2`, `hex_decode32/2`,
      `hex_decode32!/2`) — the `case:` option, `:upper` ↔ `:lower` (a different rendering,
      or accepted input on decode). The decoders' `:mixed` is left alone: it accepts both
      cases, so a swap from it only narrows acceptance on input the test already exercises —
      the `:default` ↔ `:ascii` trap.
    * `Regex.scan/3`, `Regex.run/3` — the `return:` option, `:index` ↔ `:binary` (offset
      tuples vs the matched substrings, a result-shape change any assertion catches).

  ## Swap strategy — small, legal, behavioural

  Each swap stays **within the legal set of *that* function**: the ordered ladders are
  per-family (a `truncate` only accepts `:microsecond | :millisecond | :second`, so its
  swaps never reach `:minute`, which would raise), and a swap is always to an **adjacent**
  ladder member — a single factor-of-1000/60 step that is subtle enough to slip past a
  loose assertion yet always observable. So a site yields at most two mutants (one finer,
  one coarser), mirroring the literal mutators' `{n-1, n+1}` pair. The unordered mode sets
  (case, form) emit one curated, behaviourally-distinct sibling. A position holding a
  non-atom (a variable, an integer parts-per-second) or an unrecognised atom contributes
  nothing, and a swap is never the original atom — no equivalent no-ops.

  ## Why pipe-aware (`mutate/2`, never `mutate/1`)

  The mode atom sits at a fixed *effective* position (`truncate`'s precision is arg 1,
  the calendar unit is arg 2), but a pipe stage carries one fewer argument than the
  source reads — `dt |> DateTime.truncate(:second)` reaches a mutator as a 1-arg node
  whose lone visible arg *is* the precision. So, like `Mutare.Mutators.CollectionArity`,
  the rule is keyed on **effective arity** (`effective_arity/2` — `length(args)`, plus one
  when `:piped`) and each mode position is translated from an effective index to the *visible* one
  (`pos - 1` when piped; an effective index 0 that is the piped value itself is skipped).

  Every result reuses the surrounding argument AST and only substitutes one atom for
  another legal one, so the single metamutant build always compiles; the swapped atom is
  emitted with fresh metadata (`{:__block__, [], [atom]}`) so Sourceror renders the new
  value, not a stale token (the clean-meta rule). On by default.

  ## Superseding the redundant leaf mutation

  A unit/mode atom sits in a value position, so `Mutare.Mutators.AtomLiteral` would
  *also* mutate it — `DateTime.truncate(dt, :second)` → `:mutare`, a mutant that just
  raises `ArgumentError` (an invalid precision) and is trivially killed. Because this
  mutator already covers that atom by rewriting the *whole call*, the transform drops the
  redundant leaf mutant: `Mutare.Transform.Overlap` diffs each mutant against its original,
  sees the swap touched exactly that atom (or, for `shift`, that one `unit:` key), and
  prunes any plain-leaf mutation at the same source range. This needs **no declaration**
  here — coverage is derived from `mutate/2`'s output, so an unrecognised atom, a variable,
  or an excluded `shift` unit (`microsecond:`) — none of which this mutator swaps — keeps
  its AtomLiteral mutant, and a `shift` amount (which the swap leaves untouched) keeps its
  `Mutare.Mutators.Literal` mutant.

  Recognises the stdlib modules by their resolved module (`Mutare.Transform.Calls`), so
  an aliased call (`alias DateTime, as: DT; DT.truncate(dt, :second)`) is matched too.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Transform.Calls

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

  # {alias_path, function, effective_arity} => {mode_positions (effective indices), group}.
  # Positions are *effective* (pipe-independent); `visible_index/2` maps them to the
  # node's own arg list. Most rules carry one position; `convert_time_unit` has two.
  @rules %{
    {[:DateTime], :truncate, 2} => {[1], :truncate},
    {[:NaiveDateTime], :truncate, 2} => {[1], :truncate},
    {[:Time], :truncate, 2} => {[1], :truncate},
    {[:DateTime], :add, 3} => {[2], :calendar},
    {[:DateTime], :add, 4} => {[2], :calendar},
    {[:DateTime], :diff, 3} => {[2], :calendar},
    {[:NaiveDateTime], :add, 3} => {[2], :calendar},
    {[:NaiveDateTime], :diff, 3} => {[2], :calendar},
    {[:Time], :add, 3} => {[2], :calendar},
    {[:Time], :diff, 3} => {[2], :calendar},
    # `shift` — the duration unit is a keyword list at position 1, not a lone atom.
    {[:DateTime], :shift, 2} => {[1], :duration},
    {[:DateTime], :shift, 3} => {[1], :duration},
    {[:NaiveDateTime], :shift, 2} => {[1], :duration},
    {[:Time], :shift, 2} => {[1], :duration_time},
    {[:Date], :shift, 2} => {[1], :duration_date},
    {[:System], :system_time, 1} => {[0], :system},
    {[:System], :monotonic_time, 1} => {[0], :system},
    {[:System], :os_time, 1} => {[0], :system},
    {[:System], :convert_time_unit, 3} => {[1, 2], :system},
    # Unix-timestamp conversions take the same `System.time_unit` at position 1; the
    # `/3` arities add a trailing `Calendar`, so the unit stays at 1.
    {[:DateTime], :from_unix, 2} => {[1], :system},
    {[:DateTime], :from_unix, 3} => {[1], :system},
    {[:DateTime], :from_unix!, 2} => {[1], :system},
    {[:DateTime], :from_unix!, 3} => {[1], :system},
    {[:DateTime], :to_unix, 2} => {[1], :system},
    # ISO 8601 rendering format — a lone positional atom (`:extended` ↔ `:basic`). `/1` has
    # no format arg; the optional trailing `offset` on `DateTime`'s `/3` keeps the format at
    # position 1 (the `NaiveDateTime`/`Time`/`Date` twins have no `/3`).
    {[:DateTime], :to_iso8601, 2} => {[1], :iso_format},
    {[:DateTime], :to_iso8601, 3} => {[1], :iso_format},
    {[:NaiveDateTime], :to_iso8601, 2} => {[1], :iso_format},
    {[:Time], :to_iso8601, 2} => {[1], :iso_format},
    {[:Date], :to_iso8601, 2} => {[1], :iso_format},
    {[:String], :upcase, 2} => {[1], :case_mode},
    {[:String], :downcase, 2} => {[1], :case_mode},
    {[:String], :capitalize, 2} => {[1], :case_mode},
    {[:String], :normalize, 2} => {[1], :norm_form},
    # Sort direction shorthand — the sorter is the trailing positional argument.
    {[:Enum], :sort, 2} => {[1], :order},
    {[:Enum], :sort_by, 3} => {[2], :order},
    {[:List], :keysort, 3} => {[2], :order},
    # Keyword-option modes — the atom is the *value* of a named key in the trailing options
    # list. `{:kw, [key: set]}` declares which key(s) to read and which value set to swap.
    {[:Base], :encode16, 2} => {[1], {:kw, [case: :base_case]}},
    {[:Base], :decode16, 2} => {[1], {:kw, [case: :base_case]}},
    {[:Base], :decode16!, 2} => {[1], {:kw, [case: :base_case]}},
    {[:Base], :encode32, 2} => {[1], {:kw, [case: :base_case]}},
    {[:Base], :decode32, 2} => {[1], {:kw, [case: :base_case]}},
    {[:Base], :decode32!, 2} => {[1], {:kw, [case: :base_case]}},
    {[:Base], :hex_encode32, 2} => {[1], {:kw, [case: :base_case]}},
    {[:Base], :hex_decode32, 2} => {[1], {:kw, [case: :base_case]}},
    {[:Base], :hex_decode32!, 2} => {[1], {:kw, [case: :base_case]}},
    {[:Regex], :scan, 3} => {[2], {:kw, [return: :regex_return]}},
    {[:Regex], :run, 3} => {[2], {:kw, [return: :regex_return]}},
    # Week-start day — the `starting_on` weekday atom (`:monday`…`:sunday`, `:default`). The
    # `/1` arities default it (no atom to swap), like `to_iso8601/1`.
    {[:Date], :day_of_week, 2} => {[1], :weekday},
    {[:Date], :beginning_of_week, 2} => {[1], :weekday},
    {[:Date], :end_of_week, 2} => {[1], :weekday},
    # URL query encoding — the trailing `encoding` atom (`:www_form` ↔ `:rfc3986`). On
    # `decode_query/3` it is the third argument; `encode_query/1`/`decode_query/2` default it.
    {[:URI], :encode_query, 2} => {[1], :uri_encoding},
    {[:URI], :decode_query, 3} => {[2], :uri_encoding}
  }

  @impl Mutare.Mutator
  def name, do: :mode_swap

  # Never fires node-locally: the mode atom's position depends on the call's effective
  # arity, which isn't knowable without pipe context.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.Mutator
  def mutate(node, %{pipe_mode: pipe_mode}) do
    case Calls.resolved_call(node) do
      {module, fun, args, rebuild} ->
        case rule(module, fun, args, pipe_mode) do
          {:ok, positions, group} ->
            case swap_sites(args, positions, group, pipe_mode) do
              [] ->
                :skip

              sites ->
                # `rebuild` keeps the same function and written alias, swapping only args.
                # Each site carries the replacement *arg node* — a fresh mode-atom literal,
                # or (for `shift`) the duration keyword list with one unit key swapped.
                Enum.map(sites, fn {vis, arg} ->
                  rebuild.(fun, List.replace_at(args, vis, arg))
                end)
            end

          :error ->
            :skip
        end

      nil ->
        :skip
    end
  end

  def mutate(_node, _context), do: :skip

  # The rule for a call at its *effective* arity (visible args + the piped value), or
  # `:error` when no rule applies.
  defp rule(mod, fun, args, pipe_mode) do
    eff_arity = Mutare.Mutator.effective_arity(args, pipe_mode)

    case Map.fetch(@rules, {mod, fun, eff_arity}) do
      {:ok, {positions, group}} -> {:ok, positions, group}
      :error -> :error
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

  # `:order` (the sort direction) accepts either the lone `:asc`/`:desc` shorthand or a
  # `{:asc | :desc, module}` tuple (the per-sort comparison-module form). Either way only
  # the direction is swapped; the tuple keeps its module. A non-direction value (a sorter
  # fun, a variable) yields nothing.
  defp order_swaps(arg) do
    case order_target(arg) do
      nil -> []
      {dir, rebuild} -> for new <- swaps(:order, dir), do: rebuild.(AST.literal(new))
    end
  end

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
  # `:default` (≡ `:monday`) maps to a concrete neighbour, mirroring `System`'s `:native`.
  defp swaps(:weekday, :default), do: [:tuesday]
  defp swaps(:weekday, atom), do: neighbours(@weekday_ladder, atom)
  defp swaps(:uri_encoding, atom), do: Map.get(@uri_encoding, atom, [])

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

  # The atom carried by an argument node, if it is an atom literal — Sourceror's
  # block-wrapped form or a bare atom. `true`/`false`/`nil` are never mode atoms.
  defp mode_atom({:__block__, _meta, [a]}) when is_atom(a) and a not in [true, false, nil],
    do: [a]

  defp mode_atom(a) when is_atom(a) and a not in [true, false, nil], do: [a]
  defp mode_atom(_node), do: []
end
