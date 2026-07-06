defmodule Mutare.Lifting do
  @moduledoc false

  @type skip_entry :: {module(), String.t(), non_neg_integer()}

  @alias_segment ~r/\A[A-Z][A-Za-z0-9_]*\z/
  @function_name ~r/\A[a-z_][A-Za-z0-9_]*[?!]?\z/

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

  @spec skip?(MapSet.t(skip_entry()), module() | nil, atom(), non_neg_integer()) :: boolean()
  def skip?(_skip_lifting, nil, _name, _arity), do: false

  def skip?(skip_lifting, module, name, arity) do
    MapSet.member?(skip_lifting, {module, Atom.to_string(name), arity})
  end

  @spec format(MapSet.t(skip_entry())) :: String.t()
  def format(skip_lifting) do
    skip_lifting
    |> Enum.sort_by(fn {module, function, arity} -> {inspect(module), function, arity} end)
    |> Enum.map_join(", ", fn {module, function, arity} ->
      "#{inspect(module)}.#{function}/#{arity}"
    end)
  end

  @spec module_from_alias(Macro.t(), module() | nil) :: module() | nil
  def module_from_alias({:__aliases__, _meta, path}, current_module)
      when is_list(path) and path != [] do
    case module_path(path, current_module) do
      {:ok, path} -> Module.concat(path)
      :error -> nil
    end
  end

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

  defp module_from_text("Elixir." <> rest), do: Module.concat(String.split(rest, "."))
  defp module_from_text(text), do: Module.concat(String.split(text, "."))

  defp module_alias?("Elixir." <> rest), do: module_alias?(rest)

  defp module_alias?(text) do
    text
    |> String.split(".")
    |> Enum.all?(&Regex.match?(@alias_segment, &1))
  end

  defp function_name?(name), do: Regex.match?(@function_name, name)

  defp module_path([:"Elixir" | rest], _current_module), do: literal_module_path(rest)

  defp module_path([{:__MODULE__, _meta, _context} | rest], current_module)
       when is_atom(current_module) and not is_nil(current_module) do
    if literal_path?(rest), do: {:ok, [current_module | rest]}, else: :error
  end

  defp module_path([{:__MODULE__, _meta, _context} | rest], nil),
    do: literal_module_path(rest)

  defp module_path(path, current_module)
       when is_atom(current_module) and not is_nil(current_module) do
    if literal_path?(path), do: {:ok, [current_module | path]}, else: :error
  end

  defp module_path(path, nil), do: literal_module_path(path)

  defp literal_module_path(path) do
    if path != [] and literal_path?(path), do: {:ok, path}, else: :error
  end

  defp literal_path?(path), do: Enum.all?(path, &is_atom/1)
end
