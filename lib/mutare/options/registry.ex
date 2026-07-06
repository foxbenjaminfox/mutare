defmodule Mutare.Options.Registry do
  @moduledoc false
  # The single declarative source of truth for every *user-configurable* option.
  #
  # Each option is one `@specs` entry carrying everything the four call sites that used to each
  # know a fragment of the option now read from one place:
  #
  #   * `:default`  — its default value (drives `Mutare.Options`'s `defstruct`/`@keys`/`new/1`)
  #   * `:cli`      — the `OptionParser` switch shape for a **1:1 passthrough** flag, or `nil` when
  #                   the flag is exceptional/translated (handled in `Mutare.Config`) or has no flag.
  #                   Drives the Mix task's `@switches` and `Config`'s pass-through fold.
  #   * `:visible`  — whether it appears in `mix mutare --show-config`
  #   * `:show`     — a 1-arity `value -> String.t()` formatter for that `--show-config` row
  #   * `:validate` — a 1-arity validator returning the canonical value or raising `ArgumentError`
  #
  # Adding a typical option is then a *single* entry here (plus its validator), instead of the old
  # four synchronized edits across `options.ex`, the Mix task, `config.ex`, and `cli/info.ex` — which
  # is exactly how `--show-config` came to silently omit `partition_env`/`seed_app_build`/`quiet`/
  # `only_files`/`only_lines`.
  #
  # Only *configuration* lives here. The runtime-wiring fields (`project` + the live-progress hooks)
  # are **not** options — they live on `Mutare.Run.Context`, validated there.
  #
  # The validators that resolve through other modules (`Mutare.Mutators`/`Mutare.MacroRouting.Registry`/
  # `Mutare.UseExpansion`, `Invocation.reserved_env_names/0`, and the reporters' `Mutare.Options.formats/0`)
  # do so at *runtime*, inside the validator bodies — so there is no compile cycle with `Mutare.Options`
  # (which compile-depends on `defaults/0` here; this module never compile-depends on it).

  alias Mutare.Lifting
  alias Mutare.Sandbox.Command.Invocation

  # --- shared validator helpers --------------------------------------------

  # The scalar validators share one shape: return the value when a predicate holds, else raise an
  # `ArgumentError` naming the field. `validate!/3` is that shape; `validate_nullable!/3` additionally
  # lets `nil` through (an optional field). The `, got: <value>` suffix is appended here, so each
  # `msg` states only the requirement.
  defp validate!(value, pred, msg) do
    if pred.(value), do: value, else: raise(ArgumentError, "#{msg}, got: #{inspect(value)}")
  end

  defp validate_nullable!(nil, _pred, _msg), do: nil
  defp validate_nullable!(value, pred, msg), do: validate!(value, pred, msg)

  # Shared validation for the plain boolean fields: the `&is_boolean/1` predicate and the
  # "`:field` must be true or false" message live here once, so each boolean field's validator
  # is a one-line delegate carrying only its own option-semantics comment.
  defp validate_boolean!(field, value),
    do: validate!(value, &is_boolean/1, "#{inspect(field)} must be true or false")

  # --- per-field validators ------------------------------------------------

  defp validate_paths!(paths),
    do:
      validate!(
        paths,
        fn p -> is_list(p) and p != [] and Enum.all?(p, &is_binary/1) end,
        ":paths must be a non-empty list of path strings"
      )

  defp validate_exclude!(value),
    do:
      validate!(
        value,
        fn v -> is_list(v) and Enum.all?(v, &is_binary/1) end,
        ":exclude must be a list of strings"
      )

  # A `:mutators` list is resolved through the one `Mutare.Mutators` catalog into
  # `Mutare.Mutator.Spec`s, so the direct API (`Mutare.run/2`, `Options.new/1`)
  # resolves family atoms, accepts `{module, opts}` configured entries, and rejects
  # non-mutator modules exactly as the CLI/`.mutare.exs` path does. An already
  # resolved list passes through unchanged (resolution is idempotent).
  # `nil` is the internal "key omitted; let `Mutare.Transform` pick its default set"
  # sentinel. `Options.new/1` rejects explicit non-list values before this validator.
  # `resolve/1` raises a descriptive "unknown mutator" error on a bad entry; the
  # fallback keeps a clear accepted-shapes message for an outright wrong value.
  defp validate_mutators!(nil), do: nil

  defp validate_mutators!(mutators) when is_list(mutators),
    do: Mutare.Mutators.resolve(mutators)

  defp validate_mutators!(other) do
    raise ArgumentError,
          ":mutators must be omitted or set to a list of mutators, got: #{inspect(other)}"
  end

  # Resolve and validate `:macro_routes` through `Mutare.MacroRouting.Registry` into `Mutare.Macro.Spec`s. The
  # resolution is purely syntactic (no reflection), so an entry naming a module that is not a
  # dependency of the Mutare process (e.g. `Ecto.Query`) is accepted. `nil`/absent means none;
  # the built-ins (`Kernel.match?`/`destructure`) and mutator-provided macros are merged later,
  # in `Mutare.Transform`. `Mutare.MacroRouting.Registry.resolve/1` raises a descriptive error on a bad entry.
  defp validate_macro_routes!(nil), do: []

  defp validate_macro_routes!(macros) when is_list(macros),
    do: Mutare.MacroRouting.Registry.resolve(macros)

  defp validate_macro_routes!(other) do
    raise ArgumentError, ":macro_routes must be a list of macro entries, got: #{inspect(other)}"
  end

  defp validate_skip_lifting!(entries), do: Lifting.validate_skip_lifting!(entries)

  # `:extensions` (default `[]`) lists non-mutating modules implementing `Mutare.MacroRouting`,
  # `Mutare.UseExpansion`, or both, e.g. a Gettext integration. Each entry is a bare module or a
  # `{module, opts}` pair (opts delivered to `expand_use/3`'s context), resolved to a
  # `Mutare.Extension.Spec`; the module must be a loaded extension. Resolution is by reflection (a
  # module *is* on the Mutare process path, unlike a `:macro_routes` module which is only
  # named). `Mutare.Extension.validate!/1` is the single home for the check — shared with
  # `Mutare.Transform`, so a non-extension fails loudly on either entry path. Extensions are not
  # mutators — they make the built-in mutators' work land, never produce mutations themselves.
  # An explicit `nil` (like `:macro_routes`) means "none", coerced to `[]` rather than raising.
  defp validate_extensions!(nil), do: []
  defp validate_extensions!(extensions), do: Mutare.Extension.validate!(extensions)

  # `:expand_uses` (default `true`) toggles the `use`-expansion pre-pass
  # (`Mutare.Transform.Uses`) that surfaces `import`/`alias` hidden behind `use`. `false`
  # freezes the pre-expansion behaviour (e.g. to debug or pin mutant counts).
  defp validate_expand_uses!(value), do: validate_boolean!(:expand_uses, value)

  defp validate_only_files!(nil), do: nil
  defp validate_only_files!(%MapSet{} = set), do: set
  defp validate_only_files!(list) when is_list(list), do: MapSet.new(list)

  defp validate_only_files!(other) do
    raise ArgumentError,
          ":only_files must be a MapSet, a list of paths, or nil, got: #{inspect(other)}"
  end

  # `:only_lines` (the `--line FILE:LINE` filter) scopes the *run* to the mutants on
  # specific `file:line` locations — a narrow rerun, e.g. to recheck one survivor the
  # report named. A `MapSet`/list of `{file, line}` pairs, normalised to a `MapSet`;
  # `nil` means no line filter. The `file` is a root-relative path (as shown in the
  # report) and `line` a positive integer, validated per entry so a bad pair fails at
  # the edge rather than silently matching nothing deep in `Mutare.Schema`.
  defp validate_only_lines!(nil), do: nil
  defp validate_only_lines!(%MapSet{} = set), do: validate_line_entries!(set)
  defp validate_only_lines!(list) when is_list(list), do: validate_line_entries!(MapSet.new(list))

  defp validate_only_lines!(other) do
    raise ArgumentError,
          ":only_lines must be a MapSet, a list of {file, line} tuples, or nil, got: #{inspect(other)}"
  end

  defp validate_line_entries!(set) do
    Enum.each(set, fn
      {file, line} when is_binary(file) and file != "" and is_integer(line) and line > 0 ->
        :ok

      bad ->
        raise ArgumentError,
              ":only_lines entries must be {file, line} with a non-empty path string and a " <>
                "positive integer line, got: #{inspect(bad)}"
    end)

    set
  end

  defp validate_test_selection!(mode),
    do:
      validate!(
        mode,
        &(&1 in [:tests, :coverage, :full]),
        ":test_selection must be :tests, :coverage, or :full"
      )

  # `:workers` defaults to `nil`, resolved here to half `System.schedulers_online/0`
  # **clamped to 1..4** (the lone computed default), so the struct always carries a
  # concrete positive integer. Why that shape: each worker is a full `mix test` BEAM
  # that itself uses every scheduler, so a parallel suite already scales with the
  # machine on its own — extra workers only fill the utilization gaps one run leaves
  # (boot/app-start, IO waits, the small selected-test sets), and the workers needed
  # for that is a small constant, not a fraction of the cores. Past ~4 the
  # oversubscription inflates wall time toward the per-mutant cap and manufactures
  # provisional timeouts (NOTES "Parallel workers", "Timeouts — portable self-halt").
  # An explicit `nil` resolves the same way; any other non-positive value is rejected.
  defp validate_workers!(nil), do: System.schedulers_online() |> div(2) |> min(4) |> max(1)

  defp validate_workers!(workers),
    do: validate!(workers, &(is_integer(&1) and &1 > 0), ":workers must be a positive integer")

  # `:partition_env` (default `nil` = off) names an env var each concurrent worker
  # is given a distinct partition id under (e.g. `MIX_TEST_PARTITION`), so a
  # stateful suite can pick a per-worker database. A non-empty string enables it;
  # `nil` disables. It must also not collide with a name Mutare itself sets on the
  # sandbox `mix` (the partition entry is *appended* to that env, so a duplicate key
  # would silently clobber e.g. `MIX_ENV`). See `Mutare.Runner.Partitions`.
  defp validate_partition_env!(value) do
    name =
      validate_nullable!(
        value,
        &(is_binary(&1) and &1 != ""),
        ":partition_env must be a non-empty string (an env var name) or nil"
      )

    validate_nullable!(
      name,
      &(&1 not in Invocation.reserved_env_names()),
      ":partition_env must not name a variable Mutare reserves " <>
        "(#{Enum.join(Invocation.reserved_env_names(), ", ")})"
    )
  end

  defp validate_timeout!(ms),
    do:
      validate_nullable!(
        ms,
        &(is_integer(&1) and &1 > 0),
        ":timeout must be a positive integer (milliseconds) or nil"
      )

  # Generous by default (30 min): the cap exists to bound a *pathological* compile
  # (observed: orphaned metamutant compiles at multi-day ages, and a type-checker
  # cliff past 80 minutes — see NOTES), not to police a legitimately slow one. A
  # cold compile of a big target with unseeded deps is the slowest honest case and
  # stays far under it. `nil` disables the cap.
  defp validate_compile_timeout!(ms),
    do:
      validate_nullable!(
        ms,
        &(is_integer(&1) and &1 > 0),
        ":compile_timeout must be a positive integer (milliseconds) or nil"
      )

  # `nil` (the default) derives the cap from the per-mutant cap (×10 — see
  # `Mutare.Runner`); an explicit value overrides it, mirroring how `:timeout`
  # overrides the baseline derivation. There is no "uncapped" setting on purpose:
  # the cap exists so a pathological coverage capture degrades to run-all
  # selection instead of hanging the run at the probe stage (see
  # `Mutare.Runner.CoverageProbe`); a legitimately slow instrumented suite wants
  # a bigger number, not no bound.
  defp validate_probe_timeout!(ms),
    do:
      validate_nullable!(
        ms,
        &(is_integer(&1) and &1 > 0),
        ":probe_timeout must be a positive integer (milliseconds) or nil"
      )

  defp validate_multiplier!(multiplier),
    do:
      validate!(
        multiplier,
        &(is_number(&1) and &1 > 0),
        ":timeout_multiplier must be a positive number"
      )

  # `nil` (the default) sets no memory cap — the historical behavior. An integer
  # caps every BEAM process's heap in the sandbox's *runtime* runs (baseline,
  # coverage probe, per-mutant `mix test`; never the one metamutant compile) at
  # that many megabytes, so a mutation that allocates without bound dies as an
  # ordinary test failure instead of racing the kernel's OOM killer for the host.
  # See `Mutare.Sandbox.Command.Invocation.heap_cap_env/1` for the mechanism and
  # sizing guidance (the baseline validates the cap fits the suite).
  defp validate_max_heap!(mb),
    do:
      validate_nullable!(
        mb,
        &(is_integer(&1) and &1 > 0),
        ":max_heap_mb must be a positive integer (megabytes) or nil"
      )

  # At least one run — you always need a green check; N>1 re-runs the baseline to
  # catch a test that disagrees with itself (`Mutare.Runner.Baseline`).
  defp validate_baseline_runs!(n),
    do:
      validate!(
        n,
        &(is_integer(&1) and &1 >= 1),
        ":baseline_runs must be a positive integer (>= 1)"
      )

  # Retry an all-red baseline attempt before aborting. This is deliberately
  # separate from `:baseline_runs`: runs detect pass/fail disagreement, retries
  # survive a consistently-red attempt that may go green on the next try.
  defp validate_baseline_retries!(n),
    do:
      validate!(
        n,
        &(is_integer(&1) and &1 >= 0),
        ":baseline_retries must be a non-negative integer"
      )

  defp validate_kill_runs!(n),
    do:
      validate!(
        n,
        &(is_integer(&1) and &1 >= 1),
        ":kill_runs must be a positive integer (>= 1)"
      )

  # On by default: the per-mutant cap is scaled from an *uncontended* baseline, but
  # mutants run under parallel-worker contention, so a slow-but-finite run can
  # overrun the cap and record a false `:timeout` kill — hiding a true survivor.
  # Confirming each timeout with one sequential (uncontended) re-run keeps the
  # verdict honest; only genuinely hanging mutants pay the second cap
  # (`--no-confirm-timeouts` opts out). See `Mutare.Runner`.
  defp validate_confirm_timeouts!(value), do: validate_boolean!(:confirm_timeouts, value)

  defp validate_harness_retries!(n),
    do:
      validate!(
        n,
        &(is_integer(&1) and &1 >= 0),
        ":harness_retries must be a non-negative integer"
      )

  # nil disables the abort guard; otherwise a fraction (0.0..1.0) of the mutants
  # that *ran* — above it, the run aborts rather than report a hollowed-out score.
  defp validate_harness_error_rate!(rate),
    do:
      validate_nullable!(
        rate,
        &(is_number(&1) and &1 >= 0 and &1 <= 1),
        ":max_harness_error_rate must be a number between 0.0 and 1.0, or nil"
      )

  defp validate_sandbox!(path),
    do:
      validate_nullable!(
        path,
        &(is_binary(&1) and &1 != ""),
        ":sandbox must be a non-empty path string or nil"
      )

  defp validate_keep_sandbox!(value), do: validate_boolean!(:keep_sandbox, value)

  # When true (the default; `--no-seed-app-build` turns it off), a narrowed run seeds the
  # mutated app's own compiled `_build` so the one `mix compile` recompiles just the
  # metamutant file(s) — see `Mutare.Sandbox.Seed.app_build/4`. The escape hatch exists to
  # rule the optimisation out when diagnosing a surprising score, or to force a cold compile.
  defp validate_seed_app_build!(value), do: validate_boolean!(:seed_app_build, value)

  # When true (`--strict-ignores`), a `# mutare:ignore` directive that suppresses
  # no mutant fails the run instead of only warning (see
  # `Mutare.Ignore.ineffective/2`). Default `false` (warn only).
  defp validate_strict_ignores!(value), do: validate_boolean!(:strict_ignores, value)

  # When true (`--quiet`), the Mix task does not attach the live progress reporter
  # (`Mutare.Report.Live`), so nothing is written to stderr as the run proceeds —
  # for CI, or any time the live block is unwanted. The final report and any
  # machine outputs are unaffected. Default `false`. Inert in the direct API
  # (`Mutare.run/2` never starts `Live`); it only gates the Mix task's wiring.
  defp validate_quiet!(value), do: validate_boolean!(:quiet, value)

  # When true (`--verbose`), the Mix task starts the live reporter in verbose mode:
  # a permanent scrollback line for every mutant (with its duration) and a `✓` detail
  # note after each phase (compile time, baseline timing, coverage breakdown + cap,
  # worker count). The inverse UI knob to `:quiet`; `--quiet` wins when both are set
  # (a quiet run starts no reporter at all). Default `false`. Inert in the direct API
  # (`Mutare.run/2` never starts `Live`).
  defp validate_verbose!(value), do: validate_boolean!(:verbose, value)

  # nil means no cap (run every mutant); otherwise an upper bound on the number of
  # mutants tested. The cap is applied by `Mutare.Schema` (it truncates the site
  # list to the first N), so the metamutant still embeds every mutant — only the
  # run is bounded.
  defp validate_max_mutants!(n),
    do:
      validate_nullable!(
        n,
        &(is_integer(&1) and &1 > 0),
        ":max_mutants must be a positive integer or nil"
      )

  # nil means no cap (run every mutant); otherwise stop the per-mutant run once
  # this many *survivors* (`:survived` results) have been found. Unlike
  # `:max_mutants` (a schema cap on candidate *sites*), this is enforced in the
  # runner's per-mutant loop — every mutant is still compiled in, the run just
  # halts early once enough survivors surface. See `Mutare.Runner`.
  defp validate_max_survivors!(n),
    do:
      validate_nullable!(
        n,
        &(is_integer(&1) and &1 > 0),
        ":max_survivors must be a positive integer or nil"
      )

  defp validate_min_score!(score),
    do:
      validate_nullable!(
        score,
        &(is_number(&1) and &1 >= 0 and &1 <= 100),
        ":min_score must be a number between 0 and 100, or nil"
      )

  # nil disables the coverage-gap gate; otherwise this is an absolute count of
  # :no_coverage mutants allowed in a complete run. 0 means fail CI on any
  # uncovered mutant while preserving the score denominator.
  defp validate_max_no_coverage!(n),
    do:
      validate_nullable!(
        n,
        &(is_integer(&1) and &1 >= 0),
        ":max_no_coverage must be a non-negative integer or nil"
      )

  # Post-run CI gates for statuses deliberately kept out of the score. These do
  # not change the score semantics; they make “Mutare could not test this
  # meaningfully” actionable when a CI policy wants that to be fatal.
  defp validate_fail_on_poisoned!(value), do: validate_boolean!(:fail_on_poisoned, value)

  defp validate_fail_on_harness_error!(value),
    do: validate_boolean!(:fail_on_harness_error, value)

  # `:reporters` is the list of *output formats* (the single source of truth for
  # format validation). Distinct from `:reporter` (a `Mutare.Run.Context` hook). Input
  # accepts a bare format atom (stdout) or `{format, path | nil}`; the canonical struct
  # always stores the tuple form. The valid format set is `Mutare.Options.formats/0`
  # (read at runtime, so the formats can stay homed in `Mutare.Options`).
  defp validate_reporters!(reporters) when is_list(reporters) do
    Enum.map(reporters, &validate_reporter_entry!/1)
  end

  defp validate_reporters!(other) do
    raise ArgumentError,
          ":reporters must be a list of format atoms or {format, path | nil} tuples, " <>
            "got: #{inspect(other)}"
  end

  defp validate_reporter_entry!(entry) do
    formats = Mutare.Options.formats()

    case entry do
      format when is_atom(format) ->
        if format in formats, do: {format, nil}, else: bad_reporter_entry!(entry, formats)

      {format, path} ->
        if format in formats and (is_nil(path) or (is_binary(path) and path != "")),
          do: {format, path},
          else: bad_reporter_entry!(entry, formats)

      _ ->
        bad_reporter_entry!(entry, formats)
    end
  end

  @spec bad_reporter_entry!(term(), [atom()]) :: no_return()
  defp bad_reporter_entry!(entry, formats) do
    raise ArgumentError,
          ":reporters entries must be a format atom or {format, path | nil} with format in " <>
            "#{inspect(formats)}, got: #{inspect(entry)}"
  end

  # --- `--show-config` value formatters ------------------------------------

  # The generic formatter: a list inspects, a string is itself, anything else (atoms, numbers,
  # booleans) renders via interpolation. Specs override it only where today's output differs.
  defp show_value(nil), do: "nil"
  defp show_value(v) when is_list(v), do: inspect(v)
  defp show_value(v) when is_binary(v), do: v
  defp show_value(v), do: to_string(v)

  defp show_mutators(nil), do: "(all built-ins — see --list-mutators)"

  # `validate_mutators!/1` has already resolved this to `[Mutare.Mutator.Spec{}]`, so we
  # just read the names — no re-resolution, and no `rescue` masking a real bug.
  defp show_mutators(mutators), do: Enum.map_join(mutators, ", ", &to_string(&1.name))

  defp show_extensions([]), do: "(none)"

  defp show_extensions(extensions) do
    Enum.map_join(extensions, ", ", fn
      %Mutare.Extension.Spec{module: module, opts: []} -> inspect(module)
      %Mutare.Extension.Spec{module: module, opts: opts} -> "#{inspect(module)} #{inspect(opts)}"
    end)
  end

  defp show_reporters(reporters) do
    Enum.map_join(reporters, ", ", fn
      {format, nil} -> "#{format} (stdout)"
      {format, path} -> "#{format} (#{path})"
    end)
  end

  defp show_timeout(nil), do: "derived from baseline run"
  defp show_timeout(ms), do: to_string(ms)

  defp show_compile_timeout(nil), do: "uncapped"
  defp show_compile_timeout(ms), do: to_string(ms)

  defp show_probe_timeout(nil), do: "derived from the per-mutant cap"
  defp show_probe_timeout(ms), do: to_string(ms)

  defp show_cap(nil), do: "(no cap)"
  defp show_cap(n), do: to_string(n)

  defp show_gate(nil), do: "(no gate)"
  defp show_gate(n), do: to_string(n)

  defp show_sandbox(nil), do: "(throwaway temp dir)"
  defp show_sandbox(path), do: path

  defp show_partition_env(nil), do: "(off)"
  defp show_partition_env(name), do: name

  defp show_only_files(nil), do: "(all discovered files)"
  defp show_only_files(set), do: inspect(set)

  defp show_only_lines(nil), do: "(all lines)"
  defp show_only_lines(set), do: inspect(set)

  defp show_skip_lifting(set) do
    if MapSet.size(set) == 0, do: "(none)", else: Lifting.format(set)
  end

  # --- the registry --------------------------------------------------------

  @doc """
  Every option spec, in registry order.

  Ordered to reproduce the `--show-config` row order (visible entries), with the hidden scope /
  tuning fields slotted next to their relatives. The struct field order `Mutare.Options` derives
  follows this; it is cosmetic (structs are maps — nothing reads a field positionally).

  This is a function rather than a module attribute because the `:validate`/`:show` values are
  captures of this module's *private* functions, which a module attribute cannot hold (only a
  function body can capture a local). It is rebuilt per call — cheap map construction plus named-fun captures,
  and only called a handful of times per run (each `Options.new/1`, the CLI switch composition, a
  `--show-config`).

  Each entry is built by `spec/1` from a keyword list: `:key`, `:default`, and `:validate` are
  required; `:cli` defaults to `nil` (not a 1:1 passthrough flag — the exceptional ones live in
  `Mutare.Config`), `:visible` to `true` (every option currently shows in `--show-config`; the field
  is the declarative knob to hide one), and `:show` to the generic `show_value/1` formatter.
  """
  def specs do
    [
      spec(key: :paths, default: ["lib"], validate: &validate_paths!/1),
      spec(key: :exclude, default: [], validate: &validate_exclude!/1),
      spec(key: :mutators, default: nil, show: &show_mutators/1, validate: &validate_mutators!/1),
      spec(key: :macro_routes, default: [], validate: &validate_macro_routes!/1),
      spec(
        key: :skip_lifting,
        default: MapSet.new(),
        show: &show_skip_lifting/1,
        validate: &validate_skip_lifting!/1
      ),
      spec(
        key: :extensions,
        default: [],
        show: &show_extensions/1,
        validate: &validate_extensions!/1
      ),
      spec(key: :expand_uses, default: true, cli: :boolean, validate: &validate_expand_uses!/1),
      spec(
        key: :only_files,
        default: nil,
        show: &show_only_files/1,
        validate: &validate_only_files!/1
      ),
      spec(
        key: :only_lines,
        default: nil,
        show: &show_only_lines/1,
        validate: &validate_only_lines!/1
      ),
      spec(key: :test_selection, default: :tests, validate: &validate_test_selection!/1),
      spec(key: :workers, default: nil, cli: :integer, validate: &validate_workers!/1),
      spec(
        key: :partition_env,
        default: nil,
        show: &show_partition_env/1,
        validate: &validate_partition_env!/1
      ),
      spec(
        key: :timeout,
        default: nil,
        cli: :integer,
        show: &show_timeout/1,
        validate: &validate_timeout!/1
      ),
      spec(
        key: :timeout_multiplier,
        default: 3.0,
        cli: :float,
        validate: &validate_multiplier!/1
      ),
      spec(
        key: :compile_timeout,
        default: 1_800_000,
        cli: :integer,
        show: &show_compile_timeout/1,
        validate: &validate_compile_timeout!/1
      ),
      spec(
        key: :probe_timeout,
        default: nil,
        cli: :integer,
        show: &show_probe_timeout/1,
        validate: &validate_probe_timeout!/1
      ),
      spec(
        key: :max_heap_mb,
        default: nil,
        cli: :integer,
        show: &show_cap/1,
        validate: &validate_max_heap!/1
      ),
      spec(key: :baseline_runs, default: 1, cli: :integer, validate: &validate_baseline_runs!/1),
      spec(
        key: :baseline_retries,
        default: 0,
        cli: :integer,
        validate: &validate_baseline_retries!/1
      ),
      spec(key: :kill_runs, default: 1, cli: :integer, validate: &validate_kill_runs!/1),
      spec(
        key: :confirm_timeouts,
        default: true,
        cli: :boolean,
        validate: &validate_confirm_timeouts!/1
      ),
      spec(
        key: :harness_retries,
        default: 2,
        cli: :integer,
        validate: &validate_harness_retries!/1
      ),
      spec(
        key: :max_harness_error_rate,
        default: 0.5,
        cli: :float,
        validate: &validate_harness_error_rate!/1
      ),
      spec(
        key: :max_mutants,
        default: nil,
        cli: :integer,
        show: &show_cap/1,
        validate: &validate_max_mutants!/1
      ),
      spec(
        key: :max_survivors,
        default: nil,
        cli: :integer,
        show: &show_cap/1,
        validate: &validate_max_survivors!/1
      ),
      spec(
        key: :min_score,
        default: nil,
        cli: :float,
        show: &show_gate/1,
        validate: &validate_min_score!/1
      ),
      spec(
        key: :max_no_coverage,
        default: nil,
        cli: :integer,
        show: &show_gate/1,
        validate: &validate_max_no_coverage!/1
      ),
      spec(
        key: :fail_on_poisoned,
        default: false,
        cli: :boolean,
        validate: &validate_fail_on_poisoned!/1
      ),
      spec(
        key: :fail_on_harness_error,
        default: false,
        cli: :boolean,
        validate: &validate_fail_on_harness_error!/1
      ),
      spec(
        key: :strict_ignores,
        default: false,
        cli: :boolean,
        validate: &validate_strict_ignores!/1
      ),
      spec(
        key: :sandbox,
        default: nil,
        cli: :string,
        show: &show_sandbox/1,
        validate: &validate_sandbox!/1
      ),
      spec(
        key: :keep_sandbox,
        default: false,
        cli: :boolean,
        validate: &validate_keep_sandbox!/1
      ),
      spec(
        key: :seed_app_build,
        default: true,
        cli: :boolean,
        validate: &validate_seed_app_build!/1
      ),
      spec(key: :quiet, default: false, cli: :boolean, validate: &validate_quiet!/1),
      spec(key: :verbose, default: false, cli: :boolean, validate: &validate_verbose!/1),
      spec(
        key: :reporters,
        default: [{:human, nil}],
        show: &show_reporters/1,
        validate: &validate_reporters!/1
      )
    ]
  end

  # Build one spec, defaulting the optional facets so the common entry stays a single readable line.
  defp spec(fields) do
    %{
      key: Keyword.fetch!(fields, :key),
      default: Keyword.fetch!(fields, :default),
      validate: Keyword.fetch!(fields, :validate),
      cli: Keyword.get(fields, :cli, nil),
      visible: Keyword.get(fields, :visible, true),
      show: Keyword.get(fields, :show, &show_value/1)
    }
  end

  # --- accessors -----------------------------------------------------------

  @doc """
  The `key -> default` keyword list, in registry order — the single source `Mutare.Options` derives
  its `defstruct`, `@keys`, and `new/1` per-field defaults from.
  """
  def defaults, do: for(spec <- specs(), do: {spec.key, spec.default})

  @doc """
  The 1:1 passthrough CLI switches as an `OptionParser` keyword list — the options whose flag is a
  plain `--key`/`--no-key` rename. Composed into the Mix task's `@switches` alongside `Config`'s
  exceptional flags and the task's own project/inspect flags.
  """
  def cli_switches, do: for(%{key: k, cli: cli} <- specs(), cli != nil, do: {k, cli})

  @doc """
  The keys of the 1:1 passthrough flags — what `Mutare.Config` folds straight from parsed flags
  into the options keyword list (no translation).
  """
  def passthrough_keys, do: for(%{key: k, cli: cli} <- specs(), cli != nil, do: k)

  @doc """
  The `{label, value_string}` rows for `mix mutare --show-config`, in registry order — every visible
  option formatted by its `:show`. The caller (`Mutare.CLI.Info`) prepends the `target` row.

  Takes the `Mutare.Options` as a plain map (no `%Mutare.Options{}` pattern) on purpose: this module
  is `Mutare.Options`'s compile-time dependency (it derives its `defstruct` from `defaults/0`), so a
  struct pattern here would close a compile cycle.
  """
  def display_rows(options) when is_map(options) do
    for %{key: key, visible: true, show: show} <- specs() do
      {to_string(key), show.(Map.fetch!(options, key))}
    end
  end
end
