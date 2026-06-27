defmodule Mutare.Sandbox.Command.Output do
  @moduledoc """
  Read shapes out of a `mix` run's captured output.

  A mutant's exit code is the *primary* signal (`Mutare.Sandbox.Command` decodes
  it), but two jobs need to look *past* the code at the human-readable output:

    * **Refining a verdict.** Exit `1` is ambiguous — a genuine harness failure or
      a mutation that broke the test suite's own compilation — and a BEAM abort can
      land on any code. `suite_compile_error?/1`, `atom_exhausted?/1`, and
      `boot_failure?/1` are the pure discriminators `Mutare.Sandbox.Command.outcome/2`
      consults to split those cases (see that module's moduledoc for *why* each is
      the verdict it is).
    * **Locating a failure.** `Mutare.Poison` maps a failed metamutant compile back
      to mutant ids (`source_location_regex/0` + `diagnostic_severity/1`), and
      `Mutare.Runner.Baseline` names the tests in a flaky run (`test_location_regex/0`).

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

  # Compiler-diagnostic *headers*. Elixir prints each warning/error as a block headed
  # by one of these markers, the rest of the block (gutter, carets, `└─ file:line:col:`
  # footer) following until the next header. A raised compile exception (`** (…Error)`)
  # is the header of a hard failure. Read by `diagnostic_severity/1`.
  @error_marker ~r/^\s*error:/
  @exception_marker ~r/^\s*\*\* \(\w*Error\)/
  @warning_marker ~r/^\s*warning:/

  @doc """
  Regex matching mix's `== Compilation error in file <path> ==` banner, capturing
  `<path>`. Read here by `suite_compile_error?/1`; exposed so the banner has a
  single home.
  """
  @spec compile_error_banner() :: Regex.t()
  def compile_error_banner, do: @compile_error_banner

  @doc """
  Regex matching a `<file>:<line>` source reference in mix output (an `.ex`/`.exs`
  path and a line, e.g. `lib/foo.ex:5` or `test/foo_test.exs:42`), capturing the
  file and the line. `Mutare.Poison` scans it to map a compile error back to a
  mutant id; it lives here so mix's output shape has one home.
  """
  @spec source_location_regex() :: Regex.t()
  def source_location_regex, do: @source_location

  @doc """
  Regex matching a `<test_file>:<line>` reference in mix output — a narrowing of
  `source_location_regex/0` to `_test.exs` files, capturing the file and the line.
  `Mutare.Runner.Baseline` scans it to name the tests in a flaky run.
  """
  @spec test_location_regex() :: Regex.t()
  def test_location_regex, do: @test_location

  @doc """
  The diagnostic severity a compiler-output `line` *starts*: `:error` (an `error:`
  header or a raised `** (…Error)`), `:warning` (a `warning:` header), or `nil` (any
  other line — a diagnostic's body/footer, or chatter — which inherits its block's
  severity from the preceding header).

  `Mutare.Poison` threads this across the output so it scans only non-warning lines for
  mutant locations: a failed metamutant compile prints every warning the mutations
  provoked (an `unused variable` from a mutant forcing a guard to `true`, a
  `cannot match` from a widened clause), each footered with the same `file:line` shape
  `source_location_regex/0` matches — and mistaking those for the real error's location
  dropped valid mutants as false poison. Co-located with the other mix-output patterns
  so a diagnostic-format change is a single fix.
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
  Whether `output` reports a `mix` compilation error in a **test script** — the
  signature of a mutation that broke the test suite's compilation (see
  `Mutare.Sandbox.Command.outcome/2`). Matches the `compile_error_banner/0` only
  when the captured path is a `.exs` under a `test/` directory; a lib-file error or
  no banner is not one. Pure, so the discriminator is unit-testable.
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
  Whether `output` shows the BEAM aborting because the **atom table** filled — the
  signature of a mutation that mints unbounded atoms (see
  `Mutare.Sandbox.Command.outcome/2`). Such a run is a detected resource-divergence
  (the suite can never complete with it), so the runner treats it as a kill — like a
  timeout — rather than an infra failure.

  Matches only when the otherwise-`:harness_error` exit code is *also* paired with
  this VM-abort banner; a normal pass/fail/timeout verdict still wins in
  `Mutare.Sandbox.Command.outcome/2`. Pure, so the discriminator is unit-testable.
  """
  @spec atom_exhausted?(String.t()) :: boolean()
  def atom_exhausted?(output) when is_binary(output) do
    Regex.match?(@atom_table_exhausted, output)
  end

  @doc """
  Whether `output` shows the sandbox node **dying during boot** with its own
  diagnostic erased by a secondary `:standard_error` failure (see
  `Mutare.Sandbox.Command.outcome/2`). The signature is the emulator's
  `terminating during boot` abort slogan paired with the torn-down `standard_error`
  device the CLI reporter recursed on.

  Such a run is a harness error (the mutation says nothing — it is almost always
  resource/connection contention across concurrent workers at startup), but a
  *known-transient* one whose real cause is unrecoverable from output, so the
  runner messages it specifically and retries it harder. Matches only when the
  otherwise-`:harness_error` exit code is *also* paired with this banner; a normal
  pass/fail/timeout verdict still wins in `Mutare.Sandbox.Command.outcome/2`. Pure,
  so the discriminator is unit-testable.
  """
  @spec boot_failure?(String.t()) :: boolean()
  def boot_failure?(output) when is_binary(output) do
    Regex.match?(@boot_during_startup, output) and
      Regex.match?(@torn_down_standard_error, output)
  end

  @doc """
  The last `lines` lines of captured `mix` output — enough to point at a failure
  without dumping a whole suite run into an error message. The one home for "tail
  the output", shared by the baseline, the coverage probe, and the Mix task's
  error formatter (each picks its own `lines`).
  """
  @spec output_tail(String.t(), pos_integer()) :: String.t()
  def output_tail(output, lines \\ 20) when is_binary(output) do
    output |> String.split("\n") |> Enum.take(-lines) |> Enum.join("\n")
  end
end
