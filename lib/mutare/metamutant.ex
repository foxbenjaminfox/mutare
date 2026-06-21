defmodule Mutare.Metamutant do
  @moduledoc """
  The shape of a selector `case` subject in the metamutant.

  This is the one piece of generated structure that `Mutare.Transform` writes
  and that the readers (`Mutare.Manifest`, used by both `Mutare.Coverage` and
  `Mutare.Poison`) recognise. Owning it in a single module keeps the producer
  from hand-building the same AST literal twice and keeps the consumers from
  re-deriving how to spot a selector.

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

  `subject?/2` is tolerant of how the subject is *parsed back*: `Code.string_to_quoted`
  leaves `:persistent_term`/`:mutare_active` as bare atoms, while `Sourceror.parse_string!`
  wraps every literal in a `{:__block__, _, [literal]}`. `Mutare.Manifest` re-parses with
  Sourceror (it needs `Sourceror.get_range/1` for the generated line ranges), so the
  predicate has to see through that wrapping.

  `Mutare.Selector` owns the runtime constants (the `:persistent_term` key and
  the baseline id); this module owns their AST.
  """

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
  Whether `node` is a selector subject — the predicate `Mutare.Manifest` walks with.

  Two shapes are accepted:

    * the **inline read** `:persistent_term.get(<key>, <baseline>)` (`subject_ast/0`) —
      what a module-level / `:scaffold` / head-default selector splices, recognised
      independently of `var`; and
    * the **hoisted read** — a bare reference to the active-id variable `var`, what a
      selector inside a function body splices once the read is hoisted to a prologue /
      threaded parameter (see `Mutare.Transform`'s `selector_subject/1`). Recognised
      only when `var` is supplied (the canonical/salted dispatch name the caller
      discovers), so a user's `case some_var do …` is never mistaken for a selector.

  Tolerant of the `{:__block__, _, [literal]}` wrapping `Sourceror.parse_string!`
  adds (and a no-op on the bare-atom shape `Code.string_to_quoted` produces).
  """
  @spec subject?(Macro.t(), atom() | nil) :: boolean()
  def subject?(node, var \\ nil)

  def subject?({{:., _, [mod, :get]}, _, [key | _]}, _var),
    do: unwrap(mod) == :persistent_term and unwrap(key) == Mutare.Selector.key()

  def subject?({name, _meta, context}, var)
      when is_atom(name) and is_atom(context) and not is_nil(var),
      do: name == var

  def subject?(_node, _var), do: false

  @doc """
  Whether `node` is the **tupled** subject of a `case` rewritten by the tuple-the-scrutinee
  path (`Mutare.Transform.emit_case_pattern_site/3`): a 2-tuple `{<subject>, <scrutinee>}`
  whose first element is the plain selector subject. `Mutare.Manifest` uses this to spot such
  a `case` (its mutant clauses gate on the active id via a `when` guard, not the clause
  pattern, so the dispatch is recognised by the subject, then by the gate).

  A 2-tuple *is* a literal, so when `Mutare.Manifest` parses the metamutant back with a
  `:literal_encoder`, the subject arrives wrapped as `{:__block__, _, [{first, scrutinee}]}`;
  the bare 2-tuple form is matched too (the shape `Transform` splices). `var` is the
  hoisted active-id variable (or `nil`), threaded to `subject?/2` so a tupled subject
  whose first element is the bare variable (`{mutare_active, <subject>}`) is recognised
  too.
  """
  @spec pattern_subject?(Macro.t(), atom() | nil) :: boolean()
  def pattern_subject?(node, var \\ nil)
  def pattern_subject?({:__block__, _meta, [{first, _scrutinee}]}, var), do: subject?(first, var)
  def pattern_subject?({first, _scrutinee}, var), do: subject?(first, var)
  def pattern_subject?(_node, _var), do: false

  # See through Sourceror's literal wrapping (`{:__block__, _, [:persistent_term]}`);
  # a bare atom passes through untouched.
  defp unwrap({:__block__, _meta, [literal]}), do: literal
  defp unwrap(other), do: other
end
