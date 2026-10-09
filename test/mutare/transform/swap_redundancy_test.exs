defmodule Mutare.Transform.SwapRedundancyTest do
  @moduledoc """
  Evaluation pins for `Mutare.Transform.Suppression.redundant_swap/1`: whenever it claims an
  operand swap redundant somewhere in an expression, evaluating the expression with the swap
  must match evaluating it unmutated (`:unobservable`), or with the sibling mutant the claim
  locates — on every operand pair. The space is small and finite, so it is enumerated rather
  than sampled.

  The operand values are the ones the reader's exclusions answer to: sub-unit gaps (which
  `DateTime.diff`/`Time.diff` round), signed zeros (which `abs/1` keeps and OTP 27's `===`
  tells apart), and values that make the call raise. Values are compared by their external
  term encoding, so a zero's sign counts on every OTP. A raise matches a raise of the same
  exception type; its message may name the operands in the other order, which the reader
  accepts (NOTES "Operand swaps the enclosing expression cannot observe").
  """
  # Pure: parses and evaluates closures in-process.
  use ExUnit.Case, async: true

  alias Mutare.AST
  alias Mutare.Mutator.Dispatch
  alias Mutare.Mutators.{ConventionAtom, Relational}
  alias Mutare.Transform.Suppression

  @three_way %{
    "DateTime.compare" => [
      ~U[2020-01-01 00:00:00Z],
      ~U[2020-01-01 00:00:00.5Z],
      ~U[2020-01-02 00:00:00Z],
      nil
    ],
    "Date.compare" => [~D[2020-01-01], ~D[2020-01-02], ~D[2019-12-31], nil],
    "Time.compare" => [~T[00:00:00], ~T[00:00:00.5], ~T[12:00:00], nil],
    "NaiveDateTime.compare" => [~N[2020-01-01 00:00:00], ~N[2020-01-01 00:00:00.5], nil],
    "Version.compare" => ["1.0.0", "1.0.0+build", "1.0.1", "bad", "worse"]
  }

  @negating %{
    "Date.diff(a, b)" => [~D[2020-01-01], ~D[2020-01-02], ~D[2019-12-31], nil],
    "a - b" => [0, 1, -1, 2, 0.0, -0.0, 0.5, -0.5, :x]
  }

  @equality ~w(== != === !==)
  @ordering ~w(< > <= >=)

  defp three_way_readings do
    atoms = [:lt, :eq, :gt, :foo]

    lists =
      for(l <- [[], [:lt], [:eq], [:gt], [:lt, :eq], [:lt, :gt], [:eq, :gt]], do: l) ++
        [[:lt, :eq, :gt], [:lt, :lt], [:gt, :eq, :gt]]

    for(op <- @equality, a <- atoms, do: ["X #{op} #{inspect(a)}", "#{inspect(a)} #{op} X"])
    |> List.flatten()
    |> Kernel.++(for l <- lists, do: "X in #{inspect(l)}")
    |> Kernel.++(for l <- lists, do: "X not in #{inspect(l)}")
    |> Kernel.++(for a <- atoms, do: "match?(#{inspect(a)}, X)")
    |> Kernel.++(["not (X == :lt)", "!(X != :eq)"])
  end

  defp negating_readings do
    for(op <- @equality ++ @ordering, z <- ~w(0 0.0 1), do: ["X #{op} #{z}", "#{z} #{op} X"])
    |> List.flatten()
    |> Kernel.++(["abs(X)", "abs(X) < 1", "1 >= abs(X)", "abs(X) == 0", "abs(X) === 0.0"])
    |> Kernel.++(["not (X == 0)"])
  end

  defp cases do
    three_way =
      for {call, values} <- @three_way,
          reading <- three_way_readings(),
          do: {String.replace(reading, "X", "#{call}(a, b)"), values}

    negating =
      for {child, values} <- @negating,
          reading <- negating_readings(),
          do: {String.replace(reading, "X", "(#{child})"), values}

    three_way ++ negating
  end

  test "every claimed redundant swap evaluates like the original or its named sibling" do
    claims =
      for {source, values} <- cases(),
          root = AST.parse!(source),
          {path, node} <- nodes(root),
          {swap_path, survivor} <- List.wrap(Suppression.redundant_swap(node)) do
        swapped = put_at(root, path ++ swap_path, swap(Suppression.at(node, swap_path)))

        twins =
          case survivor do
            :unobservable ->
              [root]

            {survivor_path, mutated?} ->
              at = path ++ survivor_path

              twins =
                for %Dispatch.Result{node: mutated} <-
                      Dispatch.mutations(Suppression.at(root, at), [ConventionAtom, Relational]),
                    mutated?.(mutated),
                    do: put_at(root, at, mutated)

              assert twins != [], "#{source}: no sibling mutant where the claim locates one"
              twins
          end

        for twin <- twins do
          assert outcomes(swapped, values) === outcomes(twin, values),
                 "#{source}: swapped #{AST.to_string(swapped)} differs from #{AST.to_string(twin)}"
        end

        {source, survivor_kind(survivor)}
      end

    # Not vacuous: each kind of claim is made, under each antisymmetric operation.
    kinds = claims |> Enum.map(&elem(&1, 1)) |> Enum.frequencies()
    assert kinds[:unobservable] > 0 and kinds[:sibling] > 0

    for call <- Map.keys(@three_way) ++ ["Date.diff", " - "] do
      assert Enum.any?(claims, fn {source, _} -> String.contains?(source, call) end),
             "no claim made under #{call}"
    end
  end

  test "the readings left out are observable" do
    # `DateTime.diff` rounds down: half a second apart reads 0 one way and -1 the other.
    a = ~U[2020-01-01 00:00:00.5Z]
    b = ~U[2020-01-01 00:00:00Z]
    assert DateTime.diff(a, b) == 0 != (DateTime.diff(b, a) == 0)

    # A float difference can be a zero of either sign, and `abs/1` keeps it; OTP 27's `===`
    # sees it too (OTP 26's does not, but the target may run 27).
    {x, y} = {-0.0, 0.0}
    assert inspect(abs(x - y)) != inspect(abs(y - x))

    if String.to_integer(System.otp_release()) >= 27,
      do: assert(x - y === 0.0 != (y - x === 0.0))

    for source <- [
          "DateTime.diff(a, b) == 0",
          "Time.diff(a, b) == 0",
          "NaiveDateTime.diff(a, b) == 0",
          "a - b === 0.0",
          "abs(a - b)",
          "abs(a - b) === 0.0"
        ] do
      root = AST.parse!(source)

      assert Enum.all?(nodes(root), fn {_path, node} ->
               Suppression.redundant_swap(node) == nil
             end)
    end
  end

  defp survivor_kind(:unobservable), do: :unobservable
  defp survivor_kind({_path, _mutated?}), do: :sibling

  # Every node with its path from `root`, in `Suppression.at/2`'s indexing.
  defp nodes(root), do: nodes(root, [])

  defp nodes({_form, _meta, args} = node, path) when is_list(args),
    do: [{path, node} | children(args, path)]

  defp nodes(list, path) when is_list(list), do: children(list, path)
  defp nodes(_leaf, _path), do: []

  defp children(list, path),
    do: list |> Enum.with_index() |> Enum.flat_map(fn {c, i} -> nodes(c, path ++ [i]) end)

  defp put_at(_node, [], new), do: new

  defp put_at({form, meta, args}, [i | rest], new) when is_list(args),
    do: {form, meta, List.update_at(args, i, &put_at(&1, rest, new))}

  defp put_at(list, [i | rest], new) when is_list(list),
    do: List.update_at(list, i, &put_at(&1, rest, new))

  defp swap({form, meta, [a, b | rest]}), do: {form, meta, [b, a | rest]}

  # The expression's outcome on every operand pair: its value, or the exception type it raised.
  defp outcomes(ast, values) do
    {fun, _binding} = Code.eval_string("fn a, b -> #{AST.to_string(ast)} end")

    for a <- values, b <- values do
      try do
        {:ok, :erlang.term_to_binary(fun.(a, b))}
      rescue
        e -> {:raise, e.__struct__}
      end
    end
  end
end
