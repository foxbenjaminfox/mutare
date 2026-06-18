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

  Unicode modes:

    * `String.upcase/2`, `String.downcase/2`, `String.capitalize/2` — the casing mode
      (`:default` ↔ `:ascii`; the exotic `:greek`/`:turkic` fall back to `:default`)
    * `String.normalize/2` — the normalization form (`:nfc` ↔ `:nfd`, `:nfkc` ↔ `:nfkd`,
      toggling composition while preserving compatibility)

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
  the rule is keyed on **effective arity** (`length(args) + if(piped, do: 1, else: 0)`)
  and each mode position is translated from an effective index to the *visible* one
  (`pos - 1` when piped; an effective index 0 that is the piped value itself is skipped).

  Every result reuses the surrounding argument AST and only substitutes one atom for
  another legal one, so the single metamutant build always compiles; the swapped atom is
  emitted with fresh metadata (`{:__block__, [], [atom]}`) so Sourceror renders the new
  value, not a stale token (the clean-meta rule). On by default.

  ## Owning the mode position

  A unit/mode atom sits in a value position, so `Mutare.Mutators.AtomLiteral` would
  *also* mutate it — `DateTime.truncate(dt, :second)` → `:mutare`, a mutant that just
  raises `ArgumentError` (an invalid precision) and is trivially killed. This mutator
  already covers that atom by rewriting the call, so it claims the position via the
  optional `owned_args/2` callback: `Mutare.Transform` then routes that argument through
  a non-mutating context, and AtomLiteral never sees it. Ownership is claimed **only
  where a swap is actually produced** (it reads the same `swap_sites/4` as `mutate/2`),
  so an unrecognised atom or a variable in a mode position stays available to AtomLiteral.

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

  # Unordered mode sets: one curated, behaviourally-distinct sibling per member.
  @case_modes %{default: [:ascii], ascii: [:default], greek: [:default], turkic: [:default]}
  @norm_forms %{nfc: [:nfd], nfd: [:nfc], nfkc: [:nfkd], nfkd: [:nfkc]}

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
    {[:System], :system_time, 1} => {[0], :system},
    {[:System], :monotonic_time, 1} => {[0], :system},
    {[:System], :os_time, 1} => {[0], :system},
    {[:System], :convert_time_unit, 3} => {[1, 2], :system},
    {[:String], :upcase, 2} => {[1], :case_mode},
    {[:String], :downcase, 2} => {[1], :case_mode},
    {[:String], :capitalize, 2} => {[1], :case_mode},
    {[:String], :normalize, 2} => {[1], :norm_form}
  }

  @impl Mutare.Mutator
  def name, do: :mode_swap

  # Never fires node-locally: the mode atom's position depends on the call's effective
  # arity, which isn't knowable without pipe context.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.Mutator
  def mutate(node, %{piped: piped?}) do
    case Calls.resolved_call(node) do
      {module, fun, args, rebuild} ->
        case rule(module, fun, args, piped?) do
          {:ok, positions, group} ->
            case swap_sites(args, positions, group, piped?) do
              [] ->
                :skip

              sites ->
                # `rebuild` keeps the same function and written alias, swapping only args.
                Enum.map(sites, fn {vis, atom} -> rebuild.(fun, replace_arg(args, vis, atom)) end)
            end

          :error ->
            :skip
        end

      nil ->
        :skip
    end
  end

  def mutate(_node, _context), do: :skip

  # Claim the unit/mode atom positions this call's rule actually swaps, so the transform
  # keeps other mutators (notably AtomLiteral) from firing in place on a leaf this mutator
  # already covers via the whole call. Same positions as `mutate/2` produces — both read
  # `swap_sites/4`, so ownership and mutation never drift.
  @impl Mutare.Mutator
  def owned_args(node, %{piped: piped?}) do
    case Calls.resolved_call(node) do
      {module, fun, args, _rebuild} ->
        case rule(module, fun, args, piped?) do
          {:ok, positions, group} ->
            args |> swap_sites(positions, group, piped?) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

          :error ->
            []
        end

      nil ->
        []
    end
  end

  def owned_args(_node, _context), do: []

  # The rule for a call at its *effective* arity (visible args + the piped value), or
  # `:error` when no rule applies.
  defp rule(mod, fun, args, piped?) do
    eff_arity = Mutare.Mutator.effective_arity(args, piped?)

    case Map.fetch(@rules, {mod, fun, eff_arity}) do
      {:ok, {positions, group}} -> {:ok, positions, group}
      :error -> :error
    end
  end

  # The `{visible_index, replacement_atom}` pairs this rule yields — one per legal sibling
  # of each recognised mode atom. A position whose visible arg isn't a recognised mode atom
  # (a variable, an integer parts-per-second, or the piped value itself) contributes none.
  # The single source of both the mutants and the owned positions.
  defp swap_sites(args, positions, group, piped?) do
    for pos <- positions,
        vis = Mutare.Mutator.visible_index(pos, piped?),
        vis != nil,
        atom <- mode_atom(Enum.at(args, vis)),
        new_atom <- swaps(group, atom) do
      {vis, new_atom}
    end
  end

  defp replace_arg(args, vis, atom), do: List.replace_at(args, vis, AST.literal(atom))

  # The legal sibling atoms for a swap. Ladders return the adjacent neighbour(s);
  # the System-only `:native` maps to a concrete unit; mode sets are a lookup.
  defp swaps(:truncate, atom), do: neighbours(@truncate_ladder, atom)
  defp swaps(:calendar, atom), do: neighbours(@calendar_ladder, atom)
  defp swaps(:system, :native), do: [:second]
  defp swaps(:system, atom), do: neighbours(@system_ladder, atom)
  defp swaps(:case_mode, atom), do: Map.get(@case_modes, atom, [])
  defp swaps(:norm_form, atom), do: Map.get(@norm_forms, atom, [])

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
