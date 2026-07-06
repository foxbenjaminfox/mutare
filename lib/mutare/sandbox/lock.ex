defmodule Mutare.Sandbox.Lock do
  @moduledoc false

  @name ".mutare_sandbox.lock"
  @owner_name "owner"
  @metadata_grace_seconds 5

  defstruct [:dir, :token]

  @type t :: %__MODULE__{dir: Path.t(), token: String.t()}

  @doc false
  def name, do: @name

  @doc false
  @spec acquire(Path.t()) :: t()
  def acquire(sandbox) when is_binary(sandbox) do
    do_acquire(sandbox, 0)
  end

  @doc false
  @spec release(t() | nil) :: :ok
  def release(nil), do: :ok

  def release(%__MODULE__{dir: dir, token: token}) do
    with {:ok, owner} <- read_owner(dir),
         ^token <- owner["token"] do
      File.rm_rf(dir)
    end

    :ok
  end

  defp do_acquire(sandbox, attempts) when attempts < 5 do
    dir = Path.join(sandbox, @name)
    token = token()

    case File.mkdir(dir) do
      :ok ->
        write_owner!(dir, token)
        %__MODULE__{dir: dir, token: token}

      {:error, :eexist} ->
        reclaim_or_refuse!(sandbox, dir, attempts)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create sandbox lock", path: dir
    end
  end

  defp do_acquire(sandbox, _attempts) do
    raise ArgumentError,
          "could not acquire sandbox lock under #{inspect(sandbox)} after repeated stale-lock retries"
  end

  defp reclaim_or_refuse!(sandbox, dir, attempts) do
    case read_owner(dir) do
      {:ok, owner} ->
        if owner_live?(owner) do
          refuse_live!(sandbox, dir, owner)
        else
          File.rm_rf(dir)
          do_acquire(sandbox, attempts + 1)
        end

      :error ->
        if recent?(dir) do
          raise ArgumentError,
                "sandbox #{inspect(sandbox)} is already being locked by another Mutare process " <>
                  "(lock metadata is not written yet at #{inspect(dir)})"
        else
          File.rm_rf(dir)
          do_acquire(sandbox, attempts + 1)
        end
    end
  end

  @spec refuse_live!(Path.t(), Path.t(), map()) :: no_return()
  defp refuse_live!(sandbox, dir, owner) do
    pid = Map.get(owner, "pid", "unknown")
    host = Map.get(owner, "host", "unknown host")

    raise ArgumentError,
          "sandbox #{inspect(sandbox)} is already in use by Mutare process #{pid} on " <>
            "#{host} (lock #{inspect(dir)}). Use a different --sandbox path, wait for " <>
            "that run to finish, or remove the lock only after confirming the owner is gone."
  end

  defp write_owner!(dir, token) do
    owner = %{
      "host" => host(),
      "pid" => System.pid(),
      "started_at_ms" => Integer.to_string(System.system_time(:millisecond)),
      "start_time" => proc_start_time(System.pid()) || "",
      "token" => token
    }

    content =
      owner
      |> Enum.sort()
      |> Enum.map_join("\n", fn {key, value} -> "#{key}=#{value}" end)

    File.write!(Path.join(dir, @owner_name), content <> "\n")
  end

  defp read_owner(dir) do
    with {:ok, content} <- File.read(Path.join(dir, @owner_name)),
         owner when map_size(owner) > 0 <- parse_owner(content),
         pid when is_binary(pid) and pid != "" <- owner["pid"] do
      {:ok, Map.put(owner, "pid", pid)}
    else
      _ -> :error
    end
  end

  defp parse_owner(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] when key != "" -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp owner_live?(owner) do
    owner_host = owner["host"]

    if owner_host in [nil, "", host()] do
      same_process?(owner["pid"], owner["start_time"])
    else
      true
    end
  end

  defp same_process?(pid, recorded_start_time) do
    cond do
      not pid_string?(pid) ->
        false

      current = proc_start_time(pid) ->
        recorded_start_time in [nil, ""] or recorded_start_time == current

      true ->
        pid_alive?(pid)
    end
  end

  defp pid_string?(pid) when is_binary(pid), do: Regex.match?(~r/^\d+$/, pid)
  defp pid_string?(_pid), do: false

  defp pid_alive?(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  rescue
    ErlangError -> false
  end

  # Linux procfs gives us the process start time, so PID reuse does not keep a
  # dead lock alive forever. The stat file's second field is the command in
  # parentheses and may contain spaces, so split after the final ") " and count
  # from field 3; starttime is field 22.
  defp proc_start_time(pid) when is_binary(pid) do
    path = Path.join(["/proc", pid, "stat"])

    with {:ok, stat} <- File.read(path),
         [_, rest] <- :binary.split(stat, ") "),
         fields <- String.split(rest),
         start_time when is_binary(start_time) <- Enum.at(fields, 19) do
      start_time
    else
      _ -> nil
    end
  end

  defp recent?(dir) do
    case File.stat(dir, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        System.system_time(:second) - mtime < @metadata_grace_seconds

      _ ->
        false
    end
  end

  defp host do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp token do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
