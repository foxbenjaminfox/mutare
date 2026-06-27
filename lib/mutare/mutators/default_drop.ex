defmodule Mutare.Mutators.DefaultDrop do
  @moduledoc """
  Drop a trailing **optional argument**, reverting the call to its implicit default —
  the "is this refinement actually tested?" probe. A survivor means no test asserts
  that the dropped argument changes the result. One mechanic (pop the trailing
  argument, keep the rest), two veins:

  ## Not-found defaults — implicit `nil`

  Lookups whose trailing argument is the value returned when the key/index is absent.
  A survivor means the *not-found* path — where your chosen default actually matters —
  is uncovered.

    * `Map.get/3` → `Map.get/2`            `Keyword.get/3` → `Keyword.get/2`
    * `Map.pop/3` → `Map.pop/2`            `Keyword.pop/3` → `Keyword.pop/2`
    * `Enum.at/3` → `Enum.at/2`
    * `List.first/2` → `List.first/1`      `List.last/2` → `List.last/1`
    * `Map.get_lazy/3` → `Map.get/2`       `Keyword.get_lazy/3` → `Keyword.get/2`
    * `Map.pop_lazy/3` → `Map.pop/2`       `Keyword.pop_lazy/3` → `Keyword.pop/2`

  The `_lazy` forms drop their fallback function and rename to the base lookup.

  ## Refinement defaults — a precision, base, separator, or fill

  A trailing option that *refines* an otherwise-complete call; dropping it reverts to
  the standard behaviour, asking whether the refinement is pinned by a test:

    * `Float.round/2`, `Float.ceil/2`, `Float.floor/2` → `/1` — drop the **precision**
      (implicit `0`): "does the decimal precision matter?"
    * `Integer.to_string/2`, `Integer.to_charlist/2`, `Integer.parse/2`,
      `Integer.digits/2`, `Integer.undigits/2` → `/1` — drop the **base** (implicit `10`):
      "does the base matter?"
    * `Enum.join/2` → `Enum.join/1` — drop the **separator** (implicit `""`)
    * `String.pad_leading/3`, `String.pad_trailing/3` → `/2` — drop the **fill**
      (implicit `" "`)
    * `String.trim/2`, `String.trim_leading/2`, `String.trim_trailing/2` → `/1` — drop
      the **to-trim string**, reverting to whitespace trimming

  ## The equivalence guard

  Dropping a trailing argument that *already equals the implicit default* is an
  equivalent no-op, so a trailing **literal** equal to the implicit default is skipped:
  `nil` for the lookups, `0` for the rounding precision, `10` for the integer base, `""`
  for `Enum.join`, `" "` for the pads — `Map.get(m, k, nil)`, `Float.round(x, 0)`,
  `Integer.to_string(n, 10)`, `Enum.join(xs, "")`, `String.pad_leading(s, n, " ")` are
  all left alone. A non-default trailing arg (`:none`, `false`, `2`, `", "`, `"*"`, a
  variable, an expression) *is* the observable difference, so it is dropped.

  Two cases have **no** equivalent literal, so they always drop: a `_lazy` fallback (a
  function value, never a literal) and `String.trim`'s to-trim string (whitespace
  trimming has no value form — `String.trim(s, " ")` trims *only* spaces, not all
  whitespace, so it is genuinely not equivalent to `String.trim(s)`).

  The comparison reads a string literal's *decoded* value, so an escaped spelling of a
  default (`Enum.join(xs, "\\s")` for a space) is not recognised as equivalent and
  yields a phantom mutant — a harmless over-emission (a false *survivor*, never a
  silently dropped mutant).

  ## Scope

  On by default. Matches aliased and bare-imported calls too. Two siblings overlap
  *deliberately*, each producing a distinct mutant on the same call:
  `Mutare.Mutators.CallRemoval` removes `String.trim`/`pad_leading`/`pad_trailing`
  outright (→ the raw input), where this drops only the refining argument (→ the default
  behaviour); and `Mutare.Mutators.Numeric` renames `Float.ceil ↔ Float.floor` (keeping
  the precision), orthogonal to this precision drop.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutators.Helpers

  # {alias_path, function, effective_arity} => {base_function, equivalent_defaults}.
  # The operation is uniform: drop the trailing (optional) argument and rename to the
  # base function. `equivalent_defaults` lists the literal value(s) the argument may hold
  # that are equivalent to the implicit default — dropping one of those is a no-op, so it
  # is skipped. An empty list means the argument has no literal default form (a `_lazy`
  # fallback fun, `String.trim`'s to-trim string), so it always drops.
  @rules %{
    # Not-found defaults — implicit nil.
    {[:Map], :get, 3} => {:get, [nil]},
    {[:Keyword], :get, 3} => {:get, [nil]},
    {[:Map], :pop, 3} => {:pop, [nil]},
    {[:Keyword], :pop, 3} => {:pop, [nil]},
    {[:Enum], :at, 3} => {:at, [nil]},
    {[:List], :first, 2} => {:first, [nil]},
    {[:List], :last, 2} => {:last, [nil]},
    {[:Map], :get_lazy, 3} => {:get, []},
    {[:Keyword], :get_lazy, 3} => {:get, []},
    {[:Map], :pop_lazy, 3} => {:pop, []},
    {[:Keyword], :pop_lazy, 3} => {:pop, []},
    # Rounding precision — implicit 0.
    {[:Float], :round, 2} => {:round, [0]},
    {[:Float], :ceil, 2} => {:ceil, [0]},
    {[:Float], :floor, 2} => {:floor, [0]},
    # Integer base — implicit 10.
    {[:Integer], :to_string, 2} => {:to_string, [10]},
    {[:Integer], :to_charlist, 2} => {:to_charlist, [10]},
    {[:Integer], :parse, 2} => {:parse, [10]},
    {[:Integer], :digits, 2} => {:digits, [10]},
    {[:Integer], :undigits, 2} => {:undigits, [10]},
    # Join separator — implicit "".
    {[:Enum], :join, 2} => {:join, [""]},
    # String pad fill — implicit " ".
    {[:String], :pad_leading, 3} => {:pad_leading, [" "]},
    {[:String], :pad_trailing, 3} => {:pad_trailing, [" "]},
    # String trim char — whitespace, no literal default form (always drops).
    {[:String], :trim, 2} => {:trim, []},
    {[:String], :trim_leading, 2} => {:trim_leading, []},
    {[:String], :trim_trailing, 2} => {:trim_trailing, []}
  }

  @impl Mutare.Mutator
  def name, do: :default_drop

  @impl Mutare.Mutator
  def mutate(node, %{pipe_mode: pipe_mode}) do
    with {:ok, {new_fun, equivalent_defaults}, {_module, _fun, args, rebuild}} <-
           Helpers.lookup_resolved_arity(node, pipe_mode, @rules),
         {dropped, kept} = List.pop_at(args, -1),
         # Skipped when the explicit trailing arg already equals the implicit default.
         false <- equivalent_default?(dropped, equivalent_defaults) do
      # `rebuild` reuses the written alias node, keeping the call within its module.
      [rebuild.(new_fun, kept)]
    else
      _ -> :skip
    end
  end

  # Whether the dropped node is a literal equal to one of the rule's equivalent defaults
  # (so dropping it is a no-op). A non-literal argument (a variable, expression, or a
  # `_lazy` fallback fun) is never an equivalent default.
  defp equivalent_default?(node, equivalent_defaults) do
    case AST.literal_value(node) do
      {:ok, value} -> value in equivalent_defaults
      :error -> false
    end
  end
end
