defmodule Mutare.Metamutant do
  @moduledoc """
  The shape of a selector `case` subject in the metamutant.

  This is the one piece of generated structure that `Mutare.Transform` writes
  and that `Mutare.Manifest` recognises for `Mutare.Poison` readback.
  Owning it in a single module keeps the producer from hand-building the same AST
  literal twice and keeps the consumer from re-deriving how to spot a selector.

  A selector `case` looks like:

      case :persistent_term.get(:mutare_active, 0) do
        17 -> <mutated>     # one clause per mutant id hosted here
        18 -> <mutated>
        _  -> <original>    # the catch-all: baseline + every inactive mutant
      end

  The subject is one of two shapes. A module-level / `:scaffold` / head-default
  selector reads `:persistent_term` **inline** (the form above). A selector inside a
  function *body* instead reads the **hoisted** active id — a bare reference to the
  dispatch variable `mutare_active`, bound once per function activation (the lifted
  dispatcher threads it as the base clause's first parameter; a non-lifted function
  binds it in a `:do`-block prologue), so the per-site `:persistent_term.get` is gone:

      case mutare_active do          # the hoisted read — same shape, cheaper subject
        17 -> <mutated>
        mutare_active -> <original>
      end

  Recognising the subject is enough to find every selector:

    * `subject_ast/0` builds the inline subject `Transform` splices in,
    * `subject?/2` recognises *either* shape — the inline read unconditionally, the
      hoisted bare variable only when the active-id variable name is supplied (the
      predicate `Mutare.Manifest` uses to walk a rendered metamutant, recovering that
      name once via `Manifest.active_var/1`).

  `subject?/2` is tolerant of how the subject is *parsed back*: bare ASTs may keep
  `:persistent_term`/`:mutare_active` as atoms, while `Mutare.Manifest`
  re-parses with `Code.string_to_quoted!` plus a literal encoder that wraps literals as
  `{:__block__, _, [literal]}` for `Sourceror.get_range/1` compatibility. The
  predicate has to see through both shapes.

  `Mutare.Selector` owns the runtime constants (the `:persistent_term` key and
  the baseline id); this module owns their AST.
  """

  alias Mutare.AST

  @baseline Mutare.Selector.baseline()

  # The key is read from `Mutare.Selector.key/0` at *runtime*, not baked as a
  # compile-time attribute: when Mutare dogfoods itself, the suite-under-test
  # building fixtures in the sandbox resolves it to its private `suite_key/0`,
  # while the harness process (where the real metamutant is built) resolves it to
  # `default_key/0` — so producer (`subject_ast/0`) and recognizer (`subject?/2`)
  # always agree *within a process*, and the two key-spaces stay disjoint.

  @doc """
  The selector subject `Transform` splices into every selector/dispatcher `case`:
  `:persistent_term.get(<key>, <baseline>)`.
  """
  @spec subject_ast() :: Macro.t()
  def subject_ast do
    # Block-wrap the literal args (the clean-meta convention). Bare literals render
    # fine as a `case` *subject*, but as a match RHS — `mutare_active =
    # :persistent_term.get(:mutare_active, 0)` in a lifted dispatcher — the Elixir
    # formatter's `force_args?/2` inspects the call args and crashes on a bare atom
    # (it expects `{_, meta, _}` nodes). Wrapping makes every spliced subject render
    # cleanly in any position; `subject?/2` sees through the wrapping.
    {{:., [], [:persistent_term, :get]}, [],
     [{:__block__, [], [Mutare.Selector.key()]}, {:__block__, [], [@baseline]}]}
  end

  @doc """
  Returns whether `node` is a selector subject.

  `Mutare.Manifest` uses this while walking rendered metamutant source. Two shapes
  match:

    * the inline read built by `subject_ast/0`:
      `:persistent_term.get(<key>, <baseline>)`
    * the hoisted read used inside function bodies: a bare reference to the active
      mutant variable `var`

  The hoisted form is recognised only when `var` is supplied. That prevents an
  ordinary source-level `case some_var do ...` from being treated as a selector.

  Literal wrappers added by `Mutare.Manifest`'s readback parse are accepted,
  as are bare atoms from ordinary quoted ASTs.
  """
  @spec subject?(Macro.t(), atom() | nil) :: boolean()
  def subject?(node, var \\ nil)

  def subject?({{:., _, [mod, :get]}, _, [key | _]}, _var),
    do:
      AST.unwrap_literal(mod) == :persistent_term and
        AST.unwrap_literal(key) == Mutare.Selector.key()

  def subject?({name, _meta, context}, var)
      when is_atom(name) and is_atom(context) and not is_nil(var),
      do: name == var

  def subject?(_node, _var), do: false

  @doc """
  Returns whether `node` is a tupled selector subject.

  The tuple-the-scrutinee path emits case subjects as
  `{<selector_subject>, <scrutinee>}`. The mutant clauses then gate on the active
  id in guards, so `Mutare.Manifest` recognises the dispatch by checking the
  tuple's first element with `subject?/2`.

  Both the bare two-tuple and the `{:__block__, _, [{first, scrutinee}]}` wrapper
  produced by literal-encoded reparse are accepted. `var` is passed through so the
  hoisted selector-variable form is recognised too.
  """
  @spec pattern_subject?(Macro.t(), atom() | nil) :: boolean()
  def pattern_subject?(node, var \\ nil)
  def pattern_subject?({:__block__, _meta, [{first, _scrutinee}]}, var), do: subject?(first, var)
  def pattern_subject?({first, _scrutinee}, var), do: subject?(first, var)
  def pattern_subject?(_node, _var), do: false
end
