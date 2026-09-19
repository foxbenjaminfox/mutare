defmodule Mutare.Test.ClobberingHostMutator do
  @moduledoc """
  A selector host that claims more than its `:hosted` position — the shape of the mutare_ecto
  keyword-shorthand bug. `filter(query, condition)` routes the *query* `:hosted`, which is what
  makes core offer the call to the host, and the *condition* `:expression`, so core's own families
  mutate inside it. `host/2` targets the condition anyway. Its splice replaces the condition,
  which by then holds core's selectors, with a selector whose catch-all is the raw original: core's
  mutants keep their Sites and lose their branches, and the metamutant still compiles.
  `verify_invariants` is what notices.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.CallRouting
  @behaviour Mutare.Mutator.MacroHost

  alias Mutare.CallRouting.{ArgumentRoutes, Call}
  alias Mutare.Mutator.MacroHost.Target

  @impl Mutare.Mutator
  def name, do: :clobbering_host

  @impl Mutare.CallRouting
  def call_routes, do: [{Mutare.Test.HostDSL, :filter, 2, :routing}]

  @impl Mutare.CallRouting
  def route_arguments(%Call{} = call),
    do: ArgumentRoutes.new(call, [:hosted, :expression])

  @impl Mutare.Mutator.MacroHost
  def hosted_macros, do: [{Mutare.Test.HostDSL, :filter, 2}]

  @impl Mutare.Mutator.MacroHost
  def host(%Call{node: {_form, _meta, [_query, {:>, meta, operands} = condition]}}, _context) do
    splice = fn {form, call_meta, [query, _condition]}, selector ->
      {form, call_meta, [query, selector]}
    end

    [Target.new(condition, [{:>=, meta, operands}], splice)]
  end

  def host(_call, _context), do: []
end

defmodule Mutare.Test.StaleTokenMutator do
  @moduledoc """
  Increments an integer literal but keeps the original node's metadata — the Sourceror clean-meta
  mistake `Mutare.AST.literal/1` exists to prevent. The metadata's `:token` still reads the old
  digits, so the replacement renders as the original: a mutant no test can kill.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :stale_token

  @impl Mutare.Mutator
  def mutate({:__block__, meta, [n]}) when is_integer(n), do: [{:__block__, meta, [n + 1]}]
  def mutate(_node), do: []
end

defmodule Mutare.Test.UniqueLiteralMutator do
  @moduledoc """
  Adds a fresh positive `System.unique_integer/1` to an integer literal on every call, so two
  renders of one source never agree — a nondeterministic mutator.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :unique_literal

  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [n]}) when is_integer(n),
    do: [Mutare.AST.literal(n + System.unique_integer([:positive, :monotonic]))]

  def mutate(_node), do: []
end
