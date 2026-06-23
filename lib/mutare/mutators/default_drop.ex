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

  On by default. Matches aliased and bare-imported calls too.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Transform.Calls

  # {alias_path, function, effective_arity} => base function the call collapses to.
  # The operation is uniform: drop the trailing (default/fallback) argument, rename to
  # this function. The implicit default of each base is nil, so a literal-nil trailing
  # arg is skipped as equivalent (`AST.nil_literal?/1`).
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
  def mutate(node, %{pipe_mode: pipe_mode}) do
    case Calls.resolved_call(node) do
      {module, fun, args, rebuild} ->
        eff_arity = Mutare.Mutator.effective_arity(args, pipe_mode)

        case Map.fetch(@rules, {module, fun, eff_arity}) do
          {:ok, new_fun} ->
            {dropped, kept} = List.pop_at(args, -1)

            if AST.nil_literal?(dropped) do
              # Equivalent: the explicit default already equals the implicit one.
              :skip
            else
              # `rebuild` reuses the written alias node.
              [rebuild.(new_fun, kept)]
            end

          :error ->
            :skip
        end

      nil ->
        :skip
    end
  end

  def mutate(_node, _context), do: :skip
end
