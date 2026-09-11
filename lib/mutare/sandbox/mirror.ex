defmodule Mutare.Sandbox.Mirror do
  @moduledoc false
  # The kept-sandbox mirror, extracted from `Mutare.Sandbox`: re-materialise a project tree into
  # an owned sandbox *in place*, touching only what changed. `sync/4` mirrors every source entry
  # under `root` (file bytes, symlinks as symlinks, empty directories as directories), overlays
  # the generated `overrides`, mirrors permission bits, and prunes whatever is left that nothing
  # owns. `put_file_if_changed/3` is the byte-aware, symlink-safe writer the fresh path and the
  # ownership marker share, so "write a file into the sandbox" has one definition.
  #
  # The invariants everything here is built around (NOTES "`--keep-sandbox`: incremental
  # materialisation for CI caching"):
  #
  #   * an unchanged file is never written, so it keeps its mtime — what mix's incremental
  #     compiler keys staleness on (`File.cp_r!`/`File.write!` would both bump it to now);
  #   * nothing is read from or written *through* a symlink: `lstat` everywhere, a source link is
  #     recreated with the same raw target and never followed, and a path a generated file must
  #     land on replaces whatever link (or linked parent directory) sits there;
  #   * the `exclude`d top-level entries (`_build`, `.git`, …) are never read, written, or
  #     pruned, so compiled artifacts survive between runs;
  #   * a real mode change re-applies the file's mtime afterwards, since `File.chmod/2` resets
  #     it to now.
  #
  # The mirror carries each source's *shape*, not just its bytes — permission modes and
  # symlinks, which the fresh path's `File.cp_r!` preserves for free and a content-only sync
  # would silently flatten (a `0755` script arriving `0644`, a symlink vanishing).

  # The permission bits of a `File.Stat` mode, masking off the file-type bits, so a
  # mirrored mode compares and chmods cleanly (`0o100755` → `0o755`).
  @permission_bits 0o7777

  @typedoc """
  A mirrorable source entry, keyed by its root-relative path: a regular file with its permission
  bits, a symlink with its raw target, or a directory with nothing in it (a non-empty directory
  is implied by the entries under it).
  """
  @type entry :: {Path.t(), {:regular, non_neg_integer()} | {:symlink, Path.t()} | :directory}

  @doc """
  Re-materialise `root` into the owned `sandbox` in place, overlaying the generated `overrides`
  (`%{rel => content}`, keyed like the source entries).

  Options:

    * `:exclude` — top-level entries of `root` (and of `sandbox`) never read, written, or
      pruned, e.g. `_build`;
    * `:managed` — extra sandbox-relative paths to keep, though they are neither mirrored nor
      overridden (the ownership marker).

  Steps, in an order that matters:

  1. mirror every source entry a generated override does not own — file contents byte-aware,
     symlinks as symlinks (never followed), empty directories as directories;
  2. write every override. Deliberately *after* the mirror, so an override always wins over a
     copied symlink at its own path or at one of its parents, and lands as a real file inside
     the sandbox instead of being written through the link;
  3. mirror permission bits, last: a suite may invoke a project script or native helper, which
     needs its executable bit. Applied to overridden paths too — the metamutant of an executable
     script keeps the script's mode, as it does on the fresh path;
  4. drop anything left in the sandbox that nothing owns.
  """
  @spec sync(Path.t(), Path.t(), %{Path.t() => binary()},
          exclude: [String.t()],
          managed: [Path.t()]
        ) ::
          :ok
  def sync(root, sandbox, overrides, opts) do
    exclude = Keyword.fetch!(opts, :exclude)
    managed_extras = Keyword.get(opts, :managed, [])

    sources = source_entries(root, exclude)
    source_set = MapSet.new(sources, fn {rel, _kind} -> rel end)
    managed = MapSet.union(source_set, MapSet.new(managed_extras ++ Map.keys(overrides)))

    for {rel, kind} <- sources, not Map.has_key?(overrides, rel) do
      mirror_source(root, sandbox, rel, kind)
    end

    for {rel, content} <- overrides, do: put_file_if_changed(sandbox, rel, content)

    for {rel, {:regular, mode}} <- sources, do: mirror_mode_if_changed(sandbox, rel, mode)

    prune(sandbox, managed, exclude)
  end

  @doc """
  Write `content` at `rel` inside `sandbox`, only when the bytes differ.

  A size check short-circuits the read for the common unchanged-large-file case, so an
  unchanged file keeps its mtime. The path is materialised *inside* the sandbox even when
  a symlink sits at it or at one of its parent components: `File.write!/2` would follow the
  link and mutate the linked file outside the sandbox, so the parents are first recreated as
  ordinary directories and the target as a regular file.
  """
  @spec put_file_if_changed(Path.t(), Path.t(), binary()) :: :ok
  def put_file_if_changed(sandbox, rel, content) do
    path = Path.join(sandbox, rel)
    ensure_parent!(sandbox, rel)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size == byte_size(content) ->
        unless File.read(path) == {:ok, content}, do: File.write!(path, content)

      {:ok, %File.Stat{type: :regular}} ->
        File.write!(path, content)

      {:ok, %File.Stat{type: type}} ->
        remove_existing_path!(path, type)
        File.write!(path, content)

      {:error, :enoent} ->
        File.write!(path, content)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect sandbox file", path: path
    end

    :ok
  end

  # --- mirroring one entry -------------------------------------------------

  defp mirror_source(root, sandbox, rel, {:regular, _mode}) do
    put_file_if_changed(sandbox, rel, File.read!(Path.join(root, rel)))
  end

  defp mirror_source(_root, sandbox, rel, {:symlink, target}) do
    put_symlink_if_changed(sandbox, rel, target)
  end

  # An empty source directory: created (or cleared of whatever else sat at its path), and
  # kept by `prune/3` because it is managed, even though nothing under it is.
  defp mirror_source(_root, sandbox, rel, :directory) do
    ensure_parent!(sandbox, rel)
    ensure_dir!(Path.join(sandbox, rel))
  end

  # A source symlink is recreated as a symlink carrying the *same* raw target, exactly
  # as `File.cp_r!` does on the fresh path — the link is never followed, so a link
  # pointing outside the project is copied, not chased, and nothing is ever written
  # through it. Generated overrides are overlaid afterwards (see `sync/4`), so a path
  # Mutare owns replaces the link rather than dereferencing it.
  defp put_symlink_if_changed(sandbox, rel, target) do
    path = Path.join(sandbox, rel)
    ensure_parent!(sandbox, rel)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        unless File.read_link(path) == {:ok, target} do
          File.rm!(path)
          File.ln_s!(target, path)
        end

      {:ok, %File.Stat{type: type}} ->
        remove_existing_path!(path, type)
        File.ln_s!(target, path)

      {:error, :enoent} ->
        File.ln_s!(target, path)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect sandbox file", path: path
    end
  end

  # Only ever chmods a regular file, and only when the bits actually differ: the sandbox
  # path may legitimately have become something else (a symlink Mutare no longer owns is
  # pruned, not chmodded), and a no-op chmod is not free — `File.chmod/2` is Erlang's
  # `write_file_info` with only the mode filled in, which resets the file's mtime to *now*.
  # That would hand mix a spuriously-changed file on every sync and undo the whole point of
  # the byte-aware mirror, so the mtime is put back after a real mode change.
  defp mirror_mode_if_changed(sandbox, rel, mode) do
    path = Path.join(sandbox, rel)

    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mode: current, mtime: mtime}}
      when Bitwise.band(current, @permission_bits) != mode ->
        File.chmod!(path, mode)
        File.touch!(path, mtime)

      _ ->
        :ok
    end
  end

  # Recreate every parent component of `rel` as an ordinary directory inside the sandbox,
  # replacing a symlink (or anything else) sitting where a directory must be.
  defp ensure_parent!(sandbox, rel) do
    rel
    |> Path.dirname()
    |> Path.split()
    |> Enum.reject(&(&1 in [".", ""]))
    |> Enum.reduce(sandbox, fn part, parent ->
      path = Path.join(parent, part)
      ensure_dir!(path)
      path
    end)
  end

  defp ensure_dir!(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        remove_existing_path!(path, type)
        File.mkdir!(path)

      {:error, :enoent} ->
        File.mkdir!(path)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect sandbox directory", path: path
    end
  end

  defp remove_existing_path!(path, :directory), do: File.rm_rf!(path)
  defp remove_existing_path!(path, :symlink), do: File.rm!(path)
  defp remove_existing_path!(path, _type), do: File.rm!(path)

  # --- reading the source tree ---------------------------------------------

  # Every mirrorable entry under `root` (skipping `exclude` at the top level, matching the
  # fresh path's copy) as a `t:entry/0`, with `rel` keyed exactly like `Schema.metamutants`
  # (`rel_path/2`). A non-empty directory is walked but is not itself an entry — it is implied
  # by the files under it (`ensure_parent!/2`). An *empty* one has nothing to imply it, so it
  # is an entry of its own; without that a shallow git checkout under `deps/` loses its empty
  # `.git/refs/heads` and `.git/refs/tags`, git stops recognising the checkout, and Mix reports
  # every git dependency as a lock mismatch — a Phoenix app's `heroicons`/`daisyui` (NOTES "The
  # kept sandbox is the default"). A symlink is recorded, never descended, so its subtree is
  # mirrored only where it also lives under `root` in its own right. Anything else (device,
  # socket, unreadable) is skipped.
  defp source_entries(root, exclude) do
    for entry <- File.ls!(root),
        entry not in exclude,
        source <- walk(root, Path.join(root, entry)) do
      source
    end
  end

  defp walk(root, path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.ls!(path) do
          [] ->
            [{rel_path(root, path), :directory}]

          children ->
            for child <- children, source <- walk(root, Path.join(path, child)), do: source
        end

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        [{rel_path(root, path), {:regular, Bitwise.band(mode, @permission_bits)}}]

      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, target} -> [{rel_path(root, path), {:symlink, target}}]
          {:error, _} -> []
        end

      _ ->
        []
    end
  end

  defp rel_path(root, path), do: path |> Path.relative_to(root) |> to_string()

  # --- pruning -------------------------------------------------------------

  # Delete sandbox files and symlinks not in `managed`, then any directory left empty —
  # unless the empty directory is itself managed (an empty source directory, mirrored on
  # purpose). Never descends an `exclude`d dir, so `_build`/`cover` and their artifacts
  # survive — nor a symlink (`lstat` types it as `:symlink`), so pruning removes the link
  # itself and never walks into whatever it points at.
  defp prune(sandbox, managed, exclude) do
    for entry <- File.ls!(sandbox), entry not in exclude do
      prune_path(Path.join(sandbox, entry), entry, managed)
    end

    :ok
  end

  defp prune_path(path, rel, managed) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        for child <- File.ls!(path),
            do: prune_path(Path.join(path, child), Path.join(rel, child), managed)

        if File.ls!(path) == [] and not MapSet.member?(managed, rel), do: File.rmdir!(path)

      {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] ->
        unless MapSet.member?(managed, rel), do: File.rm!(path)

      _ ->
        :ok
    end
  end
end
