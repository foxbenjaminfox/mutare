defmodule Mutare.Transform.Suppression do
  @moduledoc false
  # Equivalent-mutant suppression predicates, shared by the two paths that drop a redundant
  # mutation: the in-place **body** path (`Mutare.Transform.Analyze`, which drops
  # `%Candidate.InPlace{}` candidates) and the lifted **guard** path (`Mutare.Transform.Tag`,
  # which rejects `%Mutare.Mutator.Dispatch.Result{}` mutations). Both reduce to the
  # same question asked of a *mutated node* — "is this the redundant sibling of a mutation
  # another family already produces?" — so the recognition rules live here once; each caller
  # unwraps its own candidate/mutation shape down to the bare node before asking. (Before this module the two
  # carried character-for-character copies of these predicates, including two `@equality_complements`
  # maps that had to be kept in lockstep by hand — see NOTES "equivalent-sibling suppression".)
  #
  # The rules, and where each path implements its descent (the call sites carry the
  # surrounding why). Both paths walk the same four shared shapes; the *structural* clauses
  # stay in each module because the two deliver differently — the body path attaches
  # `%Candidate.InPlace{}` to node meta while threading only `mutators`, the guard path
  # accumulates `{tag, original, [%Mutare.Mutator.Dispatch.Result{}]}` targets while threading a tag
  # counter — so a single walk would need a four-callback strategy that obscures the
  # node-level reasoning. What *is* centralized here is the **vocabulary** (which
  # operators trigger each rule, as `defguard`s usable in both paths' `when` clauses)
  # and the **predicates** (which mutant is the redundant sibling). A literal operator
  # list in one path can no longer silently drift from its twin in the other.
  #
  #   | rule                       | body (Analyze)              | guard (Tag)              |
  #   |----------------------------|-----------------------------|--------------------------|
  #   | double negation `not not`  | `is_negation_op/1` clause   | literal `:not` clause    |
  #   | negation over `in`         | `is_negation_op/1` clause   | literal `:not` clause    |
  #   | negation over equality op  | `is_negation_op` + `is_equality_op` | `is_equality_op/1` clause |
  #   | short-circuit connective   | `is_body_connective/1`      | `is_guard_connective/1`  |
  #   | unobservable operand swap  | `redundant_swap/1` on every call node | the same, on every n-ary node |
  #
  # The operand-swap rule is the one that looks at a node's *parent*: whether a child's swap
  # matters depends on how the parent reads the child's result. The body path also requires
  # that the swap not reorder two effects; a guard has none to reorder.
  #
  # `Tag` additionally suppresses an empty collection literal on the RHS of guard `in`.
  # There is deliberately no body twin: emptying only the RHS still evaluates the left
  # operand, while replacing the whole body expression with `false` skips it.
  #
  # The body path admits `!`/`&&`/`||` (`is_negation_op`/`is_body_connective` carry the
  # extra operators); the guard path can't (they are guard-illegal), so it matches the
  # subset (`is_guard_connective`, and a bare `:not` head with no `!`). That body ⊇ guard
  # relationship is the reason the two sets are *named here together* rather than written
  # as independent literals — a reader sees both at once.

  alias Mutare.AST
  alias Mutare.Mutators.Conditional
  alias Mutare.Transform.Calls

  # === operator vocabulary (shared by both suppression paths' `when` clauses) =========
  #
  # `defguard`s, not plain functions or module attributes, because the structural callers
  # use these in *guard* position (`when is_equality_op(op)`) — and a guard can neither
  # call a remote function nor read a remote attribute, but it *can* use an imported guard
  # macro. So this is the single source of truth for "which operators trigger suppression"
  # that a `when` clause can actually reference.

  @doc "The equality operators whose polarity complement re-negates to the source (both paths)."
  defguard is_equality_op(op) when op in [:==, :!=, :===, :!==]

  @doc "The boolean negations the body path suppresses under (`!` is guard-illegal, so guard-only `:not`)."
  defguard is_negation_op(op) when op in [:not, :!]

  @doc "Short-circuit connectives in a runtime **body** (`&&`/`||` included)."
  defguard is_body_connective(op) when op in [:and, :&&, :or, :||]

  @doc "Short-circuit connectives legal in a **guard** (`&&`/`||` excluded) — the subset of `is_body_connective/1`."
  defguard is_guard_connective(op) when op in [:and, :or]

  # The polarity complement of each equality operator — the swap that, *under a negation*,
  # re-negates to the operator itself (`not (a !== b)` ≡ `a === b`). Exactly Relational's
  # equality flip; a strictness relaxation (`===` → `==`) is `:==`, never `===`'s complement
  # `:!==`, so it is correctly *not* redundant.
  @equality_complements %{:== => :!=, :!= => :==, :=== => :!==, :!== => :===}

  @doc """
  Whether `mutated` re-negates to its source under an outer `not` — a `true`/`false` constant
  (Conditional, ≡ the outer's) or the polarity complement of equality operator `op` (Relational's
  flip ≡ Logical's strip). A strictness relaxation (`===` → `==`) is neither, so it survives.
  """
  @spec negation_redundant?(Macro.t(), atom()) :: boolean()
  def negation_redundant?(mutated, op),
    do:
      boolean_literal?(mutated, true) or boolean_literal?(mutated, false) or
        polarity_complement?(mutated, op)

  @doc """
  Whether `mutated` is the polarity complement of equality operator `op` — `{complement, _, _}`,
  the flip that re-negates to `op` under a `not`. A relaxation (`===` → `==`) is `{:==, _, _}`,
  never the complement of `===` (`:!==`), so it is correctly *not* redundant.
  """
  @spec polarity_complement?(Macro.t(), atom()) :: boolean()
  def polarity_complement?({mop, _meta, _args}, op),
    do: mop == Map.get(@equality_complements, op)

  def polarity_complement?(_node, _op), do: false

  @doc """
  Whether `mutated` is the literal boolean `bool` (`AST.literal/1`'s `{:__block__, _, [bool]}`
  or a bare `bool`) — identifying Conditional's `true`/`false` mutant. On a connective node only
  Conditional yields a bare boolean (Logical yields the swapped operator), so this uniquely
  selects the redundant constant without keying on the producing module.
  """
  @spec boolean_literal?(Macro.t(), boolean()) :: boolean()
  def boolean_literal?({:__block__, _meta, [b]}, b) when is_boolean(b), do: true
  def boolean_literal?(b, b) when is_boolean(b), do: true
  def boolean_literal?(_node, _bool), do: false

  @doc """
  Whether `node` is an n-ary node whose head is a Conditional-eligible boolean operator — i.e.
  Conditional fires on it, so a short-circuit connective's redundant constant has a subsuming
  sibling.
  """
  @spec boolean_op_node?(Macro.t()) :: boolean()
  defdelegate boolean_op_node?(node), to: Conditional, as: :boolean_node?

  @doc """
  The constant a short-circuit connective's Conditional mutant duplicates on its left operand:
  `false` for `and`/`&&` (a false left short-circuits the whole node to false), `true` for
  `or`/`||` (a true left short-circuits to true). The guard path only ever passes `and`/`or`
  (`&&`/`||` are guard-illegal), so those two arms are unreachable there but kept for the body path.
  """
  @spec redundant_constant(atom()) :: boolean()
  def redundant_constant(op) when op in [:and, :&&], do: false
  def redundant_constant(op) when op in [:or, :||], do: true

  # === operand swaps the enclosing expression cannot observe ==========================
  #
  # Swapping the operands of an *antisymmetric* operation changes its result by a fixed
  # involution: a three-way `compare/2` exchanges `:lt` and `:gt`, and a negating difference
  # (`Date.diff/2`, binary `-`) negates. A parent that reads the result through a test the
  # involution leaves alone cannot observe the swap (`DateTime.compare(a, b) == :eq`). A
  # parent whose test the involution turns into a test one sibling mutant writes runs that
  # mutant's program (`DateTime.compare(a, b) == :lt` swapped is `… == :gt`, ConventionAtom's).
  #
  # "Cannot observe" means: on every input, both orders return the same reading or both raise
  # the same exception type (the message may differ). The involution is exact only where the
  # operation is: no `diff` that rounds its difference (`DateTime`, `Time`, `NaiveDateTime`),
  # and no reading that sees a float zero's sign (`===`, a bare `abs/1`). Why each line is
  # drawn where it is: NOTES "Operand swaps the enclosing expression cannot observe".

  @three_way_modules [[:Date], [:Time], [:DateTime], [:NaiveDateTime], [:Version]]

  # Relational's direction flip of each ordering operator. Under a negated operand,
  # `x > 0` reads as `x < 0`, and so on.
  @direction_flips %{:< => :>, :> => :<, :<= => :>=, :>= => :<=}

  @typedoc """
  A path of argument indexes from a node down to one beneath it (`[]` is the node itself);
  `at/2` follows it, `update_at/3` rewrites what it reaches.
  """
  @type path :: [non_neg_integer()]

  @typedoc "Where the mutant equivalent to a redundant swap lives, and a test of its replacement."
  @type survivor :: {path(), (Macro.t() -> boolean())}

  @doc """
  The antisymmetric node under `parent` whose operand swap `parent` cannot observe, or
  observes only as the mutant `survivor` locates — `{path, :unobservable | survivor}`, both
  paths from `parent` — or `nil`. A pure reading of the written syntax: whether the swap
  reorders effects, and whether the survivor was actually produced, are the caller's to check.
  """
  @spec redundant_swap(Macro.t()) :: {path(), :unobservable | survivor()} | nil
  def redundant_swap({_form, meta, args} = parent) when is_list(meta) and is_list(args) do
    case Calls.kernel_form(parent) do
      nil -> nil
      op -> direct_reading(op, args) || reading_through_abs(op, args)
    end
  end

  def redundant_swap(_node), do: nil

  @doc "The node at `path` under `node`, or `nil` where the path leads nowhere."
  @spec at(Macro.t(), path()) :: Macro.t() | nil
  def at(node, []), do: node
  def at({_form, _meta, args}, [i | rest]) when is_list(args), do: args |> Enum.at(i) |> at(rest)
  def at(list, [i | rest]) when is_list(list), do: list |> Enum.at(i) |> at(rest)
  def at(_node, _path), do: nil

  @doc "`node` with `fun` applied to what `path` reaches (`at/2`'s indexing)."
  @spec update_at(Macro.t(), path(), (Macro.t() -> Macro.t())) :: Macro.t()
  def update_at(node, [], fun), do: fun.(node)

  def update_at({form, meta, args}, [i | rest], fun) when is_list(args),
    do: {form, meta, List.update_at(args, i, &update_at(&1, rest, fun))}

  def update_at(list, [i | rest], fun) when is_list(list),
    do: List.update_at(list, i, &update_at(&1, rest, fun))

  @doc """
  Whether `mutated` is `original` with its first two arguments exchanged, metadata aside —
  the shape every operand swap takes (OperandSwap's, or a custom mutator's).
  """
  @spec operand_swap?(Macro.t(), Macro.t()) :: boolean()
  def operand_swap?({head, _meta, [x, y | rest]}, {head0, _meta0, [a, b | rest0]}),
    do: strip([head, x, y | rest]) == strip([head0, b, a | rest0])

  def operand_swap?(_mutated, _original), do: false

  # An argument of the parent that is itself antisymmetric, read through the parent's test.
  defp direct_reading(op, args) do
    args
    |> Enum.with_index()
    |> Enum.find_value(fn {arg, index} ->
      case antisymmetry(arg) do
        nil -> nil
        kind -> reading(kind, op, args, index)
      end
    end)
  end

  # `abs(a - b) < tolerance`: `abs` erases the negation but keeps a zero's sign, which a
  # comparison other than `===`/`!==` then cannot see. Whatever the other operand is.
  defp reading_through_abs(op, [_, _] = args)
       when op in [:==, :!=] or is_map_key(@direction_flips, op) do
    args
    |> Enum.with_index()
    |> Enum.find_value(fn {arg, index} ->
      with {_form, _meta, [inner]} <- arg,
           :abs <- Calls.kernel_form(arg),
           kind when kind in [:difference, :integer_difference] <- antisymmetry(inner) do
        {[index, 0], :unobservable}
      else
        _other -> nil
      end
    end)
  end

  defp reading_through_abs(_op, _args), do: nil

  # What swapping `node`'s operands does to its result: `:three_way` exchanges `:lt` and `:gt`,
  # `:integer_difference` negates an integer, `:difference` negates a number of either kind.
  # `Date.diff` is the one `diff` here: the others round the difference to the unit.
  defp antisymmetry({_form, _meta, [_, _]} = node) do
    if Calls.kernel_form(node) == :- do
      :difference
    else
      case Calls.resolved_call(node) do
        {module, :compare, _args, _rebuild} when module in @three_way_modules -> :three_way
        {[:Date], :diff, _args, _rebuild} -> :integer_difference
        _other -> nil
      end
    end
  end

  defp antisymmetry(_node), do: nil

  # A three-way result tested against an atom: `:lt`/`:gt` exchange, anything else is fixed.
  defp reading(:three_way, op, [_, _] = args, index) when is_equality_op(op) do
    other = 1 - index

    case args |> Enum.at(other) |> atom_value() do
      {:ok, atom} when atom in [:lt, :gt] -> {[index], {[other], &literal?(&1, exchanged(atom))}}
      {:ok, _atom} -> {[index], :unobservable}
      :error -> nil
    end
  end

  # A three-way result tested for membership in a list of atoms: the involution fixes the set
  # when it holds both `:lt` and `:gt` or neither, and maps it to a sibling mutant's set when
  # it holds exactly one (ConventionAtom rewrites that one element).
  defp reading(:three_way, :in, [_, list], 0) do
    with {elements, path} <- list_elements(list),
         {:ok, atoms} <- all_atoms(elements) do
      case Enum.with_index(atoms) |> Enum.filter(fn {atom, _i} -> atom in [:lt, :gt] end) do
        [] -> {[0], :unobservable}
        [{atom, i}] -> {[0], {[1 | path] ++ [i], &literal?(&1, exchanged(atom))}}
        [{a, _}, {b, _}] when a != b -> {[0], :unobservable}
        _repeated -> nil
      end
    else
      _not_a_list_of_atoms -> nil
    end
  end

  # `match?(:eq, compare(a, b))`: a pattern literal is not mutated, so only a fixed atom counts.
  defp reading(:three_way, :match?, [pattern, _], 1) do
    case atom_value(pattern) do
      {:ok, atom} when atom not in [:lt, :gt] -> {[1], :unobservable}
      _other -> nil
    end
  end

  # A negated result tested for equality with zero. `==` cannot tell `0.0` from `-0.0`; `===`
  # can, so it counts only against the integer `0` (an integer negates exactly, and a float
  # is never `=== 0`).
  defp reading(kind, op, [_, _] = args, index)
       when kind in [:difference, :integer_difference] and is_equality_op(op) do
    case args |> Enum.at(1 - index) |> AST.literal_value() do
      {:ok, zero} when op in [:==, :!=] and zero == 0 -> {[index], :unobservable}
      {:ok, 0} -> {[index], :unobservable}
      _other -> nil
    end
  end

  # A negated result ordered against zero reads as the opposite ordering — Relational's
  # direction flip of the parent, with the same operands.
  defp reading(kind, op, [_, _] = args, index)
       when kind in [:difference, :integer_difference] and is_map_key(@direction_flips, op) do
    case args |> Enum.at(1 - index) |> AST.literal_value() do
      {:ok, zero} when zero == 0 ->
        flip = Map.fetch!(@direction_flips, op)
        {[index], {[], &(Calls.kernel_form(&1) == flip and same_arguments?(&1, args))}}

      _other ->
        nil
    end
  end

  # The absolute value of an integer difference. (Of a float difference it keeps the zero's
  # sign; `reading_through_abs/2` handles the comparisons that cannot see it.)
  defp reading(:integer_difference, :abs, [_], 0), do: {[0], :unobservable}
  defp reading(_kind, _op, _args, _index), do: nil

  defp list_elements({:__block__, _meta, [elements]}) when is_list(elements), do: {elements, [0]}
  defp list_elements(elements) when is_list(elements), do: {elements, []}
  defp list_elements(_node), do: nil

  defp all_atoms(elements) do
    values = Enum.map(elements, &atom_value/1)

    if Enum.all?(values, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(values, fn {:ok, atom} -> atom end)},
      else: :error
  end

  defp atom_value(node) do
    case AST.literal_value(node) do
      {:ok, atom} when is_atom(atom) -> {:ok, atom}
      _other -> :error
    end
  end

  defp literal?(node, value), do: AST.literal_value(node) == {:ok, value}

  defp exchanged(:lt), do: :gt
  defp exchanged(:gt), do: :lt

  defp same_arguments?({_form, _meta, args}, args0) when is_list(args),
    do: strip(args) == strip(args0)

  defp same_arguments?(_node, _args0), do: false

  # Metadata removed throughout, so two spellings of one node compare equal (route and
  # resolution stamps included).
  defp strip(node) do
    Macro.prewalk(node, fn
      {form, meta, args} when is_list(meta) -> {form, [], args}
      other -> other
    end)
  end
end
