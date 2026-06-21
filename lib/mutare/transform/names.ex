defmodule Mutare.Transform.Names do
  @moduledoc false

  # Generated-name collision avoidance for one transform pass.
  #
  # Lifting introduces three kinds of generated identifier into a file: private
  # function names (`__mutare_<fun>_<arity>_g<n>`), the dispatch variable the gated
  # clauses read (`mutare_active`), and the super-forwarding closure variable a
  # dispatcher binds when a lifted body calls `super` (`mutare_super`; see
  # `Mutare.Transform.Super`). With the canonical `"__mutare_"` / `mutare_active` /
  # `mutare_super` a clash with hand-written code is near-impossible — but a single
  # clash is catastrophic (a duplicate `defp` sinks the *one* metamutant build; a
  # captured variable silently miscompiles a lifted clause — its gated head would
  # bind a user value instead of the active id, or a `super` call would forward a
  # user's value instead of the closure). So this module picks names the source
  # provably never uses, from one scan of every identifier it mentions (definitions
  # *and* variables).
  #
  # `Mutare.Transform` pins these once (into `Ctx.prefix`/`Ctx.active_var`/
  # `Ctx.super_var`) before any lifting assigns them; `Mutare.Manifest` recognises a
  # lifted mutant clause by its `<active_var> === <id>` gate, not the name, so the
  # salt is invisible to it.

  alias Mutare.Coverage.Recorder

  # The canonical prefix for generated private (lifted) names. `generated_names/1`
  # derives a per-file, collision-free variant of it (see that function).
  @base_prefix "__mutare_"

  # The canonical super-forwarding closure variable (see `Mutare.Transform.Super`).
  # Like the dispatch variable it is read, so it is *not* underscore-prefixed (a
  # leading-underscore variable that is then read warns); `salted/2` derives a
  # collision-free variant when the source already uses the name.
  @super_var :mutare_super

  # The canonical piped-value closure variable. When a mutated *pipe stage* is
  # hoisted out of its illegal `x |> case … end` position, the piped value is bound
  # to a one-shot closure's parameter and the branches reference *it* rather than
  # copying the whole upstream chain (see `Mutare.Transform.hoist_pipe/2`). It is
  # read inside the branches, so — like the dispatch/super variables — it is salted
  # rather than underscore-prefixed, and must not collide with a source variable the
  # stage's arguments mention (else the closure param would capture it).
  @piped_var :mutare_piped

  # The canonical *condition-hoist* temp variable. When an `if`/`unless` condition
  # binds a variable through a **refutable** pattern (`if {:ok, v} = fetch() do`), the
  # binding is hoisted out so the (now binding-free) condition can host a selector
  # without trapping it (see `Mutare.Transform.Analyze`'s condition hoisting): the
  # match value is bound to this temp, the pattern re-matched against it, and the
  # condition reads the temp. It is read (in the condition), so — like the others — it
  # is salted, not underscore-prefixed.
  @cond_var :mutare_cond

  # The placeholder a refutable hoist carries until emit knows the salted `cond_var`.
  # `Mutare.Transform.Analyze` builds the hoist (in the id-free analyze pass, which has
  # no access to the per-file salted names), spelling the temp as this var-shaped node;
  # `substitute_hoist_placeholder/2` rewrites it to the real `cond_var` at emit. The
  # unusual *context* (`:__mutare_hoist_placeholder__` — never a source variable's
  # hygiene context, which is `nil` or a module) makes it impossible to collide with a
  # real variable, so the substitution can't capture user code.
  @hoist_name :__mutare_hoist__
  @hoist_context :__mutare_hoist_placeholder__

  # def-like forms whose names a generated private `defp` could duplicate — part of
  # the identifier set `generated_names/1` scans the source for.
  @def_forms ~w(def defp defmacro defmacrop defguard defguardp defdelegate)a

  @doc """
  The collision-free `{prefix, active_var, super_var, piped_var, cond_var}` this
  source provably never uses.

  `prefix` is the private-function prefix; `active_var` the dispatch variable;
  `super_var` the super-forwarding closure variable; `piped_var` the hoisted
  pipe-stage closure variable; `cond_var` the condition-hoist temp. All are derived
  from one scan of every identifier the source mentions, so a generated name can
  never equal one already in scope.
  """
  @spec generated_names(Macro.t()) :: {String.t(), atom(), atom(), atom(), atom()}
  def generated_names(ast) do
    taken = taken_names(ast)
    prefix = Enum.find(prefix_candidates(), &free?(&1, taken))

    {prefix, salted(Recorder.var_name(), taken), salted(@super_var, taken),
     salted(@piped_var, taken), salted(@cond_var, taken)}
  end

  @doc """
  The var-shaped placeholder `Mutare.Transform.Analyze` uses for a refutable
  condition-hoist temp until emit substitutes the salted `cond_var`. See the
  `@hoist_name`/`@hoist_context` note above.
  """
  @spec hoist_placeholder() :: Macro.t()
  def hoist_placeholder, do: {@hoist_name, [], @hoist_context}

  @doc """
  Rewrite every hoist placeholder in `node` to the (salted, collision-free)
  `cond_var`, preserving each placeholder's metadata (a refutable hoist's *root*
  carries the decision candidates there). Run once at the top of emit; a no-op when
  no `if`/`unless` condition was hoisted with a refutable pattern.
  """
  @spec substitute_hoist_placeholder(Macro.t(), atom()) :: Macro.t()
  def substitute_hoist_placeholder(node, cond_var) do
    Macro.prewalk(node, fn
      {@hoist_name, meta, @hoist_context} -> {cond_var, meta, nil}
      other -> other
    end)
  end

  # A generated *variable* name the source provably never uses: the readable
  # `canonical` unless the source already mentions it, then `canonical_0`,
  # `canonical_1`, … until free. A numeric suffix (not the `__mutare_` prefix) keeps
  # it a normal, non-underscore name — a leading-underscore variable that's then
  # *read* warns ("used after being set"). The candidate family is infinite and
  # `taken` finite, so this terminates. Used for the dispatch variable
  # (`mutare_active`), the super-forwarding closure (`mutare_super`), and the
  # hoisted pipe-stage closure (`mutare_piped`).
  defp salted(canonical, taken) do
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
