defmodule Mutare.Mutators.KeywordDelete do
  @moduledoc """
  Swap a `Keyword` duplicate-key **deletion breadth** for its complement:

    * `Keyword.delete` ↔ `Keyword.delete_first`

  A keyword list can carry the **same key more than once** — it is an ordered list of
  `{key, value}` pairs, not a `Map`. `Keyword.delete(kw, key)` removes **every** entry for
  `key`; `Keyword.delete_first(kw, key)` removes only the **first**. Swapping them asks:
  does any test actually depend on *which* — would a list with a repeated key behave the
  same either way? A survivor means the suite never exercises a duplicate key at this call,
  the classic untested edge of accumulated/merged options.

  `Map` has no twin: a `Map` key is unique, so there is no "delete first vs all" distinction
  (and no `Map.delete_first`). This is the Keyword-only sibling of
  `Mutare.Mutators.MapKeyword` (the conditional-*write* lattice) — here the axis is deletion
  *breadth*, not insert/overwrite.

  **Arity-gated to `/2`, and pipe-aware.** `Keyword.delete` also has a deprecated `/3`
  (key+value) form, but `Keyword.delete_first` has no `/3` — so a `delete/3` is left alone
  rather than renamed to a nonexistent `delete_first/3` (which would poison the build). The
  gate is on **effective** arity, so a piped `kw |> Keyword.delete(k)` swaps too.

  On by default. Matches aliased and bare-imported calls, while a shadowing
  `alias MyApp.Keyword` is left alone. `Mutare.Mutators.CallRemoval` separately *removes*
  `Keyword.delete` outright (→ the original list) — a distinct mutant on the same call;
  here the call is kept and its breadth flipped.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

  # {alias_path, function, effective_arity} => complementary function. Keyed on arity so the
  # swap only fires at /2 (`delete_first` has no /3 twin); `Helpers.lookup_resolved_arity`
  # is pipe-aware, and `rebuild` keeps the written module (the swap stays within `Keyword`).
  @rules %{
    {[:Keyword], :delete, 2} => :delete_first,
    {[:Keyword], :delete_first, 2} => :delete
  }

  @impl Mutare.Mutator
  def name, do: :keyword_delete

  @impl Mutare.Mutator
  def mutate(node, %{pipe_mode: pipe_mode}) do
    with {:ok, new_fun, {_module, _fun, args, rebuild}} <-
           Helpers.lookup_resolved_arity(node, pipe_mode, @rules) do
      # Pure rename — keep the arguments, keep the written module.
      [rebuild.(new_fun, args)]
    end
  end
end
