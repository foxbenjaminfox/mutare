defmodule Mutare.Mutators.StringCall do
  @moduledoc """
  Swap complementary `String` calls for their directional opposite:

    * `String.starts_with?` ↔ `String.ends_with?`
    * `String.upcase` ↔ `String.downcase`
    * `String.trim_leading` ↔ `String.trim_trailing`
    * `String.replace_prefix` ↔ `String.replace_suffix`
    * `String.replace_leading` ↔ `String.replace_trailing`
    * `String.pad_leading` ↔ `String.pad_trailing`
    * `String.first` ↔ `String.last`
    * `String.graphemes` ↔ `String.codepoints`

  …plus the Erlang `:string` module's directional/case pairs:

    * `:string.uppercase` ↔ `:string.lowercase`  (analogue of `upcase`/`downcase`)
    * `:string.to_upper` ↔ `:string.to_lower`     (the legacy case pair)
    * `:string.left` ↔ `:string.right`            (justify/pad direction — the
      analogue of `pad_leading`/`pad_trailing`)

  …plus the Erlang `:binary` module's first/last pair — the byte-level twin of
  `String.first`/`String.last`:

    * `:binary.first` ↔ `:binary.last`            (the first vs last *byte* of a
      binary, where `String.first`/`last` take the first/last grapheme)

  (The trim/predicate pairs have no `:string` twin — there the *direction* is an
  argument atom, e.g. `:string.trim(s, :leading)`, not a distinct function name,
  so renaming cannot express the swap.)

  It also makes one **call → operator** substitution: `String.equivalent?(a, b)`
  (Unicode-canonical equality) → `Kernel.==(a, b)`, dropping the normalization. The
  mutant survives unless a test feeds canonically-equivalent-but-distinct encodings —
  pointing at exactly that gap.

  The sibling of `Mutare.Mutators.Collection` (the `Enum`/`List` swaps). `String`, the
  Erlang `:string` module, and the Erlang `:binary` module are all matched in their
  direct, aliased, and bare-imported forms (`String.upcase`, `alias String, as: S;
  S.upcase`, `import String; upcase`, and likewise `:string.uppercase`, `:binary.first`),
  while a shadowing `alias MyApp.String` is left alone.

  On by default — high signal on the affix/case/predicate functions that anchor
  string-handling logic, exactly where an off-by-direction bug hides. Distinct
  from `Mutare.Mutators.StringLiteral` (the `:string` family), which mutates the
  string *value*; this mutates the *call*.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST
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

      {module, fun, args, rebuild} ->
        case Map.fetch(@swaps, {module, fun}) do
          # `rebuild` reuses the written module node, so the swap stays within the module
          # (and an aliased `S.upcase`/imported `upcase` keeps its written form).
          {:ok, new_fun} -> [rebuild.(new_fun, args)]
          :error -> :skip
        end

      nil ->
        :skip
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
