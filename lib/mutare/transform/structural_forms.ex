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
  # Four classes, beyond the ordinary `:call`:
  #
  #   * `:structural` — an **expression** head: `if`/`unless`, the pipe, the boolean connectives
  #     and negations, `in`, and the *construct* special forms (`case`, `cond`, `with`, `for`,
  #     `try`, `receive`, `fn`, `quote`, `unquote`, `super`, the capture `&`). A route may `:skip`
  #     one — every walk honours `:skip` at its entry, ahead of its form clauses, so the node is an
  #     inert leaf exactly like a skipped call — but nothing else.
  #   * `:declaration` — a **definition or directive** head: `def`/`defp`, `defmacro`/`defmacrop`,
  #     `defmodule`, `defimpl`/`defprotocol`/`defdelegate`, `use`, `@`, and the special-form
  #     directives `alias`/`import`/`require`. Not a call in any sense a route could act on — a
  #     "skipped" `def` would still have its head lifted and its returns annotated by paths no
  #     route stamp reaches, and `# mutare:ignore` already owns "leave this definition alone" — so
  #     no route may name one, `:skip` included.
  #   * `:literal` — **literal and pattern syntax**: `{}`, `%{}`, `%`, `<<>>`, `=`, `^`, `::`. Data,
  #     not calls, and the literal families already own them (`--mutators`,
  #     `# mutare:ignore[<family>]`). The AST agrees that "skip every tuple" could never be honoured
  #     coherently: a two-tuple has no node of its own, a struct `%S{}` hides its `%{}`, an
  #     interpolated string is a `<<>>`. No route may name one.
  #   * `:internal` — every other special form: compiler-internal syntax a user never writes as a
  #     call (`{:__block__, …}` wraps every literal and statement sequence, `__aliases__` is how
  #     `Foo.Bar` parses, `.` is the remote-call head, the nullary `__MODULE__`/`__ENV__`/… are not
  #     calls at all). No route may name one.
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

  # The special forms partitioned (see the classes above). A form none of these lists name — a
  # future Elixir's, say — falls to `:internal`: rejected, the conservative reading.
  @special_form_constructs [
    :case,
    :cond,
    :with,
    :for,
    :try,
    :receive,
    :fn,
    :quote,
    :unquote,
    :unquote_splicing,
    :super,
    :&
  ]

  @special_form_directives [:alias, :import, :require]

  @special_form_literals [:{}, :%{}, :%, :<<>>, :=, :^, :"::"]

  @special_forms_key [:Kernel, :SpecialForms]

  @type class :: :call | :structural | :declaration | :literal | :internal

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
  `:structural` expression form (`:skip` only), or one of the classes no route may name — a
  `:declaration`, `:literal` syntax, or an `:internal` compiler form. A `nil` module key (a
  name-only match whose module the resolver couldn't see) is always a `:call`.
  """
  @spec classify(Spec.module_key() | nil, atom()) :: class()
  def classify([:Kernel], name) when name in @kernel_structural, do: :structural
  def classify([:Kernel], name) when name in @kernel_declarations, do: :declaration
  def classify(@special_forms_key, name) when name in @special_form_constructs, do: :structural
  def classify(@special_forms_key, name) when name in @special_form_directives, do: :declaration
  def classify(@special_forms_key, name) when name in @special_form_literals, do: :literal
  def classify(@special_forms_key, name) when name in @special_forms, do: :internal
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
      :literal -> raise ArgumentError, literal_message(module_key, name)
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
      :literal -> false
      :internal -> false
    end
  end

  @doc """
  The route text `Mutare.Poison.Hint` should suggest for a head: `:raw` for a call, `:skip`
  for a structural form, `nil` for a head no route can name (a declaration, literal syntax, an
  internal form).
  """
  @spec hint_treatment(Spec.module_key() | nil, atom()) :: :raw | :skip | nil
  def hint_treatment(module_key, name) do
    case classify(module_key, name) do
      :call -> :raw
      :structural -> :skip
      :declaration -> nil
      :literal -> nil
      :internal -> nil
    end
  end

  @doc """
  `hint_treatment/2` for a module named as the compiler prints it (`"Kernel"`, `"Ecto.Query"`) —
  the shape `Mutare.Poison.Hint` and `Mutare.Report.Live` receive. A segment naming no loaded
  module is a target-project module, and the head an ordinary call.
  """
  @spec hint_treatment_for(String.t(), atom()) :: :raw | :skip | nil
  def hint_treatment_for(module, name) when is_binary(module) do
    key =
      try do
        module |> String.split(".") |> Enum.map(&String.to_existing_atom/1)
      rescue
        ArgumentError -> nil
      end

    hint_treatment(key, name)
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

    "#{head} is a definition or directive, not a call: a call route cannot target it. To leave " <>
      "a definition alone, use `# mutare:ignore` (`-start`/`-end` for a span, `-file` for a " <>
      "whole file)."
  end

  defp literal_message(module_key, name) do
    "#{describe(module_key, name)} is literal or pattern syntax, not a call: a call route cannot " <>
      "name it. To hold back a literal family everywhere, use `--mutators` or " <>
      "`# mutare:ignore[<family>]`; to leave one position alone, route the enclosing call " <>
      "(`:raw` or `:interior`)."
  end

  defp internal_message(module_key, name) do
    "#{describe(module_key, name)} is a special form no call route can name (compiler-internal " <>
      "syntax, or a form Mutare does not route)."
  end

  defp describe(module_key, name), do: "#{inspect(Module.concat(module_key))}.#{name}"
end
