defmodule Mutare.Mutators.StringCall do
  @moduledoc """
  Renames string calls to a complementary operation:

    * `String.starts_with?` ↔ `String.ends_with?`
    * `String.upcase` ↔ `String.downcase`
    * `String.trim_leading` ↔ `String.trim_trailing`
    * `String.replace_prefix` ↔ `String.replace_suffix`
    * `String.replace_leading` ↔ `String.replace_trailing`
    * `String.pad_leading` ↔ `String.pad_trailing`
    * `String.first` ↔ `String.last`
    * `String.graphemes` ↔ `String.codepoints`
    * `:string.uppercase` ↔ `:string.lowercase`
    * `:string.to_upper` ↔ `:string.to_lower`
    * `:string.left` ↔ `:string.right`
    * `:binary.first` ↔ `:binary.last`

  The Erlang `:string` trim direction is an argument rather than a function name,
  so it is not included.

  `String.equivalent?(a, b)` also produces `Kernel.==(a, b)`, removing Unicode
  normalization from the comparison.

  Direct, aliased, and imported calls are supported for Elixir and Erlang modules.
  An alias that resolves to another module does not match. This family is enabled
  by default and is separate from `Mutare.Mutators.StringLiteral`, which changes
  string values rather than calls.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Mutators.Helpers
  alias Mutare.Transform.Calls

  # {module, function} => new_function. The module is an Elixir path (`[:String]`) or an
  # Erlang atom (`:string`); the swap keeps the module, so only the new function name is
  # stored. The shared `Calls.resolved_call` returns whichever module shape applies, so a
  # direct, aliased, or imported call all key in here uniformly.
  @swaps %{
    {[:String], :starts_with?} => :ends_with?,
    {[:String], :ends_with?} => :starts_with?,
    {[:String], :upcase} => :downcase,
    {[:String], :downcase} => :upcase,
    {[:String], :trim_leading} => :trim_trailing,
    {[:String], :trim_trailing} => :trim_leading,
    {[:String], :replace_prefix} => :replace_suffix,
    {[:String], :replace_suffix} => :replace_prefix,
    # `replace_leading`/`replace_trailing` replace *every* leading/trailing run of
    # a match, a distinct pair from the single-occurrence `replace_prefix`/`suffix`.
    {[:String], :replace_leading} => :replace_trailing,
    {[:String], :replace_trailing} => :replace_leading,
    {[:String], :pad_leading} => :pad_trailing,
    {[:String], :pad_trailing} => :pad_leading,
    {[:String], :first} => :last,
    {[:String], :last} => :first,
    # The two ways to break a string into a list of single-character strings:
    # `graphemes` groups combining marks into one glyph, `codepoints` does not.
    {[:String], :graphemes} => :codepoints,
    {[:String], :codepoints} => :graphemes,
    # The Erlang `:string` module's directional/case pairs.
    {:string, :uppercase} => :lowercase,
    {:string, :lowercase} => :uppercase,
    {:string, :to_upper} => :to_lower,
    {:string, :to_lower} => :to_upper,
    {:string, :left} => :right,
    {:string, :right} => :left,
    # The Erlang `:binary` module's first/last byte pair — the byte-level twin of
    # `String.first`/`String.last` (both `:binary` functions return a byte).
    {:binary, :first} => :last,
    {:binary, :last} => :first
  }

  @impl Mutare.Mutator
  def name, do: :string_call

  @impl Mutare.Mutator
  def mutate(node) do
    case Calls.resolved_call(node) do
      # `String.equivalent?(a, b)` → raw `a == b`, resolved like the swaps.
      {[:String], :equivalent?, args, _rebuild} ->
        equivalent_substitution(args)

      # Every other call → the shared `{module, fun}` swap-table path over the already-
      # resolved call (no second resolution), so an aliased `S.upcase`/imported `upcase`
      # keeps its written module node (`Helpers.swap_resolved/2`).
      resolved ->
        Helpers.swap_resolved(resolved, @swaps)
    end
  end

  # `String.equivalent?(a, b)` compares strings for Unicode canonical equivalence;
  # substituting raw `==` drops the normalization, so the mutant survives unless a
  # test feeds canonically-equivalent-but-distinct encodings. The swap is emitted as
  # `Elixir.Kernel.==(...)`, not a bare `a == b`: a bare `==` would resolve to a
  # same-named local/imported operator if one shadows it (`import Kernel, except: [==: 2]`
  # plus a `def a == b`), silently changing the mutant. The **absolute** `Elixir.Kernel`
  # qualifier (`__aliases__` led by `:Elixir`, which alias resolution never rewrites) pins
  # the real operator independently of the target's imports *and* aliases — the same
  # alias-proof form `Mutare.Transform` uses for its generated `Elixir.Kernel.raise`
  # nodes (see `Mutare.AST.absolute_call/3`). Both arities route here —
  # `String.equivalent?/2` direct, and the LHS-less `/1` pipe stage
  # (`a |> String.equivalent?(b)` → `a |> Elixir.Kernel.==(b)`) — so the same call builds
  # both, keeping the source's argument list.
  defp equivalent_substitution(args) when length(args) in [1, 2],
    do: [AST.absolute_call([:Kernel], :==, args)]

  defp equivalent_substitution(_), do: :skip
end
