defmodule Mutare.Sandbox.Ownership do
  @moduledoc false
  # The sandbox-ownership guard, extracted from `Mutare.Sandbox`: the code that decides whether a
  # path may be adopted, wiped, or must be refused untouched — the one place that can `rm_rf!` a
  # sandbox, so it is kept small and self-contained. `claim!/3` takes ownership of the target dir
  # for `prepare/3` (creating/adopting/resetting it and leaving the ownership marker); `ensure_lockable!/1`
  # is the lighter precheck `acquire_lock/2` runs before dropping a lock file. Both share the same
  # lstat dispatch (`ensure_ownable_directory!/2`), so the safety-critical "never touch a
  # non-directory" rule lives in exactly one place.

  alias Mutare.Sandbox.Lock

  # Sourced from `Mutare.Sandbox.Lock`, the single owner of the lock filename, so the "the lock is
  # not real content" carve-out (in `reset!/1` and `effectively_empty?/1`) can't drift from it.
  @lock_name Lock.name()

  # A sandbox is a copy we compile, mutate, overwrite, and (in fresh mode) wipe.
  # Before clearing a directory we must be sure it is *ours* — not, say, a path
  # `--sandbox` was pointed at by mistake — so we never `rm_rf!` arbitrary user
  # data. We take a path only when it is one of:
  #
  #   1. absent — we create it;
  #   2. an empty directory — we adopt it; or
  #   3. a directory carrying our ownership marker — a sandbox from an earlier
  #      run, which we reuse: synced in place in kept mode, wiped and re-copied
  #      in fresh mode (poison recovery rebuilds the same path either way).
  #
  # Anything else — a non-empty directory we never marked, a regular file, a
  # symlink — is refused untouched. The marker is a small dotfile whose first
  # line is a fixed signature; we verify its contents (not just its name) so a
  # coincidental file cannot hand us ownership of a directory we did not create.
  @marker_name ".mutare_sandbox"
  @marker_signature "mutare-sandbox-ownership-marker"
  @marker_body """
  #{@marker_signature}

  This directory is a Mutare sandbox: a compiled-and-mutated copy of a target
  project. Mutare overwrites and prunes it on every run — keep nothing here.
  """

  @doc "The ownership-marker filename, so `Mutare.Sandbox`'s keep-mode prune keeps it managed."
  @spec marker_name() :: String.t()
  def marker_name, do: @marker_name

  # Take ownership of the sandbox path (create / adopt / reset it — see `handle_existing_dir!/3`),
  # then leave our marker. `pinned?` is whether the caller chose `:sandbox` explicitly (vs. an
  # auto-generated default) — it decides how an existing *owned* dir is treated in fresh mode.
  def claim!(sandbox, keep?, pinned?) do
    ensure_ownable_directory!(sandbox, fn -> handle_existing_dir!(sandbox, keep?, pinned?) end)
    put_if_changed(marker_path(sandbox), @marker_body)
  end

  # The lstat dispatch `claim!/3` and `ensure_lockable!/1` share: create an absent path, run
  # `on_existing_dir` for a directory (the one branch that differs — adopt/reset vs. validate), and
  # refuse any non-directory / raise on any other lstat error. `lstat` (not `stat`) so a symlink is
  # seen as a symlink, never followed to a directory we would then wipe. Keeping the refuse/raise
  # branches here is the point: the "never touch a non-directory" safety rule lives in one place.
  defp ensure_ownable_directory!(sandbox, on_existing_dir) do
    case File.lstat(sandbox) do
      {:error, :enoent} ->
        File.mkdir_p!(sandbox)

      {:ok, %File.Stat{type: :directory}} ->
        on_existing_dir.()

      {:ok, %File.Stat{type: type}} ->
        refuse!(sandbox, "is a #{type}, not a directory")

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect sandbox", path: sandbox
    end
  end

  # What to do with an existing *directory* at the sandbox path, by ownership and mode.
  defp handle_existing_dir!(sandbox, keep?, pinned?) do
    owned = owned?(sandbox)

    cond do
      # Keep mode reuses an owned dir *in place* — `sync` re-materialises it,
      # preserving its `_build`. Never wiped.
      keep? and owned ->
        :ok

      # Fresh mode at an explicitly pinned `:sandbox`: wiping a prior Mutare
      # sandbox at a fixed path is the documented, intended reuse.
      owned and pinned? ->
        reset!(sandbox)

      # Fresh mode at an auto-generated path: the pid-salted name cannot collide
      # with a *live* run, so an existing owned dir here is a stale leftover (or,
      # very rarely, an unexpected pid+counter collision). Refuse loudly rather
      # than silently wipe — clobbering a concurrently-active sandbox is exactly
      # the corruption the salting guards against.
      owned ->
        refuse_autogen!(sandbox)

      effectively_empty?(sandbox) ->
        :ok

      true ->
        refuse!(sandbox, "is a non-empty directory without Mutare's ownership marker")
    end
  end

  # Ours iff the marker is a regular file whose contents start with our
  # signature — verified, so a coincidental dotfile can't grant ownership.
  defp owned?(sandbox) do
    path = marker_path(sandbox)

    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path)) and
      match?({:ok, @marker_signature <> _}, File.read(path))
  end

  defp reset!(sandbox) do
    File.mkdir_p!(sandbox)

    for entry <- File.ls!(sandbox), entry != @lock_name do
      File.rm_rf!(Path.join(sandbox, entry))
    end
  end

  defp marker_path(sandbox), do: Path.join(sandbox, @marker_name)

  @spec refuse!(Path.t(), String.t()) :: no_return()
  defp refuse!(sandbox, reason) do
    raise ArgumentError,
          "refusing to use sandbox #{inspect(sandbox)}: it #{reason}. Mutare only writes " <>
            "to a path that is absent, an empty directory, or a previous Mutare sandbox; " <>
            "point it at a fresh or empty directory."
  end

  @spec refuse_autogen!(Path.t()) :: no_return()
  defp refuse_autogen!(sandbox) do
    raise ArgumentError,
          "refusing to use sandbox #{inspect(sandbox)}: it is an existing Mutare sandbox at an " <>
            "auto-generated path. That path is salted with this process's OS pid, so it cannot " <>
            "collide with a live run — this is a stale leftover from a halted run (or, rarely, " <>
            "an unexpected pid+counter collision). Mutare won't wipe it automatically; delete it " <>
            "and re-run, or pass an explicit --sandbox to reuse a fixed path."
  end

  # The lock lives inside the sandbox, so a lock-only directory is still empty
  # for adoption purposes. This is the crash-before-marker case: Mutare created
  # the sandbox path and acquired the lock, then died before writing the ownership
  # marker.
  defp effectively_empty?(sandbox) do
    sandbox
    |> File.ls!()
    |> Enum.reject(&(&1 == @lock_name))
    |> Enum.empty?()
  end

  # Refuse non-empty, unowned directories before creating or reclaiming an
  # internal lock. That keeps a user-provided sandbox scoped to that exact path
  # without dropping a lock file into arbitrary user data.
  def ensure_lockable!(sandbox) do
    ensure_ownable_directory!(sandbox, fn ->
      unless owned?(sandbox) or effectively_empty?(sandbox) do
        refuse!(sandbox, "is a non-empty directory without Mutare's ownership marker")
      end
    end)
  end

  # Write only when the bytes actually change, so unchanged files keep their mtime.
  # A size check short-circuits the full read for the common unchanged-large-file
  # case.
  defp put_if_changed(path, content) do
    unless same_content?(path, content) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end
  end

  defp same_content?(path, content) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size == byte_size(content) ->
        File.read(path) == {:ok, content}

      _ ->
        false
    end
  end
end
