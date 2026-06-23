defmodule Mutare.Mutators.AliasLiteral do
  @moduledoc """
  Module-alias mutations: replace a literal alias used **as a value** with a
  distinct sentinel alias (`Mutare.Mutant`), dropping it when the original already
  equals the sentinel.

  An alias is mutated only where it is a runtime *value* — `apply(MyModule, :f, [])`,
  `x = MyModule`, `[A, B]`, `is_struct(x, MyModule)`, a behaviour/strategy module
  passed as an argument. A weak suite that never pins down *which* module is used
  there lets the sentinel survive; anywhere the module is actually invoked, the
  mutant (a nonexistent module) raises and is killed.

  It is **not** mutated where it is a *name/type* rather than a value:

    * the module side of a remote call (`MyModule.foo()`);
    * a struct name (`%MyStruct{…}`) — it is a type, and the sentinel is not a struct;
    * `alias`/`import`/`require`/`use` directives, `@behaviour`/`@type`/specs, and a
      `defmodule` name — all compile-time;
    * the module of a `defimpl`/`for:`, a `defprotocol`, or a `defdelegate` `to:` (a
      `defimpl`'s implementation *body* still mutates).

  Only fully-literal aliases (every segment an atom) are touched; a dynamic alias like
  `__MODULE__.Sub` or `unquote(m).Foo` is left alone.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST

  @sentinel AST.sentinel_alias()

  @impl Mutare.Mutator
  def name, do: :alias

  @impl Mutare.Mutator
  def mutate({:__aliases__, _meta, segments}) when is_list(segments) do
    if Enum.all?(segments, &is_atom/1) and segments != @sentinel,
      do: [{:__aliases__, [], @sentinel}],
      else: :skip
  end

  def mutate(_node), do: :skip
end
