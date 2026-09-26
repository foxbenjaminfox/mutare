defmodule Mutare.RebuiltCallReuseTest do
  @moduledoc """
  A replacement's walk returns a node as it is only where the node was resolved, and
  resolved in the environment now in force — not wherever the term happens to occur in the
  offered node.

  Two ways the weaker reading (any subtree of the offered node is "already resolved") went
  wrong, both false survivors the source patch would have killed:

  A subtree the offered call's route kept as syntax — the `:raw` argument of `keep(value,
  _syntax)` — was never resolved, so it carries no route. A mutator that returns that
  subtree makes it executable source, and the walk must resolve it there for the first
  time: `DSL.ignored(p = 7)` is a routed macro that discards its argument, and a reader
  that takes it as an ordinary call credits the write `p = 7` the macro never makes.

  A call the walk did resolve can be moved beneath a directive that changes what it
  resolves to. `alias Discard, as: Local; Local.value(p = 6)` wraps the offered
  `Local.value(p = 6)` — the identical term — in a block whose alias shadows the file's,
  and the compiler resolves the patch by the new alias. The walk must too: the retained
  environment says `Eager.value/1`, an ordinary function, where the call is now the macro
  `Discard.value/1`.

  A desugaring can go stale the same way. The walk makes `(p = 6) |> Function.identity()`
  the direct call `Function.identity(p = 6)`, which is what `Kernel.|>/2` means by it. A
  mutator that wraps the offered call — the identical term, its pipe spelling stamped on —
  in `(import Kernel, except: [|>: 2]; import DiscardPipe, only: [|>: 2]; …)` changes what
  the written `|>` means; the renderer spells the call as that pipe again, so the compiler
  reads `DiscardPipe.|>/2`, a macro that discards both operands. Re-resolving the direct
  call finds no operator to reconsider: the walk must hand the pipe back as written, and
  resolve it there.

  Neither repair may be undone by a boundary. A mutator that puts the offered call beneath a
  fresh *skipped* call — `(alias Discard, as: Local; Function.identity(Local.value(p = 6)))`
  with `Function.identity/1` skipped, or the pipe beneath the imports and a skipped
  `List.first/1` — leaves it where the walk does not go: a skip keeps its arguments as
  written. The binding readers still read them, since a skipped call's arguments run, and
  what they find there must be the source the patch spells — no alias stamp naming `Eager`,
  no direct call presuming `Kernel`'s `|>` — so the walk returns the region as written.

  The end-to-end tests accept either faithful delivery or a withheld mutant; the unit tests
  pin what the rerouted node reads as. Each hazard has a control that reaches the same
  source through fresh syntax (a reparsed copy of the same term), which the walk always
  resolved — the difference between hazard and control is provenance alone.
  """
  use ExUnit.Case, async: true

  import Mutare.Test.SourcePatch, only: [assert_patches: 4]

  alias Mutare.CallRouting.Registry
  alias Mutare.Transform.{BindingEscapeEmit, Meta, Resolve, WrittenPipe}

  defmodule DSL do
    # Splices `value` into the caller; the second argument is syntax the macro discards.
    defmacro keep(value, _syntax), do: value
    defmacro ignored(_expression), do: 6
  end

  defmodule Eager do
    def value(value), do: value
  end

  defmodule Discard do
    defmacro value(_expression), do: 6
  end

  defmodule DiscardPipe do
    import Kernel, except: [|>: 2]
    defmacro _left |> _right, do: 6
  end

  # `keep(first, second)` → `second`: the raw argument, made executable. With `reparse:`
  # the same source through fresh syntax.
  defmodule SelectSecond do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallReuseTest.DSL

    @impl Mutare.Mutator
    def name, do: :select_second

    @impl Mutare.Mutator
    def mutate(node, %{opts: opts}) do
      case Mutare.Calls.resolved_call_to(node, DSL, :keep) do
        {:ok, :keep, [_first, second], _rebuild} -> [maybe_reparse(second, opts)]
        _other -> :skip
      end
    end

    def maybe_reparse(node, opts) do
      if Keyword.get(opts, :reparse, false),
        do: node |> Macro.to_string() |> Code.string_to_quoted!(),
        else: node
    end
  end

  # `Local.value(e)` → `(alias Discard, as: Local; Local.value(e))`: the offered call, the
  # identical term, beneath an alias that changes its callee.
  defmodule ShadowAlias do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallReuseTest.{Discard, Eager, SelectSecond}

    @impl Mutare.Mutator
    def name, do: :shadow_alias

    @impl Mutare.Mutator
    def mutate(node, %{opts: opts}) do
      case Mutare.Calls.resolved_call_to(node, Eager, :value) do
        {:ok, :value, _arguments, _rebuild} ->
          directive = Code.string_to_quoted!("alias #{inspect(Discard)}, as: Local")
          [{:__block__, [], [directive, SelectSecond.maybe_reparse(node, opts)]}]

        _other ->
          :skip
      end
    end
  end

  # `left |> Function.identity()` → `(import Kernel, except: [|>: 2]; import DiscardPipe,
  # only: [|>: 2]; left |> Function.identity())`: the offered call, the identical term with
  # its pipe spelling stamped on, beneath imports that change what `|>` means. With
  # `reparse:` the same pipe through fresh syntax — resugared first, since the direct call
  # printed alone is not the source the stamp spells.
  defmodule ShadowPipe do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallReuseTest.DiscardPipe

    @impl Mutare.Mutator
    def name, do: :shadow_pipe

    @impl Mutare.Mutator
    def mutate(node, %{opts: opts}) do
      case Mutare.Calls.resolved_call_to(node, Function, :identity) do
        {:ok, :identity, [_operand], _rebuild} ->
          if Mutare.Transform.Meta.written_pipe_meta(node),
            do: [replacement(node, Keyword.get(opts, :reparse, false))],
            else: :skip

        _other ->
          :skip
      end
    end

    def replacement(node, reparse?) do
      {:__block__, _meta, directives} =
        Code.string_to_quoted!("""
        import Kernel, except: [|>: 2]
        import #{inspect(DiscardPipe)}, only: [|>: 2]
        """)

      expression =
        if reparse?,
          do:
            node
            |> Mutare.Transform.WrittenPipe.resugar()
            |> Macro.to_string()
            |> Code.string_to_quoted!(),
          else: node

      {:__block__, [], directives ++ [expression]}
    end
  end

  # The two shadowing mutants above with the offered call beneath a call their routes skip:
  # `(alias Discard, as: Local; Function.identity(Local.value(e)))` and `(import …;
  # List.first([left |> Function.identity()]))`.
  defmodule ShadowAliasUnderSkip do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallReuseTest.{Discard, Eager, SelectSecond}

    @impl Mutare.Mutator
    def name, do: :shadow_alias_under_skip

    @impl Mutare.Mutator
    def mutate(node, %{opts: opts}) do
      case Mutare.Calls.resolved_call_to(node, Eager, :value) do
        {:ok, :value, _arguments, _rebuild} -> [replacement(node, opts)]
        _other -> :skip
      end
    end

    def replacement(node, opts) do
      directive = Code.string_to_quoted!("alias #{inspect(Discard)}, as: Local")
      wrapped = {{:., [], [Function, :identity]}, [], [SelectSecond.maybe_reparse(node, opts)]}
      {:__block__, [], [directive, wrapped]}
    end
  end

  defmodule ShadowPipeUnderSkip do
    @behaviour Mutare.Mutator
    alias Mutare.RebuiltCallReuseTest.ShadowPipe

    @impl Mutare.Mutator
    def name, do: :shadow_pipe_under_skip

    @impl Mutare.Mutator
    def mutate(node, %{opts: opts}) do
      case ShadowPipe.mutate(node, %{opts: opts}) do
        [replacement] -> [beneath_skip(replacement)]
        :skip -> :skip
      end
    end

    def beneath_skip({:__block__, meta, statements}) do
      {directives, [expression]} = Enum.split(statements, -1)
      {:__block__, meta, directives ++ [{{:., [], [List, :first]}, [], [[expression]]}]}
    end
  end

  # `ignored/1` through a classifier, so the test can see whether one was asked.
  defmodule ClassifiedIgnored do
    @behaviour Mutare.CallRouting
    alias Mutare.RebuiltCallReuseTest.DSL

    @impl Mutare.CallRouting
    def call_routes, do: [{DSL, :ignored, 1, :routing}]

    @impl Mutare.CallRouting
    def route_arguments(call) do
      send(self(), {__MODULE__, :classified})
      Mutare.CallRouting.ArgumentRoutes.new(call, [:lazy_expression])
    end
  end

  # `Discard.value/1` through a classifier.
  defmodule ClassifiedDiscard do
    @behaviour Mutare.CallRouting
    alias Mutare.RebuiltCallReuseTest.Discard

    @impl Mutare.CallRouting
    def call_routes, do: [{Discard, :value, 1, :routing}]

    @impl Mutare.CallRouting
    def route_arguments(call) do
      send(self(), {__MODULE__, :classified})
      Mutare.CallRouting.ArgumentRoutes.new(call, [:lazy_expression])
    end
  end

  @dsl inspect(DSL)
  @eager inspect(Eager)
  @discard inspect(Discard)

  @syntax_routes [{DSL, :keep, 2, [:expression, :raw]}, {DSL, :ignored, 1, [:lazy_expression]}]
  @syntax_opts [call_routes: @syntax_routes, clean_functions: false]

  @alias_routes [{Discard, :value, 1, [:lazy_expression]}]
  @alias_opts [call_routes: @alias_routes, clean_functions: false]

  @pipe_routes [{DiscardPipe, :|>, 2, [:raw, :raw]}]
  @pipe_opts [call_routes: @pipe_routes, clean_functions: false]

  @skip_identity {Function, :identity, 1, :skip}
  @skipped_alias_opts [call_routes: [@skip_identity | @alias_routes], clean_functions: false]

  @skipped_pipe_opts [
    call_routes: [{List, :first, 1, :skip} | @pipe_routes],
    clean_functions: false
  ]

  # Original `{[8, 6], false}`: `keep` splices `p = 6`. Selecting the raw argument gives
  # `{[8, 6], true}`: `ignored` discards `p = 7`, and the sibling's `p = 8` is the outgoing
  # binding — a write the mutant drops, which no branch may export over.
  @syntax_source """
  defmodule Fixture do
    require #{@dsl}

    def run do
      p = :incoming
      values = [p = 8, #{@dsl}.keep(p = 6, #{@dsl}.ignored(p = 7))]
      {values, p == 8}
    end
  end
  """

  # Original `{[8, 6], false}`: `Local` is `Eager`. Under the shadowing alias `Local.value`
  # is the macro that discards `p = 6`, so the patch gives `{[8, 6], true}`.
  @alias_source """
  defmodule Fixture do
    alias #{@eager}, as: Local
    require #{@discard}

    def run do
      p = :incoming
      values = [p = 8, Local.value(p = 6)]
      {values, p == 8}
    end
  end
  """

  # Original `{[8, 6], false}`: `Kernel.|>/2` pipes `p = 6` into `Function.identity/1`, and
  # the assignment runs. Under the imports `|>` is the macro that discards both operands, so
  # the patch gives `{[8, 6], true}`.
  @pipe_source """
  defmodule Fixture do
    def run do
      p = :incoming
      values = [p = 8, (p = 6) |> Function.identity()]
      {values, p == 8}
    end
  end
  """

  defp resolve(expression, routes, extensions \\ []) do
    registry = Registry.build(routes, [], extensions)
    expression |> Sourceror.parse_string!() |> Resolve.annotate(registry)
  end

  defp keep_call(routes \\ @syntax_routes, extensions \\ []),
    do: resolve("#{@dsl}.keep(p = 6, #{@dsl}.ignored(p = 7))", routes, extensions)

  defp piped_call, do: resolve("(p = 6) |> Function.identity()", @pipe_routes)

  # Every `:mutare_nid` dropped, in node metas and in the metas a meta carries alike.
  defp without_nids(list) when is_list(list),
    do: list |> Enum.reject(&match?({:mutare_nid, _}, &1)) |> Enum.map(&without_nids/1)

  defp without_nids(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&without_nids/1) |> List.to_tuple()

  defp without_nids(leaf), do: leaf

  # A grouped right side, which `Kernel` flattens before desugaring: the direct call is
  # `Function.identity(Function.identity(p = 6))`, its prefix a call of the offered node's.
  defp grouped_call,
    do: resolve("(p = 6) |> (Function.identity() |> Function.identity())", @pipe_routes)

  defp aliased_call(routes \\ @alias_routes, extensions \\ []) do
    {:__block__, _meta, [_directive, call]} =
      resolve("alias #{@eager}, as: Local\nLocal.value(p = 6)", routes, extensions)

    call
  end

  describe "a raw argument a mutant makes executable" do
    test "is resolved there for the first time: routed, and read by its route" do
      {_head, _meta, [_first, raw]} = original = keep_call()
      assert Mutare.Calls.routed_treatments(raw) == nil
      assert BindingEscapeEmit.expression_bindings(raw) == [:p]

      rerouted = Resolve.reroute(raw, original)
      assert Mutare.Calls.routed_treatments(rerouted) == [:lazy_expression]
      assert BindingEscapeEmit.expression_bindings(rerouted) == []
    end

    test "has its destination's classifier asked, which its raw position never did" do
      {_head, _meta, [_first, raw]} =
        original = keep_call([{DSL, :keep, 2, [:expression, :raw]}], [ClassifiedIgnored])

      refute_received {ClassifiedIgnored, :classified}

      rerouted = Resolve.reroute(raw, original)
      assert_received {ClassifiedIgnored, :classified}
      assert Mutare.Calls.routed_treatments(rerouted) == [:lazy_expression]
    end

    test "behaves as the patch that makes it executable" do
      assert_patches(@syntax_source, [SelectSecond], [run: []], @syntax_opts)
    end

    test "control: the same source through fresh syntax is withheld for the dropped write" do
      assert [] =
               assert_patches(
                 @syntax_source,
                 [{SelectSecond, reparse: true}],
                 [run: []],
                 @syntax_opts
               )
    end
  end

  describe "a resolved call a mutant moves beneath a fresh alias" do
    test "is resolved again by that alias" do
      original = aliased_call()
      assert {:ok, :value, _args, _rebuild} = Mutare.Calls.resolved_call_to(original, Eager)

      directive = Code.string_to_quoted!("alias #{@discard}, as: Local")

      {:__block__, _meta, [_directive, call]} =
        Resolve.reroute({:__block__, [], [directive, original]}, original)

      assert {:ok, :value, _args, _rebuild} = Mutare.Calls.resolved_call_to(call, Discard)
      assert Mutare.Calls.routed_treatments(call) == [:lazy_expression]
      assert BindingEscapeEmit.expression_bindings(call) == []
    end

    test "behaves as its patch" do
      assert_patches(@alias_source, [ShadowAlias], [run: []], @alias_opts)
    end

    test "control: the same source through fresh syntax is withheld for the dropped write" do
      assert [] =
               assert_patches(
                 @alias_source,
                 [{ShadowAlias, reparse: true}],
                 [run: []],
                 @alias_opts
               )
    end

    test "control: in the environment it was resolved in, it is the identical term" do
      original = aliased_call()
      assert Resolve.reroute(original, original) == original

      # Beneath a block that changes nothing it resolves by, too.
      {:__block__, _meta, [call]} = Resolve.reroute({:__block__, [], [original]}, original)
      assert call == original
    end
  end

  describe "a desugared pipe a mutant moves beneath another `|>`" do
    test "is resolved again as the pipe it was written, by that operator's route" do
      original = piped_call()
      assert is_list(Meta.written_pipe_meta(original))
      assert BindingEscapeEmit.expression_bindings(original) == [:p]

      {:__block__, _meta, statements} =
        rerouted = Resolve.reroute(ShadowPipe.replacement(original, false), original)

      call = List.last(statements)

      assert {:ok, :|>, [_left, _stage], _rebuild} =
               Mutare.Calls.resolved_call_to(call, DiscardPipe)

      assert Mutare.Calls.routed_treatments(call) == [:raw, :raw]
      assert BindingEscapeEmit.expression_bindings(rerouted) == []
    end

    test "reads as the same pipe through fresh syntax does" do
      original = piped_call()

      {:__block__, _meta, statements} =
        rerouted = Resolve.reroute(ShadowPipe.replacement(original, true), original)

      call = List.last(statements)

      assert {:ok, :|>, [_left, _stage], _rebuild} =
               Mutare.Calls.resolved_call_to(call, DiscardPipe)

      assert Mutare.Calls.routed_treatments(call) == [:raw, :raw]
      assert BindingEscapeEmit.expression_bindings(rerouted) == []
    end

    test "behaves as its patch" do
      assert_patches(@pipe_source, [ShadowPipe], [run: []], @pipe_opts)
    end

    test "control: the same source through fresh syntax is withheld for the dropped write" do
      assert [] =
               assert_patches(@pipe_source, [{ShadowPipe, reparse: true}], [run: []], @pipe_opts)
    end

    test "a grouped pipe is regrouped, and resolved again as the written pipe" do
      original = grouped_call()
      {_head, _meta, [prefix]} = original
      assert is_list(Meta.written_pipe_meta(prefix))

      {:__block__, _meta, statements} =
        rerouted = Resolve.reroute(ShadowPipe.replacement(original, false), original)

      call = List.last(statements)

      assert {:ok, :|>, [_left, _stage], _rebuild} =
               Mutare.Calls.resolved_call_to(call, DiscardPipe)

      assert Mutare.Calls.routed_treatments(call) == [:raw, :raw]
      assert BindingEscapeEmit.expression_bindings(rerouted) == []

      # Beneath an unrelated alias it is `Kernel`'s again: flattened, desugared and stamped
      # as the written walk had it, no prefix reused stale. Node ids aside: the continuation's
      # spelling copy of the remaining stage takes the pipe's identity, which
      # `WrittenPipe.direct/2` gave the direct call in the stage's place.
      {:__block__, _meta, [_directive, again]} =
        Resolve.reroute(
          {:__block__, [], [Code.string_to_quoted!("alias Enum, as: Unrelated"), original]},
          original
        )

      assert without_nids(Resolve.forget(again)) == without_nids(Resolve.forget(original))
    end

    test "a grouped pipe behaves as its patch" do
      source =
        String.replace(
          @pipe_source,
          "(p = 6) |> Function.identity()",
          "(p = 6) |> (Function.identity() |> Function.identity())"
        )

      assert_patches(source, [ShadowPipe], [run: []], @pipe_opts)
    end

    test "control: in the environment it was resolved in, it is the identical desugaring" do
      original = piped_call()
      assert Resolve.reroute(original, original) == original

      # Beneath a directive that changes the environment but not `|>`, reuse is refused and
      # the pipe is resolved again: `Kernel`'s, so the same desugaring is made of it, stamped
      # as the written walk stamped it — the retained environments alone differ.
      {:__block__, _meta, [_directive, call]} =
        Resolve.reroute(
          {:__block__, [], [Code.string_to_quoted!("alias Enum, as: Unrelated"), original]},
          original
        )

      assert is_list(Meta.written_pipe_meta(call))

      assert {:ok, :identity, [_operand], _rebuild} =
               Mutare.Calls.resolved_call_to(call, Function)

      assert BindingEscapeEmit.expression_bindings(call) == [:p]
      assert Resolve.forget(call) == Resolve.forget(original)

      assert Resolve.forget(WrittenPipe.resugar(call)) ==
               Resolve.forget(WrittenPipe.resugar(original))
    end
  end

  describe "a resolved call a mutant moves beneath a skipped call" do
    test "is returned as written, and read by the environment in force there" do
      original = aliased_call([@skip_identity | @alias_routes])
      assert BindingEscapeEmit.expression_bindings(original) == [:p]

      {:__block__, _meta, [_directive, wrapper]} =
        rerouted = Resolve.reroute(ShadowAliasUnderSkip.replacement(original, []), original)

      assert Mutare.Calls.routed_treatments(wrapper) == :skip
      {_head, _meta, [call]} = wrapper
      assert Meta.routing(elem(call, 1)) == nil
      assert Mutare.Calls.resolved_call_to(call, Eager) == :error
      assert BindingEscapeEmit.expression_bindings(rerouted) == []
    end

    test "behaves as its patch" do
      assert_patches(@alias_source, [ShadowAliasUnderSkip], [run: []], @skipped_alias_opts)
    end

    test "control: the same source through fresh syntax is withheld for the dropped write" do
      assert [] =
               assert_patches(
                 @alias_source,
                 [{ShadowAliasUnderSkip, reparse: true}],
                 [run: []],
                 @skipped_alias_opts
               )
    end

    test "control: beneath a skipped call that changes nothing, its writes are still read" do
      original = aliased_call([@skip_identity | @alias_routes])
      wrapped = {{:., [], [Function, :identity]}, [], [original]}
      assert BindingEscapeEmit.expression_bindings(Resolve.reroute(wrapped, original)) == [:p]
    end

    test "has no classifier asked beneath the skip, stale or fresh" do
      for opts <- [[], [reparse: true]] do
        original = aliased_call([@skip_identity], [ClassifiedDiscard])
        rerouted = Resolve.reroute(ShadowAliasUnderSkip.replacement(original, opts), original)

        assert BindingEscapeEmit.expression_bindings(rerouted) == []
        refute_received {ClassifiedDiscard, :classified}
      end
    end
  end

  describe "a desugared pipe a mutant moves beneath a skipped call" do
    test "is returned as the written pipe, and read by the operator in force there" do
      original = resolve("(p = 6) |> Function.identity()", @skipped_pipe_opts[:call_routes])
      assert BindingEscapeEmit.expression_bindings(original) == [:p]

      replacement = ShadowPipeUnderSkip.beneath_skip(ShadowPipe.replacement(original, false))
      {:__block__, _meta, statements} = rerouted = Resolve.reroute(replacement, original)
      {_head, _meta, [[pipe]]} = List.last(statements)

      assert {:|>, _pipe_meta, [_left, stage]} = pipe
      assert Meta.routing(elem(stage, 1)) == nil
      assert BindingEscapeEmit.expression_bindings(rerouted) == []
    end

    test "behaves as its patch" do
      assert_patches(@pipe_source, [ShadowPipeUnderSkip], [run: []], @skipped_pipe_opts)
    end

    test "control: the same source through fresh syntax is withheld for the dropped write" do
      assert [] =
               assert_patches(
                 @pipe_source,
                 [{ShadowPipeUnderSkip, reparse: true}],
                 [run: []],
                 @skipped_pipe_opts
               )
    end
  end
end
