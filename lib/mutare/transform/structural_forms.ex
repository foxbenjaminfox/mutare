defmodule Mutare.Transform.StructuralForms do
  @moduledoc false
  # The resolved heads a call route may *name* but that Mutare does not analyze as calls.
  #
  # `Mutare.Transform.Analyze` (and its guard/pattern twin `Mutare.Transform.Tag`) dispatch on
  # these heads with dedicated clauses that name the context of each position — a condition, a
  # clause pattern, an operand under a negation, a compile-time directive argument — rather than
  # walking them as call arguments. That is what makes them *structural*: they have no positions
  # in the routing sense, so a positional treatment (`:raw`, `:interior`, a keyed refinement, a
  # `:routing` classifier) has nothing to attach to. Left unchecked, such a route would either be
  # ignored by the dedicated clause (a silent no-op — what `{Kernel, :if, 2, :skip}` used to be)
  # or, if pushed through the generic argument walk, silently replace the structural analysis
  # (the condition replacements, the binding hoist, the pattern contexts). Neither is
  # acceptable, so the routing surface narrows here, in one place, consulted by
  # `Mutare.CallRouting.Spec.new/4` (an explicit key: a hard `ArgumentError`) and by
  # `Mutare.Transform.Resolve.RouteStamp` (a wildcard route cascading onto one of these heads:
  # its positions do not apply, so the head is left unstamped).
  #
  # Two classes, beyond the ordinary `:call`:
  #
  #   * `:structural` — an **expression** head: `if`/`unless`, the pipe, the boolean connectives
  #     and negations, `in`, and every `Kernel.SpecialForms` form (`case`, `cond`, `with`, `for`,
  #     `fn`, `=`, `%{}`, …). A route may `:skip` one — every walk honours `:skip` at its entry,
  #     ahead of its form clauses, so the node is an inert leaf exactly like a skipped call — but
  #     nothing else.
  #   * `:declaration` — a **definition or directive** head: `def`/`defp`, `defmacro`/`defmacrop`,
  #     `defmodule`, `defimpl`/`defprotocol`/`defdelegate`, `use`, `@`. Not a call in any sense a
  #     route could act on — a "skipped" `def` would still have its head lifted and its returns
  #     annotated by paths no route stamp reaches, and `# mutare:ignore` already owns "leave this
  #     definition alone" — so no route may name one, `:skip` included.
  #
  # Everything else — every other `Kernel` export (`inspect/2`, `send/2`, the arithmetic and
  # comparison operators, `match?/2`, the sigils, `defstruct`, …) and every remote function or
  # macro — is a `:call`, and the whole routing vocabulary applies.
  #
  # The special-form names come from `Kernel.SpecialForms` itself (by *name*: their nominal
  # arities don't track the AST — a `with` node has one argument per clause plus the block — so
  # `Mutare.Transform.Resolve` resolves a bare special form by name too). NOTES "Call routing:
  # `:skip`, `:raw`, `:interior`, keyed refinements", the "structural heads" paragraph.

  alias Mutare.CallRouting.Spec

  @kernel_structural [:if, :unless, :|>, :!, :not, :in, :and, :or, :&&, :||]

  @kernel_declarations [
    :def,
    :defp,
    :defmacro,
    :defmacrop,
    :defmodule,
    :defimpl,
    :defprotocol,
    :defdelegate,
    :use,
    :@
  ]

  @special_forms Kernel.SpecialForms.__info__(:macros) |> Keyword.keys() |> Enum.uniq()

  # Compiler-internal special forms a user never writes as a call: `{:__block__, …}` wraps every
  # literal and statement sequence, `__aliases__` is how `Foo.Bar` parses, `.` is the remote-call
  # head, `__cursor__` is the editor's, and the nullary `__MODULE__`/`__ENV__`/… are not calls at
  # all. A route on one names nothing the user could mean (and honouring it would mean stamping
  # every literal's wrapper), so it is rejected outright.
  @internal_forms [
    :__block__,
    :__aliases__,
    :__cursor__,
    :.,
    :__CALLER__,
    :__DIR__,
    :__ENV__,
    :__MODULE__,
    :__STACKTRACE__
  ]

  @special_forms_key [:Kernel, :SpecialForms]

  @type class :: :call | :structural | :declaration | :internal

  @doc """
  The module key a bare special form resolves to — `Kernel.SpecialForms`, as a route names it.
  """
  @spec special_forms_key() :: [atom()]
  def special_forms_key, do: @special_forms_key

  @doc """
  Whether `name` is a `Kernel.SpecialForms` form (`case`, `with`, `fn`, `=`, `%{}`, …), by name.
  """
  @spec special_form?(atom()) :: boolean()
  def special_form?(name), do: name in @special_forms

  @doc """
  How a route on the resolved head `module_key`/`name` is treated: an ordinary `:call`, a
  `:structural` expression form (`:skip` only), a `:declaration` (no route at all), or an
  `:internal` compiler form (no route at all). A `nil` module key (a name-only match whose module
  the resolver couldn't see) is always a `:call`.
  """
  @spec classify(Spec.module_key() | nil, atom()) :: class()
  def classify([:Kernel], name) when name in @kernel_structural, do: :structural
  def classify([:Kernel], name) when name in @kernel_declarations, do: :declaration
  def classify(@special_forms_key, name) when name in @internal_forms, do: :internal
  def classify(@special_forms_key, name) when name in @special_forms, do: :structural
  def classify(_module_key, _name), do: :call

  @doc """
  Rejects a route whose explicit key names a head that cannot carry it: any route on a
  declaration, a positional (non-`:skip`) route on a structural form. Raises `ArgumentError`.
  """
  @spec validate!(Spec.module_key(), atom(), Spec.args()) :: :ok
  def validate!(module_key, name, args) do
    case classify(module_key, name) do
      :call -> :ok
      :structural when args == :skip -> :ok
      :structural -> raise ArgumentError, structural_message(module_key, name)
      :declaration -> raise ArgumentError, declaration_message(module_key, name)
      :internal -> raise ArgumentError, internal_message(module_key, name)
    end
  end

  @doc """
  Whether a route that *matched* this head may be stamped on it — the stamp-time twin of
  `validate!/3`, for a wildcard route (`{Kernel, :*, :raw}`, `{:*, :if, …}`) whose cascade
  reached a head its own key never named. A structural form takes a `:skip`; a declaration
  takes nothing.
  """
  @spec applies?(Spec.module_key() | nil, atom(), Spec.t()) :: boolean()
  def applies?(module_key, name, %Spec{} = spec) do
    case classify(module_key, name) do
      :call -> true
      :structural -> Spec.skip?(spec)
      :declaration -> false
      :internal -> false
    end
  end

  @doc """
  The route text `Mutare.Poison.Hint` should suggest for a head: `:raw` for a call, `:skip`
  for a structural form, `nil` for a declaration or an internal form (no route can name it).
  """
  @spec hint_treatment(Spec.module_key() | nil, atom()) :: :raw | :skip | nil
  def hint_treatment(module_key, name) do
    case classify(module_key, name) do
      :call -> :raw
      :structural -> :skip
      :declaration -> nil
      :internal -> nil
    end
  end

  defp structural_message(module_key, name) do
    head = describe(module_key, name)

    "#{head} is analyzed structurally by Mutare — its parts (a condition, a branch, an operand, " <>
      "a clause) are not call arguments — so a route on it accepts only :skip (the whole form " <>
      "becomes an inert leaf). To hold back particular mutants inside one, use " <>
      "`# mutare:ignore[<family>]` on the line or `--mutators`."
  end

  defp declaration_message(module_key, name) do
    head = describe(module_key, name)

    "#{head} is a definition, not a call: a call route cannot target it. To leave a definition " <>
      "alone, use `# mutare:ignore` (`-start`/`-end` for a span, `-file` for a whole file)."
  end

  defp internal_message(module_key, name) do
    "#{describe(module_key, name)} is compiler-internal syntax, never written as a call: a call " <>
      "route cannot name it."
  end

  defp describe(module_key, name), do: "#{inspect(Module.concat(module_key))}.#{name}"
end
