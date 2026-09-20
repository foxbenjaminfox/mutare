defmodule Mutare.Test.LazyDSL do
  @moduledoc false
  # A macro that does not evaluate its first argument eagerly, exactly once, and first — what a
  # `:lazy_expression` route on that position tells Mutare to respect.

  @doc "Evaluates `value` only when `enabled?` holds — after it, and possibly never."
  defmacro lazy(value, enabled?) do
    quote do
      if unquote(enabled?), do: unquote(value), else: :skipped
    end
  end
end

defmodule Mutare.Test.OptionsDSL do
  @moduledoc false
  # Macros taking a literal keyword list, in a body and in a guard — the argument shape a keyed
  # refinement routes.

  @doc "The sum of the options' values."
  defmacro total(opts), do: quote(do: Enum.sum(Keyword.values(unquote(opts))))

  @doc "Guard-safe: whether `x` lies within the literal `min:`/`max:` options."
  defmacro within(x, opts) do
    quote do
      unquote(x) >= unquote(opts[:min]) and unquote(x) <= unquote(opts[:max])
    end
  end
end

defmodule Mutare.Test.LazyStageMutator do
  @moduledoc """
  A whole-call mutation on a `Mutare.Test.LazyDSL.lazy/2` call, which it registers **no route**
  for: to core the call is an ordinary one, a function for all it can tell.
  """
  @behaviour Mutare.Mutator

  @impl true
  def name, do: :lazy_stage

  @impl true
  def mutate({:lazy, meta, args}) when is_list(args) and args != [],
    do: [{:lazy, meta, List.replace_at(args, -1, Mutare.AST.literal(true))}]

  def mutate(_node), do: :skip
end
