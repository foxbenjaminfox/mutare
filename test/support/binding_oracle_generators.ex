defmodule Mutare.Test.BindingOracleGenerators do
  @moduledoc """
  Programs for the binding-reader oracle (`bindings_oracle_property_test.exs`): a function
  body of two to four statements over the parameters `a` and `b` and the names `p`, `q`,
  `r`, built with Elixir's scoping so that every program compiles — a read names only what
  is bound where it stands; siblings see the entry scope, not each other; a branch exports
  nothing; a block's statements accumulate. What the generator assumes bound is a
  conservative subset of what Elixir binds (a lazy macro's writes are not counted), so a
  program that fails to compile is a generator bug, never a scoping subtlety.

  The vocabulary is the binding model's: matches and pins at any depth, siblings of every
  shape (a call, a tuple, a list, an operator), blocks in argument position, `if` in its
  bare, qualified and aliased spellings, `case` with a binding clause, `destructure/2`,
  `match?/2`, and `Mutare.Test.BindingOracle`'s callees — the skipped wrapper, the three
  lazy macros, and the classifier-routed `unpack/2` (unknown beneath the wrapper).

  A pattern occurrence carries `oracle: :pattern` in its meta, so a renaming of a name's
  *reads* can leave its bindings alone (`rename_reads/3`); a call whose expansion binds what
  no static declaration claims carries `oracle: :lazy`, so a check knows where the model is
  allowed to be inexact (`inexact?/1`).
  """
  use PropCheck

  @params [:a, :b]
  @pool [:p, :q, :r]
  @oracle {:__aliases__, [], [:O]}
  @kernel {:__aliases__, [], [:Kernel]}
  @k {:__aliases__, [], [:K]}

  @doc "The names a program may bind or read: its parameters and its pool."
  def names, do: @params ++ @pool

  @doc "The parameters every program's function takes, in order."
  def params, do: @params

  @doc "The directives every rendering of a program starts with."
  def preamble do
    """
    require Mutare.Test.BindingOracle
    alias Mutare.Test.BindingOracle, as: O
    alias Kernel, as: K
    """
  end

  @doc "A program: `%{statements: [quoted]}`, two to four statements deep-generated."
  def program do
    let {count, depth} <- {integer(2, 4), integer(1, 3)} do
      let statements <- statements(MapSet.new(@params), count, depth) do
        %{statements: statements}
      end
    end
  end

  defp statements(_scope, 0, _depth), do: exactly([])

  defp statements(scope, count, depth) do
    let %{ast: ast, binds: binds} <- expr(scope, depth) do
      let rest <- statements(MapSet.union(scope, binds), count - 1, depth) do
        [ast | rest]
      end
    end
  end

  # --- expressions: each a generator of `%{ast: quoted, binds: MapSet}` -------------------

  defp expr(scope, 0), do: leaf(scope)

  defp expr(scope, depth) do
    sub = depth - 1

    frequency([
      {2, leaf(scope)},
      {3, match(scope, sub)},
      {1, pin_match(scope, sub)},
      {3, siblings(scope, sub)},
      {2, block(scope, sub)},
      {2, conditional(scope, sub)},
      {1, case_clauses(scope, sub)},
      {1, destructuring(scope, sub)},
      {1, unpack(scope, sub)},
      {1, match_predicate(scope, sub)},
      {2, wrapped(scope, sub)},
      {2, lazy(scope, sub)}
    ])
  end

  defp leaf(scope) do
    literals = for value <- [1, 2, :atom, nil, false], do: %{ast: value, binds: none()}
    reads = for name <- Enum.sort(scope), do: %{ast: var(name), binds: none()}
    oneof(literals ++ reads)
  end

  defp match(scope, sub) do
    let {name, inner} <- {name(), expr(scope, sub)} do
      %{ast: {:=, [], [pat(name), inner.ast]}, binds: MapSet.put(inner.binds, name)}
    end
  end

  # `{^x, name} = {x, inner}` — total: the pin reads `x` from before the whole match, and so
  # does the tuple's first element, whatever `inner` does to `x`.
  defp pin_match(scope, sub) do
    if MapSet.size(scope) == 0 do
      match(scope, sub)
    else
      let {pinned, name, inner} <- {oneof(Enum.sort(scope)), name(), expr(scope, sub)} do
        pattern = {{:^, [oracle: :pattern], [var(pinned)]}, pat(name)}

        %{
          ast: {:=, [], [pattern, {var(pinned), inner.ast}]},
          binds: MapSet.put(inner.binds, name)
        }
      end
    end
  end

  defp siblings(scope, sub) do
    let {shape, left, right} <-
          {oneof([:pair, :tuple, :list, :max]), expr(scope, sub), expr(scope, sub)} do
      ast =
        case shape do
          :pair -> call(@oracle, :pair, [left.ast, right.ast])
          :tuple -> {left.ast, right.ast}
          :list -> [left.ast, right.ast]
          :max -> {:max, [], [left.ast, right.ast]}
        end

      %{ast: ast, binds: MapSet.union(left.binds, right.binds)}
    end
  end

  defp block(scope, sub) do
    let first <- expr(scope, sub) do
      let second <- expr(MapSet.union(scope, first.binds), sub) do
        %{
          ast: {:__block__, [], [first.ast, second.ast]},
          binds: MapSet.union(first.binds, second.binds)
        }
      end
    end
  end

  defp conditional(scope, sub) do
    let {spelling, condition} <- {oneof([:bare, :qualified, :aliased]), expr(scope, sub)} do
      inner = MapSet.union(scope, condition.binds)

      let {yes, no} <- {expr(inner, sub), expr(inner, sub)} do
        args = [condition.ast, [do: yes.ast, else: no.ast]]

        ast =
          case spelling do
            :bare -> {:if, [], args}
            :qualified -> call(@kernel, :if, args)
            :aliased -> call(@k, :if, args)
          end

        %{ast: ast, binds: condition.binds}
      end
    end
  end

  # `case subject do 1 -> yes; name -> no end` — the second clause binds `name`.
  defp case_clauses(scope, sub) do
    let {name, subject} <- {name(), expr(scope, sub)} do
      after_subject = MapSet.union(scope, subject.binds)

      let {yes, no} <- {expr(after_subject, sub), expr(MapSet.put(after_subject, name), sub)} do
        clauses = [{:->, [], [[1], yes.ast]}, {:->, [], [[pat(name)], no.ast]}]
        %{ast: {:case, [], [subject.ast, [do: clauses]]}, binds: subject.binds}
      end
    end
  end

  defp destructuring(scope, sub) do
    let {{first, second}, left, right} <-
          {oneof([{:p, :q}, {:q, :r}, {:p, :r}]), expr(scope, sub), expr(scope, sub)} do
      ast = {:destructure, [], [[pat(first), pat(second)], [left.ast, right.ast]]}
      binds = left.binds |> MapSet.union(right.binds) |> MapSet.put(first) |> MapSet.put(second)
      %{ast: ast, binds: binds}
    end
  end

  defp unpack(scope, sub) do
    let {name, inner} <- {oneof(@pool), expr(scope, sub)} do
      %{
        ast: call(@oracle, :unpack, [[pat(name)], [inner.ast]]),
        binds: MapSet.put(inner.binds, name)
      }
    end
  end

  defp match_predicate(scope, sub) do
    let {name, inner} <- {oneof(@pool), expr(scope, sub)} do
      %{ast: {:match?, [], [{pat(name), pat(:_)}, inner.ast]}, binds: inner.binds}
    end
  end

  defp wrapped(scope, sub) do
    let inner <- expr(scope, sub) do
      %{ast: call(@oracle, :id, [inner.ast]), binds: inner.binds}
    end
  end

  defp lazy(scope, sub) do
    oneof([
      let(
        inner <- expr(scope, sub),
        do: %{ast: call(@oracle, :twice, [inner.ast], oracle: :lazy), binds: inner.binds}
      ),
      let condition <- expr(scope, sub) do
        let inner <- expr(MapSet.union(scope, condition.binds), sub) do
          %{ast: call(@oracle, :maybe, [inner.ast, condition.ast]), binds: condition.binds}
        end
      end,
      let second <- expr(scope, sub) do
        let first <- expr(MapSet.union(scope, second.binds), sub) do
          %{
            ast: call(@oracle, :reversed, [first.ast, second.ast], oracle: :lazy),
            binds: MapSet.union(first.binds, second.binds)
          }
        end
      end
    ])
  end

  defp name, do: oneof(@params ++ @pool)
  defp none, do: MapSet.new()
  defp var(name), do: {name, [], nil}
  defp pat(name), do: {name, [oracle: :pattern], nil}
  defp call(module, fun, args, meta \\ []), do: {{:., [], [module, fun]}, meta, args}

  # --- readings of a generated statement --------------------------------------------------

  @doc """
  Whether the model may read `statement`'s guaranteed bindings inexactly: it contains a
  macro whose expansion binds as statements what its route declares lazy (`twice/1`,
  `reversed/2`). A withheld classifier is the other inexact case, read from the model
  (`Mutare.Transform.Bindings.unknown_routing?/1`).
  """
  def inexact?(statement) do
    {_, lazy?} =
      Macro.prewalk(statement, false, fn
        {_, meta, _} = node, acc when is_list(meta) -> {node, acc or meta[:oracle] == :lazy}
        node, acc -> {node, acc}
      end)

    lazy?
  end

  @doc "Every read of `name` in `statement` renamed to `to`; its pattern occurrences kept."
  def rename_reads(statement, name, to) do
    Macro.prewalk(statement, fn
      {^name, meta, nil} = node -> if meta[:oracle] == :pattern, do: node, else: {to, meta, nil}
      node -> node
    end)
  end

  @doc """
  The statements as a function body, one per line group. A statement that is itself a block
  is parenthesized, so it stays one statement when the body is parsed again.
  """
  def render_body(statements) do
    Enum.map_join(statements, "\n", fn
      {:__block__, _, _} = block -> "(\n" <> Macro.to_string(block) <> "\n)"
      statement -> Macro.to_string(statement)
    end)
  end
end
