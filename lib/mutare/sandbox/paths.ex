defmodule Mutare.Sandbox.Paths do
  @moduledoc false
  # Path-safety for sandbox materialisation. `Mutare.Sandbox` `rm_rf!`s and rewrites the
  # sandbox directory, so a `--sandbox` that resolves onto the project tree could destroy
  # source. `validate!/2` refuses a sandbox that *is*, is *inside*, or *contains* the project
  # root — checking both the fully-resolved path and the parent-resolved-plus-literal-leaf
  # path, since they differ exactly when the final component is itself a symlink. Pure path
  # resolution and comparison with no Sandbox-specific state, so the component-by-component
  # symlink resolver is testable in isolation. Extracted from `Mutare.Sandbox`.

  @doc """
  Validate that `sandbox` is disjoint from the project `root`.

  Raises `ArgumentError` when the sandbox resolves to, into, or around `root` (any of
  which would let materialisation destroy or corrupt project source); returns `:ok`
  otherwise. `root` is resolved through every symlink; `sandbox` is checked under both
  interpretations of where it lands (see the inline note).
  """
  @spec validate!(Path.t(), Path.t()) :: :ok
  def validate!(root, sandbox) do
    root = resolve_path(root)
    expanded_sandbox = Path.expand(sandbox)

    # Two interpretations of where the sandbox *actually* lands, both checked against the project
    # root because materialisation `rm_rf!`s and rewrites that directory — if either resolves
    # inside the tree it could destroy source. They differ only when the final path component is
    # itself a symlink:
    #   1. `resolve_path(sandbox)` follows every symlink, the final component included — catches a
    #      sandbox that *is* a symlink into the tree (`/tmp/sb -> project/lib`).
    #   2. resolve only the *parent* chain, then re-join the literal basename — the spot where a
    #      not-yet-existing sandbox dir would be created (and wiped), catching a parent symlink
    #      that puts it inside the tree even when the leaf doesn't exist to resolve.
    # `Enum.uniq` collapses the common case where they agree. Don't fold this to a single path:
    # each interpretation guards a distinct symlink case the other misses.
    sandbox_paths =
      [
        resolve_path(expanded_sandbox),
        expanded_sandbox
        |> Path.dirname()
        |> resolve_path()
        |> Path.join(Path.basename(expanded_sandbox))
      ]
      |> Enum.uniq()

    case Enum.find_value(sandbox_paths, &overlap(&1, root)) do
      nil ->
        :ok

      relation ->
        raise ArgumentError,
              "unsafe sandbox path #{inspect(sandbox)}: it #{relation} the project root " <>
                "#{inspect(root)}; choose a directory outside the project tree"
    end
  end

  defp overlap(path, root) do
    cond do
      same_path?(path, root) -> "is"
      descendant?(path, root) -> "is inside"
      descendant?(root, path) -> "contains"
      true -> nil
    end
  end

  defp same_path?(left, right), do: path_components(left) == path_components(right)

  defp descendant?(path, parent) do
    path_parts = path_components(path)
    parent_parts = path_components(parent)

    length(path_parts) > length(parent_parts) and
      Enum.take(path_parts, length(parent_parts)) == parent_parts
  end

  defp path_components(path) do
    parts = Path.split(path)

    case :os.type() do
      {:win32, _} -> Enum.map(parts, &case_fold/1)
      {:unix, :darwin} -> Enum.map(parts, &case_fold/1)
      _ -> parts
    end
  end

  defp case_fold(part), do: part |> String.normalize(:nfc) |> String.downcase()

  # Resolve symlinks component-by-component so an existing symlinked parent
  # cannot make a lexically external sandbox land inside the project tree.
  defp resolve_path(path, links_left \\ 40) do
    path
    |> Path.expand()
    |> Path.split()
    |> then(fn [root | parts] -> resolve_parts(root, parts, links_left) end)
  end

  defp resolve_parts(path, [], _links_left), do: path

  defp resolve_parts(path, [part | rest], links_left) do
    candidate = Path.join(path, part)

    case File.read_link(candidate) do
      {:ok, _target} when links_left == 0 ->
        raise ArgumentError, "cannot validate path with more than 40 symbolic links"

      {:ok, target} ->
        target =
          case Path.type(target) do
            :absolute -> target
            _ -> Path.expand(target, path)
          end

        resolve_path(join_parts(target, rest), links_left - 1)

      {:error, :einval} ->
        resolve_parts(candidate, rest, links_left)

      {:error, :enoent} ->
        join_parts(candidate, rest)

      {:error, reason} ->
        raise ArgumentError,
              "cannot validate path #{inspect(candidate)}: #{:file.format_error(reason)}"
    end
  end

  defp join_parts(path, parts), do: Enum.reduce(parts, path, &Path.join(&2, &1))
end
