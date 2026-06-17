defmodule Mutare.Mutators.StringCall do
  @moduledoc """
  Swap complementary `String` calls for their directional opposite:

    * `String.starts_with?` ↔ `String.ends_with?`
    * `String.upcase` ↔ `String.downcase`
    * `String.trim_leading` ↔ `String.trim_trailing`
    * `String.replace_prefix` ↔ `String.replace_suffix`
    * `String.pad_leading` ↔ `String.pad_trailing`
    * `String.first` ↔ `String.last`

  Each pair shares its arities, so swapping the function name while keeping the
  argument list always compiles. These are remote calls — never legal in a guard
  — so guard-safety is automatic. The sibling of `Mutare.Mutators.Collection`
  (the `Enum`/`List` swaps); both recognise only **unaliased** calls by name, so
  a shadowing alias simply isn't matched (no false mutation).

  On by default — high signal on the affix/case/predicate functions that anchor
  string-handling logic, exactly where an off-by-direction bug hides. Distinct
  from `Mutare.Mutators.StringLiteral` (the `:string` family), which mutates the
  string *value*; this mutates the *call*.
  """
  @behaviour Mutare.Mutator

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

  @impl Mutare.Mutator
  def name, do: :string_call

  @impl Mutare.Mutator
  def mutate({{:., dot_meta, [{:__aliases__, alias_meta, mod}, fun]}, call_meta, args})
      when is_list(args) do
    case Map.fetch(@swaps, {mod, fun}) do
      {:ok, {new_mod, new_fun}} ->
        [{{:., dot_meta, [{:__aliases__, alias_meta, new_mod}, new_fun]}, call_meta, args}]

      :error ->
        :skip
    end
  end

  def mutate(_node), do: :skip
end
