defmodule Mutare.Transform.Names do
  @moduledoc false

  # Generated-name collision avoidance for one transform pass.
  #
  # Lifting introduces two kinds of generated identifier into a file: private
  # function names (`__mutare_<fun>_<arity>_g<n>`) and the dispatch variable the
  # gated clauses read (`mutare_active`). With the canonical `"__mutare_"` /
  # `mutare_active` a clash with hand-written code is near-impossible — but a single
  # clash is catastrophic (a duplicate `defp` sinks the *one* metamutant build; a
  # captured variable silently miscompiles a lifted clause — its gated head would
  # bind a user value instead of the active id). So this module picks names the
  # source provably never uses, from one scan of every identifier it mentions
  # (definitions *and* variables).
  #
  # `Mutare.Transform` pins these once (into `Ctx.prefix`/`Ctx.active_var`) before
  # any lifting assigns them; `Mutare.Manifest` recognises a lifted mutant clause by
  # its `<active_var> === <id>` gate, not the name, so the salt is invisible to it.

  alias Mutare.Coverage.Recorder

  # The canonical prefix for generated private (lifted) names. `generated_names/1`
  # derives a per-file, collision-free variant of it (see that function).
  @base_prefix "__mutare_"

  # def-like forms whose names a generated private `defp` could duplicate — part of
  # the identifier set `generated_names/1` scans the source for.
  @def_forms ~w(def defp defmacro defmacrop defguard defguardp defdelegate)a

  @doc """
  The collision-free `{prefix, active_var}` this source provably never uses.

  `prefix` is the private-function prefix; `active_var` the dispatch variable. Both
  are derived from one scan of every identifier the source mentions, so a generated
  name can never equal one already in scope.
  """
  @spec generated_names(Macro.t()) :: {String.t(), atom()}
  def generated_names(ast) do
    taken = taken_names(ast)
    prefix = Enum.find(prefix_candidates(), &free?(&1, taken))
    {prefix, active_var(taken)}
  end

  # The dispatch variable: the readable `mutare_active` unless the source already
  # uses that identifier, then `mutare_active_0`, `mutare_active_1`, … until free.
  # A numeric suffix (not the `__mutare_` prefix) keeps it a normal, non-underscore
  # name — a leading-underscore variable that's then *read* warns ("used after being
  # set"). The candidate family is infinite and `taken` finite, so this terminates.
  defp active_var(taken) do
    canonical = Recorder.var_name()

    if MapSet.member?(taken, Atom.to_string(canonical)) do
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&:"#{canonical}_#{&1}")
      |> Enum.find(&(not MapSet.member?(taken, Atom.to_string(&1))))
    else
      canonical
    end
  end

  # `"__mutare_"`, then `"__mutare_0_"`, `"__mutare_1_"`, … — a lazily-grown
  # family, all sharing the `"__mutare_"` stem. Only finitely many can be "taken"
  # (one per colliding source name), so `Enum.find/2` always terminates.
  defp prefix_candidates do
    Stream.concat(
      [@base_prefix],
      Stream.map(Stream.iterate(0, &(&1 + 1)), &"#{@base_prefix}#{&1}_")
    )
  end

  # A prefix is free when no identifier the source mentions begins with it: then no
  # `<prefix>…` name we generate (a private function, or `<prefix>active`) can equal
  # one already in scope.
  defp free?(prefix, taken), do: not Enum.any?(taken, &String.starts_with?(&1, prefix))

  # Every identifier the source mentions: names defined by a def-like form
  # (functions, macros, guards, delegates) a generated `defp` could duplicate, *and*
  # every variable/bare-name node the dispatch variable could capture or be captured
  # by. Over-collecting (e.g. a name inside a quoted macro body) is safe — it can
  # only make us salt a name we'd otherwise have kept.
  defp taken_names(ast) do
    {_ast, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {form, _meta, [head | _]} = node, acc when form in @def_forms ->
          case def_name(head) do
            nil -> {node, acc}
            name -> {node, MapSet.put(acc, Atom.to_string(name))}
          end

        # A variable (or bare zero-arg name): `context` is its hygiene context
        # (`nil`/a module), never the arg list a call carries.
        {name, _meta, context} = node, acc when is_atom(name) and is_atom(context) ->
          {node, MapSet.put(acc, Atom.to_string(name))}

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp def_name({:when, _meta, [call | _guards]}), do: def_name(call)
  defp def_name({name, _meta, _args}) when is_atom(name), do: name
  defp def_name(_), do: nil
end
