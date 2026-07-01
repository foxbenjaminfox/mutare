defmodule Mutare.Transform.ImportWitness do
  @moduledoc false

  # The **import witness**: a dead-code block `Mutare.Transform` splices alongside a mutated
  # bare imported call so the *single* metamutant compile proves the call still resolves to the
  # provider we believe it does.
  #
  # A stamped bare imported call can be silently wrong when a macro hidden from our lexical
  # pre-pass re-imports the same module with `except:` and replaces the function from another
  # module. The witness re-imports the provider the original call used, then references the same
  # bare name/arity inside an unreachable expression. If a hidden replacement is also in scope,
  # Elixir raises "imported from both ... ambiguous" during compile, and poison recovery drops
  # the generated mutant instead of letting it run against the wrong provider.
  #
  # `for_candidate/1` reads the import stamp (`Mutare.Transform.Imports.import_witness/1`) off a
  # candidate's original node and, for in-place rewrites, its mutated branch. A bare imported rename
  # needs both: the original witness proves the source name was not secretly replaced, while the
  # mutated-branch witness proves the emitted bare sibling still names the same provider. `wrap/2`
  # prefixes the witness block(s) to a single expression (the in-place path); `prepend/2` splices
  # them into a clause body's `:do` (the lifted path). Both are no-ops when no witness exists —
  # the common case (a call that isn't a bare import).

  alias Mutare.AST
  alias Mutare.Transform.{Aliases, Imports}

  @type witness :: {Aliases.module_key(), atom(), arity()}
  @type witness_set :: witness() | [witness()] | nil

  @doc "The witness(es) for a candidate's bare imported node(s), or `nil`."
  @spec for_candidate(map()) :: witness_set()
  def for_candidate(%{original: original, mutated: mutated}) do
    [original, mutated]
    |> Enum.flat_map(&from_node/1)
    |> Enum.uniq()
    |> normalize()
  end

  def for_candidate(%{original: original}), do: original |> from_node() |> normalize()
  def for_candidate(_candidate), do: nil

  defp from_node({:&, amp_meta, [{:/, _slash_meta, [ref, _arity]}]}) when is_list(amp_meta) do
    [Imports.import_witness(amp_meta) | from_node(ref)]
    |> Enum.reject(&is_nil/1)
  end

  defp from_node({_form, meta, _args}) when is_list(meta) do
    case Imports.import_witness(meta) do
      nil -> []
      witness -> [witness]
    end
  end

  defp from_node(_node), do: []

  defp normalize([]), do: nil
  defp normalize([witness]), do: witness
  defp normalize(witnesses), do: witnesses

  @doc "Prefix `witness` (as a dead-code block) to a single expression; a no-op for `nil`."
  @spec wrap(Macro.t(), witness_set()) :: Macro.t()
  def wrap(node, nil), do: node
  def wrap(node, []), do: node

  def wrap(node, witnesses) when is_list(witnesses),
    do: {:__block__, [], Enum.map(witnesses, &ast/1) ++ [node]}

  def wrap(node, witness), do: {:__block__, [], [ast(witness), node]}

  @doc """
  Splice `witness` into a clause body's `:do` block (the lifted path's `[body_kw]` shape); a
  no-op for a `nil` witness or a body that isn't a single keyword list.
  """
  @spec prepend(Macro.t(), witness_set()) :: Macro.t()
  def prepend(body, nil), do: body
  def prepend(body, []), do: body

  def prepend([kw], witness) when is_list(kw),
    do: [AST.update_do_block(kw, &wrap(&1, witness))]

  def prepend(body, _witness), do: body

  # The witness AST: `case false do true -> (import <Mod>, only: [fun: arity]; fn args -> fun(args) end); _ -> nil end`.
  # The `import` + bare reference live in the unreachable `true ->` arm, so they never run but
  # are compiled — which is what triggers the ambiguity error when a hidden replacement clashes.
  defp ast({module, fun, arity}) do
    args = args(arity)
    call = {fun, [], args}
    closure = {:fn, [], [{:->, [], [args, call]}]}
    import_directive = {:import, [], [module_node(module), [only: [{fun, arity}]]]}
    true_body = {:__block__, [], [import_directive, closure]}

    {:case, [],
     [
       {:__block__, [], [false]},
       [
         do: [
           {:->, [], [[{:__block__, [], [true]}], true_body]},
           {:->, [], [[{:_, [], nil}], {:__block__, [], [nil]}]}
         ]
       ]
     ]}
  end

  defp args(0), do: []
  defp args(arity), do: Enum.map(1..arity, &{:"mutare_import_arg#{&1}", [], nil})

  defp module_node(module) when is_list(module), do: {:__aliases__, [], [:"Elixir" | module]}
  defp module_node(module) when is_atom(module), do: {:__block__, [], [module]}
end
