defmodule Mutare.Mutators.MapKeyword do
  @moduledoc """
  Swap a `Map`/`Keyword` insert for its overwrite-semantics complement:

    * `Map.put` ↔ `Map.put_new`
    * `Keyword.put` ↔ `Keyword.put_new`

  `put` always writes the key; `put_new` writes it only when absent. The two share
  arity (`/3`), so swapping the function name while keeping the argument list always
  compiles — an arity-blind rename like `Mutare.Mutators.Collection`, correct in a
  pipe for free. These are remote calls — never legal in a guard — so guard-safety
  is automatic.

  High signal: the `put`/`put_new` distinction (does overwriting an existing key
  matter?) is a classic untested edge — a test that never exercises the
  already-present-key path won't notice the swap. On by default. Recognises only
  unaliased `Map`/`Keyword` calls by name, so a shadowing alias isn't matched (no
  false mutation). The family atom is `:map_keyword` (`:map` is `MapLiteral`).
  """
  @behaviour Mutare.Mutator

  # {alias_path, function} => {alias_path, function}
  @swaps %{
    {[:Map], :put} => {[:Map], :put_new},
    {[:Map], :put_new} => {[:Map], :put},
    {[:Keyword], :put} => {[:Keyword], :put_new},
    {[:Keyword], :put_new} => {[:Keyword], :put}
  }

  @impl Mutare.Mutator
  def name, do: :map_keyword

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
