defmodule Mutare.PropertyProbe do
  @moduledoc """
  Shared probe / compile / spec scaffolding for the **runtime** property tests —
  `transform_baseline_property_test.exs` (the baseline metamutant ≡ the original) and
  `transform_activation_property_test.exs` (each mutant runs isolated). Both compile the
  generator's fixed `Prop` fixture and exercise its exported functions; this module owns the
  mechanics they share, so a single home derives the probe set and runs it the same way.

  A *probe* is a `{name, args}` pair: an exported `name/arity` paired with an argument row.
  `specs/1` builds them from the module's public exports crossed with an input pool (the
  literals appearing in the module — so literal-matching `case` / head clauses are reached —
  ahead of a fixed set of common terms). `probe/1` runs one, capturing a normal return *or* a
  raise / throw / exit, so two compiled modules (baseline test) or two selector states
  (activation test) compare on identical, total outcomes — the tags keep a returned value from
  ever colliding with a captured failure. Everything is reached via `apply/3` so naming the
  runtime-compiled fixture never trips a compile-time "undefined module" warning.
  """
  import ExUnit.CaptureIO, only: [with_io: 2]

  # The generator's fixed module name. Held as an atom so it is only ever reached via `apply/3`
  # (never a compile-time remote call to a module that does not exist when this module compiles).
  @module Prop

  # Common terms mixed in with the module's own literals, so atom / boolean / nil clauses (whose
  # literals the numeric/string extractor below does not collect) are still reachable.
  @fixed_inputs [0, 1, -1, 2, :ok, :error, :pending, :alpha, :beta, true, false, nil, "ab"]

  # How many distinct input rows to try per exported function.
  @rows_per_function 6

  @doc "The generator's fixed fixture module (`Prop`)."
  def module, do: @module

  @doc """
  Compile a `source` string, run `fun` against the loaded module, then purge every module it
  defined so the fixed `Prop` name never clashes across cases. Swallows the (legitimate)
  redefining / unused / unreachable warnings. Returns `{:ok, fun.()}` or `{:error, exception}`.
  """
  def with_compiled(source, fun) do
    {result, _io} =
      with_io(:stderr, fn ->
        try do
          modules = Code.compile_string(source)
          value = fun.()
          Enum.each(modules, fn {module, _binary} -> purge(module) end)
          {:ok, value}
        rescue
          e ->
            # A failed compile may leave a partial definition behind; clear it best-effort.
            purge(@module)
            {:error, e}
        end
      end)

    result
  end

  @doc """
  The probe specs for the **currently compiled** `Prop`: each public `name/arity` (default-arg
  arities included) crossed with a handful of argument rows from `input_pool/1`. Must be called
  *inside* `with_compiled/2` — it reflects on the loaded module's exports.
  """
  def specs(module_ast), do: build_specs(exported(@module), input_pool(module_ast))

  @doc """
  Run one `{name, args}` probe, capturing a normal return *or* a raise / throw / exit, so two
  states are compared on identical, total outcomes (the tags keep a returned value from ever
  colliding with a captured failure).

  The captured value is `normalize/1`-d first: starting on Erlang/OTP 28 a `~r/…/` literal
  compiles to a PCRE2 NIF **resource** — an `#Reference` carried in the `Regex` struct's
  `re_pattern` — which is *unique per compilation unit*, so two independently compiled but
  textually identical regexes are never `==` even though their `source`/`opts` match (on OTP 27-
  `re_pattern` is a plain, value-equal binary). The baseline property compares the original and
  the metamutant as two **separate** compiles, so an un-normalised regex return manufactures a
  spurious divergence there (the activation property, comparing one compile under two selectors,
  is immune). Reducing every regex to its stable `{source, opts}` identity makes the comparison
  OTP-version-independent. See NOTES "OTP 28 regex `re_pattern` is a per-compile reference".
  """
  def probe({name, args}) do
    {:value, normalize(apply(@module, name, args))}
  rescue
    error -> {:raised, error.__struct__}
  catch
    kind, value -> {:caught, kind, normalize(value)}
  end

  @doc """
  Reduce a probed value to a form whose equality is stable across separate compiles, by replacing
  every `Regex` with its `{source, opts}` identity (see `probe/1` for why). Deep-walked through
  lists / tuples / plain maps so a regex nested in a returned collection is normalised too; other
  structs (`Date`, `DateTime`, …) and scalars pass through untouched.
  """
  def normalize(%Regex{} = regex), do: {:"$regex", Regex.source(regex), Regex.opts(regex)}
  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)

  def normalize(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> normalize() |> List.to_tuple()

  def normalize(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {normalize(k), normalize(v)} end)

  def normalize(other), do: other

  # Public functions of the compiled fixture (`{name, arity}`), default-arg arities included.
  defp exported(module), do: apply(module, :__info__, [:functions])

  # For each exported `name/arity`, a handful of argument rows: each rotates a window across the
  # pool, so successive rows hit different slot combinations (and, with the module's own literals
  # up front, frequently land on a literal-matching clause). Deduped; arity 0 collapses to one.
  defp build_specs(exports, pool) do
    n = length(pool)

    for {name, arity} <- exports,
        i <- 0..(@rows_per_function - 1) do
      args = for j <- 0..(arity - 1)//1, do: Enum.at(pool, rem(i + j, n))
      {name, args}
    end
    |> Enum.uniq()
  end

  # Candidate input terms: the numeric/string literals actually present in the module (so
  # literal-matching clauses are reachable) ahead of a fixed pool of common terms, capped.
  defp input_pool(module_ast) do
    (literals(module_ast) ++ @fixed_inputs)
    |> Enum.uniq()
    |> Enum.take(14)
  end

  # Collect the integer/float/binary *value* literals from the generated AST. In this generator
  # those node shapes are only ever data (operands, head/clause patterns, guard bounds) — never
  # structure — so no filtering is needed; atoms (which double as identifiers/operators) are left
  # to the fixed pool.
  defp literals(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        if is_integer(node) or is_float(node) or is_binary(node),
          do: {node, [node | acc]},
          else: {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
  end
end
