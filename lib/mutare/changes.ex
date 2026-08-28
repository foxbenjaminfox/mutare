defmodule Mutare.Changes do
  @moduledoc """
  Source *lines* changed versus a git ref — the basis for `mix mutare --since`,
  the CI mode that mutation-tests only what a branch touched.

  Scoping is per-line, not per-file: a one-line edit to a large module mutates
  only that line, not the whole file. The changed lines are fed to `:only_lines`
  (the same site filter `--line` uses), so a `--since` run and a `--line` run
  share all the downstream machinery.
  """

  # Hunk header: `@@ -<old_start>[,<old_count>] +<new_start>[,<new_count>] @@`.
  # A missing count means 1 (git omits `,1`); an explicit `,0` means the side
  # contributes no lines (a pure insertion or deletion). Named captures return
  # "" for the absent optional counts, which `count/1` reads as 1.
  @hunk ~r/^@@ -(?<os>\d+)(?:,(?<oc>\d+))? \+(?<ns>\d+)(?:,(?<nc>\d+))? @@/

  @doc """
  Lines changed under `root` versus `ref`, as a set of `{relative_path, line}`
  pairs on the *new* side of the diff (the lines that now exist to be mutated).

  Uses `git diff -U0 --relative`, run with `root` as the working dir, so it
  reports working-tree changes (committed and uncommitted) since `ref`, scoped
  to and relative to `root`. The diff command disables presentation/user hooks
  and pins prefixes because the output is parsed, and turns off `core.quotePath`
  so a non-ASCII pathname arrives verbatim rather than octal-escaped. `-U0` drops context lines so
  only genuinely-added lines land in the set; pure deletions contribute nothing
  (their file drops out entirely if it has no other changes). Returns
  `{:error, detail}` if git fails (no repo, bad ref, git missing).
  """
  @spec since(Path.t(), String.t()) :: {:ok, MapSet.t()} | {:error, String.t()}
  def since(root, ref) do
    case System.cmd(
           "git",
           [
             "-C",
             root,
             "-c",
             "core.quotePath=false",
             "diff",
             "--no-ext-diff",
             "--no-color",
             "--src-prefix=a/",
             "--dst-prefix=b/",
             "-U0",
             "--relative",
             ref
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, parse_diff(output)}

      {output, _status} ->
        {:error, String.trim(output)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Fold the unified diff into a set of {file, new_line} pairs.
  #
  # The state carries the current new-side file plus how many body lines of the
  # in-progress hunk are still to be consumed (`add` remaining `+` lines, `rem`
  # remaining `-` lines). While a hunk body is being consumed we never interpret
  # a line as a header — that is what makes the parse robust against content that
  # happens to look like a `+++ ` file header or an `@@` hunk marker.
  defp parse_diff(output) do
    output
    |> String.split("\n")
    |> Enum.reduce({nil, 0, 0, MapSet.new()}, &parse_line/2)
    |> elem(3)
  end

  # Inside a hunk body: consume one line, decrementing the matching counter, and
  # never treat it as a header. `-U0` still emits `\ No newline at end of file`
  # markers, which belong to no side and must not decrement either counter.
  defp parse_line("\\" <> _, {file, add, rem, acc}) when add + rem > 0,
    do: {file, add, rem, acc}

  defp parse_line("+" <> _, {file, add, rem, acc}) when add > 0,
    do: {file, add - 1, rem, acc}

  defp parse_line("-" <> _, {file, add, rem, acc}) when rem > 0,
    do: {file, add, rem - 1, acc}

  # Header region (no hunk body pending). New-side file name, then hunk headers.
  defp parse_line("+++ " <> path, {_file, 0, 0, acc}) do
    case unquote_path(path) do
      "/dev/null" -> {nil, 0, 0, acc}
      "b/" <> file -> {file, 0, 0, acc}
      file -> {file, 0, 0, acc}
    end
  end

  defp parse_line("@@" <> _ = line, {file, 0, 0, acc} = state) do
    case Regex.named_captures(@hunk, line) do
      %{"oc" => oc, "ns" => ns, "nc" => nc} when is_binary(file) ->
        new_start = String.to_integer(ns)
        new_count = count(nc)
        {file, new_count, count(oc), add_lines(acc, file, new_start, new_count)}

      _ ->
        state
    end
  end

  defp parse_line(_line, state), do: state

  defp add_lines(acc, _file, _start, 0), do: acc

  defp add_lines(acc, file, start, count) do
    Enum.reduce(start..(start + count - 1), acc, &MapSet.put(&2, {file, &1}))
  end

  defp count(""), do: 1
  defp count(n), do: String.to_integer(n)

  # Git C-quotes a pathname it won't print raw: the whole name (prefix included)
  # is wrapped in double quotes, with `\`-escapes for the specials and `\nnn`
  # *octal byte* escapes for the rest. `core.quotePath=false` above spares the
  # common case (a UTF-8 name), but a name containing `"`, `\`, or a control
  # character is quoted regardless — so unquote before stripping the `b/` prefix,
  # which git puts *inside* the quotes. Decoding is byte-wise: the octal escapes
  # of a UTF-8 name reassemble into exactly that name's bytes, so the result
  # matches the discovered file it names.
  defp unquote_path(<<?", rest::binary>> = path) do
    size = byte_size(rest)

    if size > 0 and :binary.last(rest) == ?" do
      unescape(binary_part(rest, 0, size - 1), "")
    else
      path
    end
  end

  defp unquote_path(path), do: path

  defp unescape(<<>>, acc), do: acc

  defp unescape(<<?\\, a, b, c, rest::binary>>, acc)
       when a in ?0..?3 and b in ?0..?7 and c in ?0..?7 do
    unescape(rest, <<acc::binary, (a - ?0) * 64 + (b - ?0) * 8 + (c - ?0)>>)
  end

  defp unescape(<<?\\, escape, rest::binary>>, acc),
    do: unescape(rest, <<acc::binary, escaped(escape)>>)

  defp unescape(<<char, rest::binary>>, acc), do: unescape(rest, <<acc::binary, char>>)

  # The named escapes; anything else (`\"`, `\\`) stands for the byte itself.
  defp escaped(?a), do: 0x07
  defp escaped(?b), do: 0x08
  defp escaped(?f), do: 0x0C
  defp escaped(?n), do: ?\n
  defp escaped(?r), do: ?\r
  defp escaped(?t), do: ?\t
  defp escaped(?v), do: 0x0B
  defp escaped(char), do: char
end
