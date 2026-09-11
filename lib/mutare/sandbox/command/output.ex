defmodule Mutare.Sandbox.Command.Output do
  @moduledoc """
  Read shapes out of a `mix` run's captured output.

  A mutant's exit code is the *primary* signal (`Mutare.Sandbox.Command` decodes
  it), but four jobs need to look *past* the code at the human-readable output:

    * **Refining a verdict.** Exit `1` is ambiguous — a genuine harness failure or
      a mutation that broke the test suite's own compilation — and a BEAM abort can
      land on any code. `suite_compile_error?/1`, `atom_exhausted?/1`, and
      `boot_failure?/1` are the pure discriminators `Mutare.Sandbox.Command.outcome/2`
      consults to split those cases (see that module's moduledoc for *why* each is
      the verdict it is).
    * **Locating a failure.** `Mutare.Poison` maps a failed metamutant compile back
      to mutant ids (`source_location_regex/0` + `diagnostic_severity/1`), and
      `Mutare.Runner.Baseline` names the tests in a flaky run (`test_location_regex/0`).
    * **Diagnosing dependencies.** `dependency_issue/1` distinguishes Mix's
      dependency-check failures from compile-poisoning so the runner can stop
      recovery immediately and the Mix task can recommend the correct command in
      the original project rather than the disposable sandbox.
    * **Summarising a failure.** A `:harness_error` has no verdict to explain it, so
      `Mutare.Report.HarnessDiagnostic` shows the one output line most likely to:
      `salient_line/1` skips mix's routine chatter and prefers a line that heads a
      failure.

  ## Why these live together

  Every pattern here recognises a shape in `mix`'s human-readable output, so they
  all break together if mix ever changes its format. They are read for *different*
  jobs by *different* modules — `compile_error_banner/0` to tell a kill from infra,
  `source_location_regex/0` to map a compile error to a mutant id, `test_location_regex/0`
  to name flaky tests — and the consumers are deliberately **not** merged (they parse
  for different ends). But sourcing every pattern from one module gives a
  mix-output-format change a single home.

  Everything here is pure, so each discriminator is unit-testable without spawning
  `mix`.
  """

  # === Mix output vocabulary ==================================================
  #
  # Patterns recognising shapes in mix's human-readable output. Co-located because
  # they all break together if mix ever changes its format, though each is read for
  # a different job by a different module (see the moduledoc).

  @compile_error_banner ~r/== Compilation error in file (\S+) ==/
  @source_location ~r{([\w/.\-]+\.exs?):(\d+)}
  @test_location ~r{([\w/.\-]+_test\.exs):(\d+)}
  @unchecked_dependencies ~r/^Unchecked dependencies for environment [^:]+:/m
  @diverged_dependencies ~r/^Dependencies have diverged:/m

  # A BEAM *abort* banner — not mix output, but read for the same job (refining a
  # verdict from captured output), so co-located here. The emulator prints this to
  # stderr and halts the whole node the instant the global atom table fills; a
  # mutation that mints unbounded atoms (an unterminated search building a fresh
  # `:"#{x}_#{i}"` per step) is what gets it there. `stderr` is merged into the
  # captured output (`stderr_to_stdout: true`), so the banner reaches `outcome/2`.
  # The wording (`no more index entries in atom_tab`) is stable across OTP releases.
  @atom_table_exhausted ~r/no more index entries in atom_tab/

  # A BEAM *boot crash* whose diagnostic was self-erased. When a supervised child
  # (a Repo/Postgrex/Redix connection under worker contention) fails to start, the
  # node tears down mid-boot; the CLI exit-reporter then tries to print the dying
  # task's error to `:standard_error`, but that IO device is already gone, so the
  # emulator terminates with `{badarg,[{io,put_chars,[standard_error,…]}]}` —
  # *replacing* the original reason. Both halves are read, since the secondary
  # failure — the reporter *recursing on* the torn-down device — is what makes the
  # signature precise (a boot crash that left a real, recoverable error would not
  # have recursed on `standard_error`):
  #   * `terminating during boot` — the emulator's boot-time abort slogan.
  #   * `put_chars … standard_error` — the CLI reporter recursing on the torn-down
  #     `:standard_error` device (`{io,put_chars,[standard_error,…]}`, or the Elixir
  #     form `:io.put_chars(:standard_error, …)`). Requiring the `put_chars`
  #     neighbour, not a bare `standard_error` mention, keeps the marker to the
  #     self-erasing recursion: a deterministic boot break that printed a real error
  #     elsewhere, or any output that merely names the device, no longer matches
  #     (it degrades to a plain `:harness_error` — the safe direction).
  # Both appear in the truncated slogan binary and the captured banner alike. The
  # cause is unrecoverable from output (that's the whole point), so the runner says
  # so plainly and treats it as known-transient. Wording stable across OTP.
  @boot_during_startup ~r/terminating during boot/i
  @torn_down_standard_error ~r/put_chars.{0,8}standard_error/

  @typedoc "The remediation class of a Mix dependency-check failure."
  @type dependency_issue :: :fetch | :compile | :diverged | :unavailable | :invalid

  @doc """
  Classify a dependency-check failure in captured Mix output.

  Returns `nil` for output unrelated to dependencies. The categories deliberately
  follow Mix's own recommendations:

    * `:fetch` — the lock/source state requires `mix deps.get`;
    * `:compile` — sources exist but require `mix deps.compile`;
    * `:diverged` — dependency declarations conflict;
    * `:unavailable` — a non-fetchable dependency (normally a local/path dep) is
      missing from the sandbox's view of the filesystem;
    * `:invalid` — another status under Mix's unchecked-dependencies banner.

  The broad banner proves this is dependency validation, while the narrower
  recommendation phrases choose remediation. This keeps an arbitrary compiler
  error that merely mentions `mix deps.get` from being reclassified.
  """
  @spec dependency_issue(String.t()) :: dependency_issue() | nil
  def dependency_issue(output) when is_binary(output) do
    cond do
      Regex.match?(@diverged_dependencies, output) ->
        :diverged

      not Regex.match?(@unchecked_dependencies, output) ->
        nil

      String.contains?(output, "mix deps.get") ->
        :fetch

      String.contains?(output, "mix deps.compile") ->
        :compile

      String.contains?(output, "dependency is not available") ->
        :unavailable

      true ->
        :invalid
    end
  end

  # Compiler-diagnostic *headers*. Elixir prints each warning/error as a block headed
  # by one of these markers, the rest of the block (gutter, carets, `└─ file:line:col:`
  # footer) following until the next header. A raised compile exception (`** (…Error)`)
  # is the header of a hard failure. Read by `diagnostic_severity/1`.
  @error_marker ~r/^\s*error:/
  @exception_marker ~r/^\s*\*\* \(\w*Error\)/
  @warning_marker ~r/^\s*warning:/

  @doc """
  Regex for Mix's `== Compilation error in file <path> ==` banner.

  The regex captures `<path>` and is used by `suite_compile_error?/1`.
  """
  @spec compile_error_banner() :: Regex.t()
  def compile_error_banner, do: @compile_error_banner

  @doc """
  Regex for a `<file>:<line>` source reference in Mix output.

  It matches `.ex` and `.exs` paths such as `lib/foo.ex:5` or
  `test/foo_test.exs:42`, capturing the file and line. `Mutare.Poison` uses it
  to map compile errors back to mutant ids.
  """
  @spec source_location_regex() :: Regex.t()
  def source_location_regex, do: @source_location

  @doc """
  Regex for a `<test_file>:<line>` reference in Mix output.

  This narrows `source_location_regex/0` to `_test.exs` files. The baseline
  runner uses it to name tests involved in a flaky run.
  """
  @spec test_location_regex() :: Regex.t()
  def test_location_regex, do: @test_location

  @doc """
  Returns the diagnostic block started by a compiler-output line.

  The result is `:error` for an `error:` header or raised `** (…Error)`,
  `:warning` for a `warning:` header, and `nil` for any other line. Body,
  footer, and chatter lines inherit the previous header's severity in the caller.

  `Mutare.Poison` uses this to scan only non-warning lines for mutant locations.
  A failed metamutant compile can include warnings caused by mutations, and those
  warnings carry the same `file:line` footer shape as real errors. Separating the
  diagnostic blocks keeps warning locations from being treated as poison.
  """
  @spec diagnostic_severity(String.t()) :: :error | :warning | nil
  def diagnostic_severity(line) when is_binary(line) do
    cond do
      Regex.match?(@error_marker, line) -> :error
      Regex.match?(@exception_marker, line) -> :error
      Regex.match?(@warning_marker, line) -> :warning
      true -> nil
    end
  end

  @doc """
  Returns whether `output` reports a Mix compilation error in a test script.

  This identifies a mutation that broke test-suite compilation. It matches the
  `compile_error_banner/0` only when the captured path is a `.exs` file under a
  `test/` directory. Lib-file errors and output without the banner return `false`.
  """
  @spec suite_compile_error?(String.t()) :: boolean()
  def suite_compile_error?(output) when is_binary(output) do
    case Regex.run(compile_error_banner(), output) do
      [_, file] -> test_script?(file)
      nil -> false
    end
  end

  # A re-evaluated test script: a `.exs` under a `test/` directory (covers an
  # umbrella's `apps/<app>/test/…` too). Lib sources are `.ex` and compiled once
  # at baseline, so they never produce a per-mutant compile error here.
  defp test_script?(file) do
    String.ends_with?(file, ".exs") and "test" in Path.split(file)
  end

  @doc """
  Returns whether `output` shows the BEAM aborting because the atom table filled.

  This is the signature of a mutation that mints unbounded atoms. The runner
  treats that as a kill, like a timeout, because the suite cannot complete with
  the mutation active.

  This predicate only refines an otherwise-`:harness_error` exit in
  `Mutare.Sandbox.Command.outcome/2`; normal pass, fail, and timeout verdicts
  take precedence.
  """
  @spec atom_exhausted?(String.t()) :: boolean()
  def atom_exhausted?(output) when is_binary(output) do
    Regex.match?(@atom_table_exhausted, output)
  end

  @doc """
  Returns whether `output` matches the known boot-failure harness error.

  The signature is the emulator's `terminating during boot` message paired with a
  secondary `:standard_error` failure. The original diagnostic is usually gone by
  then, and the common cause is resource or connection contention while concurrent
  workers start.

  The runner still records this as `:harness_error`, but it can show a more useful
  message and use the dedicated boot-failure retry budget. This predicate only
  refines an otherwise-`:harness_error` exit; normal pass, fail, and timeout
  verdicts take precedence.
  """
  @spec boot_failure?(String.t()) :: boolean()
  def boot_failure?(output) when is_binary(output) do
    Regex.match?(@boot_during_startup, output) and
      Regex.match?(@torn_down_standard_error, output)
  end

  # Chatter a `mix test` run prints on its way to anything interesting: compile
  # progress, ExUnit's seed/tag banner and `Finished in` footer, rows of progress
  # dots. Never the line that explains a failure. Read by `salient_line/1`, which
  # matches them against trimmed lines.
  @routine_prefixes [
    "Compiling ",
    "Generated ",
    "Running ExUnit with seed:",
    "Excluding tags:",
    "Including tags:",
    "Finished in "
  ]
  @progress_dots ~r/^\.+$/

  # Line starts that head a failure: a raised exception or exit (`** (RuntimeError)`,
  # `** (Mix)`, `** (EXIT from …)`) and a failed application start. `salient_line/1`
  # also counts the `error:` header, the dependency-check banners, and the boot-abort
  # slogan as failure heads, through their patterns above.
  @failure_prefixes ["** (", "Could not start application"]

  @doc """
  Returns the captured-output line most likely to explain a failed run, or `nil`.

  Blank lines and routine chatter (compile progress, ExUnit's seed/tag banner,
  progress dots, the `Finished in` footer) are skipped. Of what remains, the first
  line that heads a failure wins — a raised `** (…)`, an `error:` header, a
  dependency-check banner, a failed application start, a boot abort — else the
  first remaining line. Lines come back trimmed.

  `Mutare.Report.HarnessDiagnostic` uses it to summarise a `:harness_error` in one
  line; no verdict depends on it.
  """
  @spec salient_line(String.t()) :: String.t() | nil
  def salient_line(output) when is_binary(output) do
    lines =
      output
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or routine_line?(&1)))

    Enum.find(lines, &failure_head?/1) || List.first(lines)
  end

  defp routine_line?(line) do
    String.starts_with?(line, @routine_prefixes) or Regex.match?(@progress_dots, line)
  end

  defp failure_head?(line) do
    String.starts_with?(line, @failure_prefixes) or
      Regex.match?(@error_marker, line) or
      Regex.match?(@unchecked_dependencies, line) or
      Regex.match?(@diverged_dependencies, line) or
      Regex.match?(@boot_during_startup, line)
  end

  @doc """
  Return the last `lines` lines of captured Mix output.

  Used by baseline, coverage-probe, and Mix-task errors to show enough context
  without printing an entire suite run.
  """
  @spec output_tail(String.t(), pos_integer()) :: String.t()
  def output_tail(output, lines \\ 20) when is_binary(output) do
    output |> String.split("\n") |> Enum.take(-lines) |> Enum.join("\n")
  end
end
