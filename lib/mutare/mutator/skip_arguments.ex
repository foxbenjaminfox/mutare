defmodule Mutare.Mutator.SkipArguments do
  @moduledoc """
  Adds the `:skip_arguments` option to a value-literal mutator in one line.

  A value family (`StringLiteral`, `BitstringLiteral`, `TupleLiteral`, …) mutates a whole *literal*
  argument, so "leave this position alone" is a natural per-project option. `use
  Mutare.Mutator.SkipArguments` injects the two callbacks that wire it up — `c:Mutare.Mutator.argument_marks/1`
  (declaring the configured positions) and a `c:Mutare.Mutator.mutate/2` gate that declines at a
  self-marked position and otherwise delegates to the family's own `mutate/1`:

      defmodule Mutare.Mutators.TupleLiteral do
        @behaviour Mutare.Mutator
        use Mutare.Mutator.SkipArguments

        @impl true
        def name, do: :tuple

        @impl true
        def mutate({:{}, meta, elems}) when length(elems) > 0, do: [{:{}, meta, []}]
        def mutate(_node), do: :skip
      end

  Users then write `{Mutare.Mutators.TupleLiteral, skip_arguments: [{MyApp, :store, 2, [1]}]}` — a
  list of `{module, function, arity, positions}`, where `positions` is a list of effective argument
  indices and `{:keyword, key}` option keys (see `Mutare.Mutator.argument_marks_from/2`). The marks
  are per-instance (labeled with the instance name), so two `:as` copies don't collide, and a bad
  index fails loudly at startup.

  A family that needs *extra* logic in `mutate/2` — `Mutare.Mutators.IntegerLiteral`/`AtomLiteral` also gate
  on the built-in `:timeout`/`:infinity` marks — doesn't use this mixin; it calls
  `Mutare.Mutator.skip_arguments_marks/1` and `Mutare.Mutator.self_marked?/1` by hand instead.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      @impl Mutare.Mutator
      def argument_marks(config), do: Mutare.Mutator.skip_arguments_marks(config)

      # `mutate/2` takes precedence at dispatch, so this gate applies to every offer while the
      # family's own `mutate/1` clauses stay the source of the mutation (and directly callable).
      @impl Mutare.Mutator
      def mutate(node, context) do
        if Mutare.Mutator.self_marked?(context), do: :skip, else: mutate(node)
      end
    end
  end
end
