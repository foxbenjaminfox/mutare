defmodule Mutare.Test.RoutedSoak do
  @moduledoc """
  The routed callees the transform property soaks pipe into
  (`Mutare.TransformPropertyGenerators.routed_call_gen/1`), with the positional routes the soaks
  transform under (`call_routes/0`). Both are total and pure for any term, so baseline
  equivalence stays deterministic.

    * `keep/3` — a **function** routed `[:expression, :raw, :expression]`. Its middle argument
      is the generator's bait (`1 < 2`, which several families would mutate if offered), so a
      reading of a piped stage that lands the treatments one argument late shows up as a mutant
      inside it. Position 0 is a value, so a stage written as a pipe takes the bound delivery
      (`Mutare.Transform.PipeEmit.delivery/2`).
    * `pick/2` — a **macro** that evaluates its first argument only when the second holds,
      routed `[:lazy_expression, :expression]`: never evaluated ahead of the call, so a piped
      stage takes plain direct delivery.
  """

  @doc "The `call_routes:` entries for this module's callees."
  @spec call_routes() :: [tuple()]
  def call_routes do
    [
      {__MODULE__, :keep, 3, [:expression, :raw, :expression]},
      {__MODULE__, :pick, 2, [:lazy_expression, :expression]}
    ]
  end

  @doc "Each callee's arity as a directly written call."
  @spec arities() :: %{atom() => pos_integer()}
  def arities, do: %{keep: 3, pick: 2}

  @doc "Pairs `value` with `extra`; `_raw` is evaluated and dropped."
  @spec keep(term(), term(), term()) :: {term(), term()}
  def keep(value, _raw, extra), do: {value, extra}

  @doc "`value` when `on?` is truthy — evaluated after it, and possibly never."
  defmacro pick(value, on?) do
    quote do
      if unquote(on?), do: unquote(value), else: :skipped
    end
  end
end

defmodule Mutare.Test.RoutedSoakMutator do
  @moduledoc """
  Whole-call mutants on `Mutare.Test.RoutedSoak`'s callees. No built-in family lands one on a
  call outside the standard library, and a whole-call mutant is what puts a selector *on* a
  rewritten stage — the only thing that makes `Mutare.Transform.PipeEmit.delivery/2`
  choose between the bound and the plain delivery, and
  `Mutare.Transform.WrittenPipe.stage_attribution/2` between the stage and the whole pipe.

    * every call has its last argument replaced by `:mutare_soak` (argument 0 kept: reported at
      the stage; a `keep/3` stage is bound, a `:lazy_expression` `pick/2` stage never is);
    * a `keep/3` whose argument 0 is a bare variable also has *that* replaced — a candidate
      that rewrites argument 0, which sends the site to plain delivery and is reported over the
      whole pipe.

  `:mutare_soak` is outside the generators' atom pool, so no mutant equals its original.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Calls
  alias Mutare.Test.RoutedSoak

  @impl Mutare.Mutator
  def name, do: :routed_soak

  @impl Mutare.Mutator
  def mutate(node) do
    with :error <- keep_mutations(Calls.resolved_call_to(node, RoutedSoak, :keep)),
         :error <- pick_mutations(Calls.resolved_call_to(node, RoutedSoak, :pick)) do
      :skip
    end
  end

  defp keep_mutations({:ok, _keep, [value, raw, _extra], rebuild}) do
    [rebuild.(:keep, [value, raw, soak()])] ++
      case value do
        {name, _meta, context} when is_atom(name) and is_atom(context) ->
          [rebuild.(:keep, [soak(), raw, soak()])]

        _computed ->
          []
      end
  end

  defp keep_mutations(_other), do: :error

  defp pick_mutations({:ok, _pick, [value, _on?], rebuild}),
    do: [rebuild.(:pick, [value, soak()])]

  defp pick_mutations(_other), do: :error

  defp soak, do: Mutare.AST.literal(:mutare_soak)
end
