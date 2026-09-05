defmodule Mutare.Lifting do
  @moduledoc false

  # The `:skip_lifting` option's shared vocabulary: entry normalization/validation
  # (`validate_skip_lifting!/1`, `parse_cli_spec!/1`), the match predicate the planner
  # consults (`skip?/4`), and the resolution of a `defmodule` head to the module Elixir
  # actually defines (`module_from_alias/2`) — the key the user's entries are written
  # against. Kept out of `Mutare.Transform` so `Mutare.Config`/`Mutare.Options` can
  # validate without pulling the transform in.

  alias Mutare.Transform.Aliases

  @type skip_entry :: {module(), String.t(), non_neg_integer()}

  # The "enclosing module can't be known" sentinel: the enclosing `defmodule` head was
  # dynamic (`defmodule Module.concat(...)`), so every module nested under it is unknowable
  # too. Distinct from `nil` (= file top level, where the lexical alias env applies): a head
  # under an unresolved parent must resolve to *nothing* — resolving it with the top-level
  # rules would let it match an unrelated module's `:skip_lifting` entry. Same value as
  # `Mutare.Transform.Uses`' internal `@unresolved` for greppability (the two never meet).
  @unresolved :__mutare_unresolved__

  @type enclosing :: module() | :__mutare_unresolved__ | nil

  @alias_segment ~r/\A[A-Z][A-Za-z0-9_]*\z/
  @function_name ~r/\A[a-z_][A-Za-z0-9_]*[?!]?\z/

  @doc """
  The sentinel `Mutare.Transform` threads as the scope module when a `defmodule` head
  can't be resolved (a dynamic head). `skip?/4` and `module_from_alias/2` treat it as
  "never match / can't resolve" — unlike `nil`, which means "file top level".
  """
  @spec unresolved() :: :__mutare_unresolved__
  def unresolved, do: @unresolved

  @spec validate_skip_lifting!(nil | MapSet.t() | list()) :: MapSet.t(skip_entry())
  def validate_skip_lifting!(nil), do: MapSet.new()

  def validate_skip_lifting!(%MapSet{} = set),
    do: set |> Enum.map(&normalize_entry!/1) |> MapSet.new()

  def validate_skip_lifting!(entries) when is_list(entries),
    do: entries |> Enum.map(&normalize_entry!/1) |> MapSet.new()

  def validate_skip_lifting!(other) do
    raise ArgumentError,
          ":skip_lifting must be a list or MapSet of {Module, function, arity} entries, " <>
            "got: #{inspect(other)}"
  end

  @spec parse_cli_spec!(String.t()) :: skip_entry()
  def parse_cli_spec!(spec) when is_binary(spec) do
    with [left, arity_text] <- String.split(spec, "/", parts: 2),
         {arity, ""} when arity >= 0 <- Integer.parse(arity_text),
         {module_text, function} <- split_module_function(left),
         true <- module_alias?(module_text),
         true <- function_name?(function) do
      {module_from_text(module_text), function, arity}
    else
      _ ->
        raise ArgumentError,
              "--skip-lifting expects Module.function/arity " <>
                "(e.g. Phoenix.LiveView.LiveStream.new/4), got: #{inspect(spec)}"
    end
  end

  @spec skip?(MapSet.t(skip_entry()), enclosing(), atom(), non_neg_integer()) :: boolean()
  def skip?(_skip_lifting, module, _name, _arity) when module in [nil, @unresolved], do: false

  def skip?(skip_lifting, module, name, arity) do
    MapSet.member?(skip_lifting, {module, Atom.to_string(name), arity})
  end

  @spec format(MapSet.t(skip_entry())) :: String.t()
  def format(skip_lifting) do
    skip_lifting
    |> Enum.sort_by(fn {module, function, arity} -> {inspect(module), function, arity} end)
    |> Enum.map_join(", ", &format_entry/1)
  end

  @doc "One entry as the user would write it: `MyApp.Mod.fun/2`."
  @spec format_entry(skip_entry()) :: String.t()
  def format_entry({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"

  @doc """
  Whether `text` is a dot-separated module alias (`"Foo.Bar"`, `"Elixir.Foo"`).

  Gates `Module.concat/1` so only module-shaped input is interned as an atom. The one
  definition of "module-shaped CLI string" — `Mutare.Config` shares it for `--mutators`,
  so every flag accepts the same module syntax.
  """
  @spec module_alias?(String.t()) :: boolean()
  def module_alias?(text) do
    text
    |> String.split(".")
    |> Enum.all?(&Regex.match?(@alias_segment, &1))
  end

  @spec module_from_alias(Macro.t(), enclosing()) :: module() | nil
  def module_from_alias({:__aliases__, meta, path}, current_module)
      when is_list(path) and path != [] do
    case module_path(path, meta, current_module) do
      {:ok, module_key} -> Aliases.to_module(module_key)
      :error -> nil
    end
  end

  # An atom-named module (`defmodule :my_port_driver`, Sourceror-wrapped or bare): the
  # atom *is* the module, absolute regardless of nesting or aliases.
  def module_from_alias({:__block__, _meta, [module]}, _current_module)
      when is_atom(module) and not is_nil(module),
      do: module

  def module_from_alias(module, _current_module)
      when is_atom(module) and not is_nil(module),
      do: module

  def module_from_alias(_alias_node, _current_module), do: nil

  defp normalize_entry!({module, name, arity} = entry)
       when is_atom(module) and is_atom(name) and is_integer(arity) and arity >= 0 do
    function = Atom.to_string(name)
    if function_name?(function), do: {module, function, arity}, else: invalid_entry!(entry)
  end

  defp normalize_entry!({module, name, arity} = entry)
       when is_atom(module) and is_binary(name) and is_integer(arity) and arity >= 0 do
    if function_name?(name), do: {module, name, arity}, else: invalid_entry!(entry)
  end

  defp normalize_entry!(entry), do: invalid_entry!(entry)

  @spec invalid_entry!(term()) :: no_return()
  defp invalid_entry!(entry) do
    raise ArgumentError,
          ":skip_lifting entries must be {Module, function, arity} with a module atom, " <>
            "function atom or function-name string, and non-negative integer arity, " <>
            "got: #{inspect(entry)}"
  end

  defp split_module_function(left) do
    case left |> String.split(".") |> Enum.split(-1) do
      {module_parts, [function]} when module_parts != [] ->
        {Enum.join(module_parts, "."), function}

      _ ->
        :error
    end
  end

  # No `"Elixir." <> rest` special case: `Module.concat/1` already folds exactly one
  # canonical `Elixir` prefix (`["Elixir", "Foo"]` → `Foo`), and pre-stripping would
  # double-fold a genuine doubled prefix (`"Elixir.Elixir.MyUse"` names the module
  # `defmodule Elixir.Elixir.MyUse` defines — `:"Elixir.Elixir.MyUse"`, not `MyUse`).
  # `Mutare.Transform.Aliases` documents the same keep-the-doubled-prefix-whole rule.
  defp module_from_text(text), do: Module.concat(String.split(text, "."))

  @doc "Whether `name` is a function-name string (`\"parse\"`, `\"valid?\"`, `\"save!\"`)."
  @spec function_name?(String.t()) :: boolean()
  def function_name?(name), do: Regex.match?(@function_name, name)

  # An `Elixir.`-led head is absolute — it escapes both nesting and aliases. Keep the
  # *whole* path: `Module.concat/1` folds exactly one canonical `Elixir` prefix, so
  # stripping a segment here would double-fold `defmodule Elixir.Elixir.X` (see
  # `module_from_text/1`).
  defp module_path([:"Elixir" | _] = path, _meta, _current_module),
    do: literal_module_path(path)

  # Anything under an unresolvable (dynamic-head) parent is unresolvable too — never
  # fall through to the top-level rules, which would resolve the *written* path (or its
  # alias stamp) and match an unrelated module's entry.
  defp module_path(_path, _meta, @unresolved), do: :error

  defp module_path([{:__MODULE__, _node_meta, _context} | rest], _meta, current_module)
       when is_atom(current_module) and not is_nil(current_module) do
    if literal_path?(rest), do: {:ok, [current_module | rest]}, else: :error
  end

  defp module_path([{:__MODULE__, _node_meta, _context} | rest], _meta, nil),
    do: literal_module_path(rest)

  # A **nested** head: Elixir prefixes the *written* path with the enclosing module and does
  # **not** apply aliases to it (`alias Foo.Bar; defmodule Bar.Baz` inside `Outer` defines
  # `Outer.Bar.Baz`, not `Foo.Bar.Baz`), so any alias stamp is ignored here.
  defp module_path(path, _meta, current_module)
       when is_atom(current_module) and not is_nil(current_module) do
    if literal_path?(path), do: {:ok, [current_module | path]}, else: :error
  end

  # A **top-level** head: Elixir resolves the written path through the lexical alias env, so
  # consult the module the Resolve pre-pass stamped under `:mutare_alias` (`alias Real.Parent,
  # as: RP; defmodule RP.Child` defines `Real.Parent.Child`). No stamp ⇒ the literal path.
  defp module_path(path, meta, nil) do
    case Aliases.resolved_module(meta, path) do
      module when is_atom(module) -> {:ok, module}
      resolved when is_list(resolved) -> literal_module_path(resolved)
    end
  end

  defp literal_module_path(path) do
    if path != [] and literal_path?(path), do: {:ok, path}, else: :error
  end

  defp literal_path?(path), do: Aliases.atoms?(path)
end
