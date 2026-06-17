defmodule Mutare.Mutators.StringCall do
  @moduledoc """
  Swap complementary `String` calls for their directional opposite:

    * `String.starts_with?` ↔ `String.ends_with?`
    * `String.upcase` ↔ `String.downcase`
    * `String.trim_leading` ↔ `String.trim_trailing`
    * `String.replace_prefix` ↔ `String.replace_suffix`
    * `String.pad_leading` ↔ `String.pad_trailing`
    * `String.first` ↔ `String.last`

  …plus the Erlang `:string` module's directional/case pairs:

    * `:string.uppercase` ↔ `:string.lowercase`  (analogue of `upcase`/`downcase`)
    * `:string.to_upper` ↔ `:string.to_lower`     (the legacy case pair)
    * `:string.left` ↔ `:string.right`            (justify/pad direction — the
      analogue of `pad_leading`/`pad_trailing`)

  (The trim/predicate pairs have no `:string` twin — there the *direction* is an
  argument atom, e.g. `:string.trim(s, :leading)`, not a distinct function name,
  so renaming cannot express the swap.)

  It also makes one **call → operator** substitution: `String.equivalent?(a, b)`
  (Unicode-canonical equality) → raw `a == b`, dropping the normalization. The
  mutant survives unless a test feeds canonically-equivalent-but-distinct
  encodings — pointing at exactly that gap. Arity tells the pipe context apart
  (`equivalent?/1` doesn't exist, so a 1-arg call is always a `|>` stage):
  `a |> String.equivalent?(b)` becomes `a |> Kernel.==(b)`.

  Each pair shares its arities, so swapping the function name while keeping the
  argument list always compiles. These are remote calls — never legal in a guard
  — so guard-safety is automatic. The sibling of `Mutare.Mutators.Collection`
  (the `Enum`/`List` swaps); both recognise only **unaliased** calls by name, so
  a shadowing alias simply isn't matched (no false mutation).

  On by default — high signal on the affix/case/predicate functions that anchor
  string-handling logic, exactly where an off-by-direction bug hides. Distinct
  from `Mutare.Mutators.StringLiteral` (the `:string` family), which mutates the
  string *value*; this mutates the *call*. Recognises `String` by its resolved
  module (`Mutare.Transform.Aliases`), so an aliased `S.upcase` (`alias String, as: S`)
  is matched too.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Transform.Aliases

  # {alias_path, function} => {alias_path, function}
  @swaps %{
    {[:String], :starts_with?} => {[:String], :ends_with?},
    {[:String], :ends_with?} => {[:String], :starts_with?},
    {[:String], :upcase} => {[:String], :downcase},
    {[:String], :downcase} => {[:String], :upcase},
    {[:String], :trim_leading} => {[:String], :trim_trailing},
    {[:String], :trim_trailing} => {[:String], :trim_leading},
    {[:String], :replace_prefix} => {[:String], :replace_suffix},
    {[:String], :replace_suffix} => {[:String], :replace_prefix},
    {[:String], :pad_leading} => {[:String], :pad_trailing},
    {[:String], :pad_trailing} => {[:String], :pad_leading},
    {[:String], :first} => {[:String], :last},
    {[:String], :last} => {[:String], :first}
  }

  # Erlang `:string` module — the module is a bare atom in the AST, not an
  # `{:__aliases__, …}` node. function => function (same module).
  @erlang_swaps %{
    uppercase: :lowercase,
    lowercase: :uppercase,
    to_upper: :to_lower,
    to_lower: :to_upper,
    left: :right,
    right: :left
  }

  @impl Mutare.Mutator
  def name, do: :string_call

  @impl Mutare.Mutator
  def mutate({{:., dot_meta, [{:__aliases__, alias_meta, mod} = aliases, fun]}, call_meta, args})
      when is_list(args) do
    case Aliases.resolved_module(alias_meta, mod) do
      # `String.equivalent?(a, b)` → raw `a == b`, alias-resolved like the swaps.
      [:String] when fun == :equivalent? ->
        equivalent_substitution(args)

      resolved ->
        case Map.fetch(@swaps, {resolved, fun}) do
          {:ok, {_new_mod, new_fun}} ->
            # Reuse the literal alias node (the swap stays within `String`).
            [{{:., dot_meta, [aliases, new_fun]}, call_meta, args}]

          :error ->
            :skip
        end
    end
  end

  # `:string.uppercase(s)` and friends. The module is the atom `:string` — wrapped
  # by Sourceror as `{:__block__, _, [:string]}`, but a bare atom in plain AST.
  def mutate({{:., dot_meta, [{:__block__, _, [:string]} = mod, fun]}, call_meta, args})
      when is_list(args),
      do: swap_erlang(dot_meta, mod, fun, call_meta, args)

  def mutate({{:., dot_meta, [:string, fun]}, call_meta, args}) when is_list(args),
    do: swap_erlang(dot_meta, :string, fun, call_meta, args)

  def mutate(_node), do: :skip

  # `String.equivalent?(a, b)` compares strings for Unicode canonical equivalence;
  # substituting raw `==` drops the normalization, so the mutant survives unless a
  # test feeds canonically-equivalent-but-distinct encodings. Arity disambiguates the
  # pipe context (`String.equivalent?/1` doesn't exist, so a 1-arg call is always a
  # `|>` stage): piped, `a |> String.equivalent?(b)` becomes `a |> Kernel.==(b)`.
  defp equivalent_substitution([a, b]), do: [{:==, [], [a, b]}]

  defp equivalent_substitution([b]),
    do: [{{:., [], [{:__aliases__, [], [:Kernel]}, :==]}, [], [b]}]

  defp equivalent_substitution(_), do: :skip

  defp swap_erlang(dot_meta, mod, fun, call_meta, args) do
    case Map.fetch(@erlang_swaps, fun) do
      {:ok, new_fun} -> [{{:., dot_meta, [mod, new_fun]}, call_meta, args}]
      :error -> :skip
    end
  end
end
