defmodule Mutare.Sandbox do
  @moduledoc """
  Materialise a schema as a runnable copy of the target project.

  We copy the project to a dedicated directory (excluding build output), write
  each metamutant over its original, and inject a tiny bootstrap into
  `test/test_helper.exs` that reads `MUTANT_UNDER_TEST` into `:persistent_term`
  before the suite starts. The bootstrap is plain Erlang/Elixir with no
  dependency on Mutare, so the sandbox needs nothing added to its deps.

  Full-copy isolation is the simplest correct choice; swapping it for a shared
  build path is an open question (see DESIGN.md) to settle by measuring on a
  large umbrella.

  Materialising the workspace lives here; running `mix` against it (and the
  per-mutant timeout cap the bootstrap honours) lives in `Mutare.Sandbox.Command`.
  """

  alias Mutare.{Options, Schema}
  alias Mutare.Coverage.Recorder
  alias Mutare.Sandbox.Command

  @excluded ~w(_build .git .elixir_ls .lexical cover)

  # A sandbox is a throwaway copy we compile, mutate, and wipe. Before clearing a
  # directory we must be sure it is *ours* — not, say, a path `--sandbox` was
  # pointed at by mistake — so we never `rm_rf!` arbitrary user data. We take a
  # path only when it is one of:
  #
  #   1. absent — we create it;
  #   2. an empty directory — we adopt it; or
  #   3. a directory carrying our ownership marker — a sandbox from an earlier
  #      run, which we wipe and reuse (poison recovery rebuilds the same path).
  #
  # Anything else — a non-empty directory we never marked, a regular file, a
  # symlink — is refused untouched. The marker is a small dotfile whose first
  # line is a fixed signature; we verify its contents (not just its name) so a
  # coincidental file cannot hand us ownership of a directory we did not create.
  @marker_name ".mutare_sandbox"
  @marker_signature "mutare-sandbox-ownership-marker"
  @marker_body """
  #{@marker_signature}

  This directory is a Mutare sandbox: a throwaway, compiled-and-mutated copy of a
  target project. Mutare wipes and rebuilds it on every run — keep nothing here.
  """

  # The bootstrap is two dependency-free snippets, each rendered the same way from
  # a quoted AST its owner defines: the mutant selector
  # (`Mutare.Selector.bootstrap_ast/0`) and the per-mutant timeout watcher
  # (`Mutare.Sandbox.Command.watcher_ast/0`). The watcher enforces the wall-clock
  # cap *portably* — instead of the runner killing a hung OS process tree (which
  # needs platform-specific signals), the mutant process halts *itself* after the
  # deadline. `System.halt/1` stops the VM immediately and uncatchably, and the
  # BEAM preempts a looping process so the watcher always gets to run; if the
  # suite finishes first it dies with the VM. Each snippet stays owned next to its
  # own constants and is parsed at build time, not assembled here as a string.
  @selector_bootstrap Macro.to_string(Mutare.Selector.bootstrap_ast())
  @timeout_watcher Macro.to_string(Command.watcher_ast())

  @bootstrap """
  # ---- injected by Mutare: select the active mutant from the environment ----
  #{@selector_bootstrap}

  # ---- injected by Mutare: per-mutant timeout (self-halt; no external kill) --
  #{@timeout_watcher}
  # ---------------------------------------------------------------------------
  """

  # The coverage probe must start tracking before user `test_helper.exs` code,
  # because helpers often start the app or touch mutated code. `ExUnit.after_suite/1`
  # is only registerable after `ExUnit.start/0`, though, so coverage is injected
  # in two pieces around the user's helper.
  @coverage_helper Recorder.helper_source()
  @coverage_setup """
  # ---- injected by Mutare: coverage setup (inert unless probing) ------------
  #{Macro.to_string(Recorder.setup_ast())}
  # ---------------------------------------------------------------------------
  """
  @coverage_after_suite """
  # ---- injected by Mutare: coverage dump (inert unless probing) -------------
  #{Macro.to_string(Recorder.after_suite_ast())}
  # ---------------------------------------------------------------------------
  """

  @doc """
  Prepare a sandbox for `schema` taken from `root`. Returns the sandbox path.

  `opts` is a `Mutare.Options` (or a keyword list resolved into one); its
  `:sandbox` field is the target directory (default: a fresh temp dir).

  The sandbox must be disjoint from the project tree: it cannot be the project
  root, contain it, or be contained by it. `Options` validates the *shape* of the
  path; this disjointness check is enforced here because it is relative to `root`.

  To avoid deleting arbitrary data, the target path is only used when it is
  absent, an empty directory, or a directory carrying Mutare's ownership marker
  (a sandbox from an earlier run); anything else is refused untouched.
  """
  @spec prepare(Path.t(), Schema.t(), Options.t() | keyword()) :: Path.t()
  def prepare(root, %Schema{} = schema, opts \\ []) do
    sandbox = Options.new(opts).sandbox || default_sandbox()

    validate_paths!(root, sandbox)
    claim!(sandbox)

    copy_project(root, sandbox)
    write_metamutants(sandbox, schema)
    write_coverage_helper(sandbox)
    inject_bootstrap(sandbox)

    sandbox
  end

  @doc "The bootstrap snippet prepended to the sandbox's test helper."
  @spec bootstrap() :: String.t()
  def bootstrap, do: @bootstrap

  # --- internals -----------------------------------------------------------

  defp default_sandbox do
    Path.join(System.tmp_dir!(), "mutare_sandbox_#{System.unique_integer([:positive])}")
  end

  # Take ownership of the sandbox path, then leave our marker. `lstat` (not
  # `stat`) so a symlink is seen as a symlink, never followed to a directory we
  # would then wipe.
  defp claim!(sandbox) do
    case File.lstat(sandbox) do
      {:error, :enoent} ->
        File.mkdir_p!(sandbox)

      {:ok, %File.Stat{type: :directory}} ->
        cond do
          owned?(sandbox) -> reset!(sandbox)
          File.ls!(sandbox) == [] -> :ok
          true -> refuse!(sandbox, "is a non-empty directory without Mutare's ownership marker")
        end

      {:ok, %File.Stat{type: type}} ->
        refuse!(sandbox, "is a #{type}, not a directory")

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect sandbox", path: sandbox
    end

    File.write!(marker_path(sandbox), @marker_body)
  end

  # Ours iff the marker is a regular file whose contents start with our
  # signature — verified, so a coincidental dotfile can't grant ownership.
  defp owned?(sandbox) do
    path = marker_path(sandbox)

    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path)) and
      match?({:ok, @marker_signature <> _}, File.read(path))
  end

  defp reset!(sandbox) do
    File.rm_rf!(sandbox)
    File.mkdir_p!(sandbox)
  end

  defp marker_path(sandbox), do: Path.join(sandbox, @marker_name)

  defp refuse!(sandbox, reason) do
    raise ArgumentError,
          "refusing to use sandbox #{inspect(sandbox)}: it #{reason}. Mutare only writes " <>
            "to a path that is absent, an empty directory, or a previous Mutare sandbox; " <>
            "point it at a fresh or empty directory."
  end

  defp validate_paths!(root, sandbox) do
    root = resolve_path(root)
    expanded_sandbox = Path.expand(sandbox)

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

  defp copy_project(root, sandbox) do
    for entry <- File.ls!(root), entry not in @excluded do
      File.cp_r!(Path.join(root, entry), Path.join(sandbox, entry))
    end
  end

  defp write_metamutants(sandbox, %Schema{metamutants: metamutants}) do
    for {rel, source} <- metamutants do
      path = Path.join(sandbox, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
    end
  end

  # The dependency-free coverage helper is compiled with the app, so the
  # metamutant's per-site `hit/1` call resolves. It is written under a generated
  # `lib/` path chosen not to overwrite copied target source; the helper module
  # uses an Erlang-style atom name to avoid likely Elixir module collisions such
  # as a target's own `MutareCov`.
  defp write_coverage_helper(sandbox) do
    path = coverage_helper_path(sandbox)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @coverage_helper <> "\n")
  end

  defp coverage_helper_path(sandbox) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(fn
      0 -> "lib/__mutare__/coverage_helper.ex"
      n -> "lib/__mutare__/coverage_helper_#{n}.ex"
    end)
    |> Stream.map(&Path.join(sandbox, &1))
    |> Enum.find(&(not File.exists?(&1)))
  end

  defp inject_bootstrap(sandbox) do
    helper = Path.join(sandbox, "test/test_helper.exs")
    File.mkdir_p!(Path.dirname(helper))
    existing = if File.exists?(helper), do: File.read!(helper), else: "ExUnit.start()\n"

    File.write!(
      helper,
      @bootstrap <> "\n" <> @coverage_setup <> "\n" <> existing <> "\n" <> @coverage_after_suite
    )
  end
end
