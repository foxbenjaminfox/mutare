defmodule Mutare.Mutators.DefaultDrop do
  @moduledoc """
  Drop a trailing **default / fallback** argument from a lookup, reverting it to the
  implicit `nil` default. Asks the question mutation testing exists for: is the
  *not-found* path — where your chosen default actually matters — covered by a test?
  A survivor here means nobody asserts that an absent key/index returns your default
  rather than `nil`.

    * `Map.get/3` → `Map.get/2`            `Keyword.get/3` → `Keyword.get/2`
    * `Map.pop/3` → `Map.pop/2`            `Keyword.pop/3` → `Keyword.pop/2`
    * `Enum.at/3` → `Enum.at/2`
    * `List.first/2` → `List.first/1`      `List.last/2` → `List.last/1`
    * `Map.get_lazy/3` → `Map.get/2`       `Keyword.get_lazy/3` → `Keyword.get/2`
    * `Map.pop_lazy/3` → `Map.pop/2`       `Keyword.pop_lazy/3` → `Keyword.pop/2`

  The implicit default of every base form here is `nil`, so a **literal `nil`**
  default is skipped — dropping it would be an equivalent no-op (`Map.get(m, k, nil)`
  ≡ `Map.get(m, k)`). A non-`nil` default (`:none`, `0`, `[]`, a variable, an
  expression) is dropped, because that *is* the observable difference a test should
  pin. The `_lazy` forms drop their fallback function and rename to the base lookup;
  the fun is never `nil`, so they always apply.

  ## Why it's pipe-aware (`mutate/2`, never `mutate/1`)

  This changes a call's arity (`/3`→`/2`), and a pipe stage carries one fewer argument
  than the source reads (the collection is the `|>` left side), so `m |> Map.get(k, d)`
  reaches a mutator as a 2-arg node, ambiguous with a non-piped `Map.get(k, d)` (a
  legitimate `/2` call with nothing to drop). The optional `mutate/2` callback receives
  `%{piped: boolean}`; effective arity = visible args + (piped? 1 : 0) selects only the
  with-default forms, and the trailing *visible* argument (always the default/fallback,
  piped or not) is the one dropped.

  Every result reuses the surviving argument AST and the lower-arity form always exists,
  so the single build stays compile-safe; remote calls are guard-safe for free. On by
  default. Recognises the lookups by their resolved module (`Mutare.Transform.Aliases`),
  so an aliased call is matched too.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Transform.Aliases

  # {alias_path, function, effective_arity} => base function the call collapses to.
  # The operation is uniform: drop the trailing (default/fallback) argument, rename to
  # this function. The implicit default of each base is nil, so a literal-nil trailing
  # arg is skipped as equivalent (`nil_literal?/1`).
  @rules %{
    {[:Map], :get, 3} => :get,
    {[:Keyword], :get, 3} => :get,
    {[:Map], :pop, 3} => :pop,
    {[:Keyword], :pop, 3} => :pop,
    {[:Enum], :at, 3} => :at,
    {[:List], :first, 2} => :first,
    {[:List], :last, 2} => :last,
    {[:Map], :get_lazy, 3} => :get,
    {[:Keyword], :get_lazy, 3} => :get,
    {[:Map], :pop_lazy, 3} => :pop,
    {[:Keyword], :pop_lazy, 3} => :pop
  }

  @impl Mutare.Mutator
  def name, do: :default_drop

  # Never fires node-locally: distinguishing a `/3` (drop the default) from a piped
  # `/2` (nothing to drop) needs pipe context.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.Mutator
  def mutate({{:., dot_meta, [{:__aliases__, alias_meta, mod}, fun]}, call_meta, args}, %{
        piped: piped?
      })
      when is_list(args) do
    eff_arity = length(args) + if(piped?, do: 1, else: 0)

    case Map.fetch(@rules, {Aliases.resolved_module(alias_meta, mod), fun, eff_arity}) do
      {:ok, new_fun} ->
        {dropped, kept} = List.pop_at(args, -1)

        if nil_literal?(dropped) do
          # Equivalent: the explicit default already equals the implicit one.
          :skip
        else
          [{{:., dot_meta, [{:__aliases__, alias_meta, mod}, new_fun]}, call_meta, kept}]
        end

      :error ->
        :skip
    end
  end

  def mutate(_node, _context), do: :skip

  # A literal `nil` — bare, or Sourceror's block-wrapped form.
  defp nil_literal?(nil), do: true
  defp nil_literal?({:__block__, _meta, [nil]}), do: true
  defp nil_literal?(_), do: false
end
