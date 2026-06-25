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
  # candidate's original node, yielding a `{module, fun, arity}` to witness (or `nil`). `wrap/2`
  # prefixes the witness to a single expression (the in-place path); `prepend/2` splices it into
  # a clause body's `:do` (the lifted path). Both are no-ops for a `nil` witness — the common
  # case (a call that isn't a bare import).

  alias Mutare.AST
  alias Mutare.Transform.Imports

  @doc "The `{module, fun, arity}` to witness for a candidate's original node, or `nil`."
  @spec for_candidate(map()) :: {[atom()] | atom(), atom(), arity()} | nil
  def for_candidate(%{original: original}), do: from_node(original)
  def for_candidate(_candidate), do: nil

  defp from_node({_form, meta, _args}) when is_list(meta), do: Imports.import_witness(meta)
  defp from_node(_node), do: nil

  @doc "Prefix `witness` (as a dead-code block) to a single expression; a no-op for `nil`."
  @spec wrap(Macro.t(), {[atom()] | atom(), atom(), arity()} | nil) :: Macro.t()
  def wrap(node, nil), do: node
  def wrap(node, witness), do: {:__block__, [], [ast(witness), node]}

  @doc """
  Splice `witness` into a clause body's `:do` block (the lifted path's `[body_kw]` shape); a
  no-op for a `nil` witness or a body that isn't a single keyword list.
  """
  @spec prepend(Macro.t(), {[atom()] | atom(), atom(), arity()} | nil) :: Macro.t()
  def prepend(body, nil), do: body

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
