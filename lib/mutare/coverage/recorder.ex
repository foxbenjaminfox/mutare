defmodule Mutare.Coverage.Recorder do
  @moduledoc """
  The generated-code side of coverage capture: the contract the metamutant and
  the test bootstrap share to record coverage **synchronously, in the test
  process**, with no race.

  `Mutare.Coverage` reads what this produces; this module owns *how it is
  produced*. There are three pieces, all emitted into generated code:

    * `record_ast/1` — spliced by `Mutare.Transform` into every selector
      catch-all. At baseline, under a tracking flag, it records the site's mutant
      ids into shared ETS — in whatever process runs the line, including the test
      process. (`Mutare.Selector` owns the *selection* contract the same way.)
    * `helper_source/0` — a dependency-free helper module
      (`Mutare.Sandbox` writes it into the sandbox) holding the ETS writes and the
      end-of-suite dump, so the per-site code stays a single call and the
      OTP-version-tolerant label read lives in one place.
    * `setup_ast/0` and `after_suite_ast/0` — injected around the target's
      `test_helper.exs`; when the probe env var is set, setup creates the tables
      and flips the tracking flag before user helper code runs, while the
      after-suite hook is registered after the helper has started ExUnit.

  ## Why this, not `:cover`

  `:cover`'s counters live in a single global table keyed `{module, line}` — there
  is no per-process partition, so attributing coverage to a test in *one* run
  needs a snapshot at each test boundary, and the only global per-test signal
  ExUnit emits is an **async cast to formatters** that races test execution
  (fast `async: false` modules' coverage is lost). The metamutant, by contrast,
  *is* code we generate and that runs synchronously in the test process. So the
  capture lives there, accumulate-only (never reset), keyed by mutant id directly.

  ## The gate (why it is inert outside the probe)

  The spliced expression is `mutare_active == 0 and
  :persistent_term.get(:mutare_track, false) and <helper>.hit([<ids>])`:

    * per-mutant runs (`mutare_active != 0`) short-circuit on the integer compare —
      ~zero hot-loop cost;
    * the baseline green run and Mutare's own unit tests (`:mutare_track` unset)
      short-circuit on the persistent-term read — the helper is never *called*;
    * only the probe run (`MUTARE_COVERAGE` set → `:mutare_track` true,
      `mutare_active == 0`) records.

  The helper's `hit/1` returns `true` so the `and` chain stays boolean (an `:ets`
  call returns an int/`true` and would raise `BadBooleanError` mid-`and`).
  """

  alias Mutare.Coverage.HelperTemplate

  @env_var "MUTARE_COVERAGE"
  @track_key :mutare_track

  # The table names, dump file, and umbrella-path env vars the dependency-free helper reads/writes
  # are owned by `HelperTemplate` (the helper's source) and sourced from there, so the bootstrap
  # that *creates* the tables (`setup_ast/0`) and the dump reader (`Mutare.Coverage`) can never
  # drift from the helper that *writes* them.
  @agg_table HelperTemplate.agg_table()
  @attr_table HelperTemplate.attr_table()
  @unlabeled_table HelperTemplate.unlabeled_table()
  @dump_file HelperTemplate.dump_file()
  @helper_module :mutare_cov

  # An umbrella runs each app's suite with cwd = that app's dir, so the dump must
  # be written to (and the test-file paths normalised against) absolute locations
  # the probe controls, not cwd-relative ones. The probe sets these; the helper
  # reads them, falling back to the cwd-relative behaviour when unset (single app).
  # (Owned by `HelperTemplate`, like the table names above.)
  @dump_path_env HelperTemplate.dump_path_env()
  @root_env HelperTemplate.root_env()

  # Self-hosting isolation for the helper module name, mirroring
  # `Mutare.Selector`'s private selection key. When the target *is* Mutare, the
  # sandbox holds **two** definitions of the helper module: the real one
  # `Mutare.Sandbox` writes (`helper_module/0`, with `dump/1`) *and* Mutare's own
  # `test/support/mutare_cov.ex` test stand-in. Two modules with the same atom name
  # is a "redefining module" clash — the stand-in (which has no `dump/1`) can win,
  # and the probe's `after_suite(&:mutare_cov.dump/1)` then raises
  # `UndefinedFunctionError`, collapsing coverage to run-all (see NOTES,
  # "Self-hosting coverage").
  #
  # So the *stand-in's* module name is configurable: `fixture_module/0` returns
  # `helper_module/0` unless `fixture_override_env/0` names another.
  # `Mutare.Sandbox.Command` sets that env var (to `suite_fixture_module/0`) on
  # every sandbox `mix`, so the suite-under-test's stand-in compiles under a private
  # name (`:mutare_cov__suite_fixture`) and never collides with the real helper the
  # sandbox writes. The real helper, the metamutant's baked `hit/1` calls, and the
  # bootstrap all keep `helper_module/0` (the override is unset in the harness
  # process, and a normal target has no stand-in compiled in, so this is inert).
  @fixture_override_env "MUTARE_COV_FIXTURE_MODULE"
  @suite_fixture_module "mutare_cov__suite_fixture"

  # The canonical name the catch-all binds the selector subject to, so the coverage
  # record can reuse it (no second `:persistent_term` read). It is only a *default*:
  # `Mutare.Transform` passes a per-file, collision-free name (salted away from a
  # source identifier of the same name) into `catch_all_pattern/1` and `record_ast/2`,
  # and the catch-all pattern and the record's gate must always agree on it.
  @var_name :mutare_active

  @doc "Env var the probe sets to turn coverage recording on for one run."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc "The `:persistent_term` flag the spliced record reads (`false` by default)."
  @spec track_key() :: atom()
  def track_key, do: @track_key

  @doc "The file (relative to the sandbox) the end-of-suite dump is written to."
  @spec dump_file() :: String.t()
  def dump_file, do: @dump_file

  @doc "Env var the probe sets to the absolute path the dump is written to."
  @spec dump_path_env() :: String.t()
  def dump_path_env, do: @dump_path_env

  @doc "Env var the probe sets to the absolute root test-file paths are relative to."
  @spec root_env() :: String.t()
  def root_env, do: @root_env

  @doc "The dependency-free helper module emitted into the sandbox."
  @spec helper_module() :: module()
  def helper_module, do: @helper_module

  @doc """
  The module name Mutare's `test/support/mutare_cov.ex` stand-in defines itself as.

  `helper_module/0` (`:mutare_cov`) unless `fixture_override_env/0` names another —
  the one knob self-hosting needs so the stand-in does not collide with the real
  helper the sandbox writes (see the constant's comment above).
  """
  @spec fixture_module() :: module()
  def fixture_module do
    case System.get_env(@fixture_override_env) do
      nil -> @helper_module
      "" -> @helper_module
      name -> String.to_atom(name)
    end
  end

  @doc "Env var a sandbox run sets to give the suite-under-test's stand-in a private module name."
  @spec fixture_override_env() :: String.t()
  def fixture_override_env, do: @fixture_override_env

  @doc "The private stand-in module name (`fixture_override_env/0`'s value) used under dogfooding."
  @spec suite_fixture_module() :: String.t()
  def suite_fixture_module, do: @suite_fixture_module

  @doc "The canonical selector-subject variable name (`:mutare_active`); the default `var`."
  @spec var_name() :: atom()
  def var_name, do: @var_name

  @doc """
  The catch-all clause pattern that binds the selector subject to `var` (default
  `mutare_active`).

  `Mutare.Transform` uses this in place of the old `_` so `record_ast/2` can read
  the active id without a second `:persistent_term` lookup — passing the same
  per-file `var` to both.
  """
  @spec catch_all_pattern(atom()) :: Macro.t()
  def catch_all_pattern(var \\ @var_name), do: {var, [], nil}

  @doc """
  The expression `Mutare.Transform` prepends to a catch-all body to record that
  this selector's mutant `ids` ran (see the moduledoc for the gate).

  Hand-built (not `quote`d) to share the `var` binding `catch_all_pattern/1`
  introduces (the same per-file name must be passed to both) and to splice `ids` as
  a literal list of integers.

  Literal args carry clean (empty) metadata — the `0` especially: a *bare* integer
  makes Sourceror's normalizer assign it a `:line` but no `:token`, which crashes
  the Elixir formatter when this expression is rendered as a statement in a `def`
  body (a lifted dispatcher's coverage record). Clean-meta `{:__block__, [], [lit]}`
  renders via the inspect path in any position (the same rule literal mutators
  follow — see CLAUDE.md).
  """
  @spec record_ast([pos_integer()], atom()) :: Macro.t()
  def record_ast(ids, var \\ @var_name) when is_list(ids) do
    active_zero = {:==, [], [{var, [], nil}, literal(0)]}
    track_read = {{:., [], [:persistent_term, :get]}, [], [literal(@track_key), literal(false)]}
    hit_call = {{:., [], [@helper_module, :hit]}, [], [ids_literal(ids)]}

    {:and, [], [{:and, [], [active_zero, track_read]}, hit_call]}
  end

  @doc """
  The dispatch variable a coverage record reads — the inverse of `record_ast/2` — or
  `nil` when `node` is not a coverage record.

  A coverage record is `<var> == 0 and :persistent_term.get(<track_key>, false) and
  <helper>.hit(<ids>)`, so its `<var>` is this metamutant's per-file (possibly salted)
  dispatch name. The embedded `<track_key>` read (`:mutare_track`) is internal — a
  target's own source can't forge it — so this is the *unambiguous* way to recover the
  dispatch name from a rendered metamutant: it is uniform across the file (every record
  reads the same name) and present wherever a hoisted selector or lifted gate uses the
  variable. `Mutare.Manifest` recovers the name from it in preference to a `<var> =
  :persistent_term.get(...)` binding, which a source file could itself write (with a
  same-family name, masking the real salted one).

  The `<helper>.hit(...)` arm is ignored — only the unforgeable `<track_key>` arm is
  matched — so a self-hosting helper-module override does not affect recognition.
  Tolerant of the `{:__block__, _, [literal]}` wrapping a literal-encoding re-parse
  adds to the `0` / `<track_key>` literals.
  """
  @spec record_var(Macro.t()) :: atom() | nil
  def record_var({:and, _, [{:and, _, [active_zero, track_read]}, _hit]}) do
    if track_read?(track_read), do: active_zero_var(active_zero)
  end

  def record_var(_), do: nil

  defp track_read?({{:., _, [mod, :get]}, _, [key | _]}),
    do: unwrap(mod) == :persistent_term and unwrap(key) == @track_key

  defp track_read?(_), do: false

  defp active_zero_var({:==, _, [{var, _, ctx}, zero]})
       when is_atom(var) and is_atom(ctx),
       do: if(unwrap(zero) == 0, do: var)

  defp active_zero_var(_), do: nil

  # See through a literal-encoding re-parse's `{:__block__, _, [literal]}` wrapping;
  # a bare literal passes through untouched.
  defp unwrap({:__block__, _meta, [literal]}), do: literal
  defp unwrap(other), do: other

  defp literal(value), do: {:__block__, [], [value]}

  # Build the ids list AST so `Sourceror.to_string` renders it as a list literal
  # (`[91, 92]`), never a charlist. A *bare* list of small integers triggers the
  # "small-int list is a charlist" heuristic (`[91, 92]` → `~c"[\\"`), whose
  # rendering can splice an unbalanced quote/backslash into the metamutant and
  # break its re-parse. Wrapping each id in a `:__block__` node leaves them
  # ordinary integers at compile time while keeping the rendered form a list.
  defp ids_literal(ids), do: Enum.map(ids, &{:__block__, [], [&1]})

  @doc """
  The `@compile {:no_warn_undefined, {<helper>, :hit, 1}}` attribute
  `Mutare.Transform` prepends to every metamutant module body.

  Each module's selector catch-alls call the coverage helper's `hit/1` (see
  `record_ast/1`). In an umbrella the helper lives in a generated sibling app the
  mutated app declares no dep on, so `mix` may compile the caller before the
  helper and the compiler's xref check draws a benign "undefined function"
  warning. The call still resolves at runtime; this attribute suppresses only the
  compile-time check, and is a harmless no-op where the helper is co-compiled (a
  single-app target, which never warns) — so `Transform` can emit it
  unconditionally.
  """
  @spec no_warn_attr_ast() :: Macro.t()
  def no_warn_attr_ast do
    helper = @helper_module

    quote do
      @compile {:no_warn_undefined, {unquote(helper), :hit, 1}}
    end
  end

  @template_path Path.join(__DIR__, "helper_template.ex")
  @external_resource @template_path
  @helper_template_source File.read!(@template_path)

  # Rename the template module to `helper_module/0` by replacing its `defmodule` *declaration
  # line* — not the bare module name — so the name may also appear in the template's
  # comments/docs/strings without being silently rewritten too. Splitting on the anchor and
  # matching exactly two parts asserts a single occurrence at *Mutare's* compile time: if the
  # template's first line ever changes, this fails here rather than emitting a helper that
  # won't compile in the sandbox.
  @helper_defmodule_anchor "defmodule Mutare.Coverage.HelperTemplate do"
  @helper_source (case String.split(@helper_template_source, @helper_defmodule_anchor) do
                    [before, rest] ->
                      before <> "defmodule #{inspect(@helper_module)} do" <> rest

                    _ ->
                      raise "Mutare.Coverage.HelperTemplate: expected exactly one " <>
                              "#{inspect(@helper_defmodule_anchor)} line in the template source"
                  end)

  @doc """
  Source of the dependency-free coverage helper `Mutare.Sandbox` writes into the sandbox
  (compiled once, with the app). It is `Mutare.Coverage.HelperTemplate`'s own source — a real,
  compile-checked module, not a stringified `quote` — with its `defmodule` line rewritten to
  `helper_module/0` (`:mutare_cov`).

  `hit/1` records into the shared ETS tables; `dump/1` (run by `after_suite`) serialises them to
  `dump_file/0`, mapping each test module to its source file.
  """
  @spec helper_source() :: String.t()
  def helper_source, do: @helper_source

  @doc """
  The setup snippet `Mutare.Sandbox` prepends before the target's test helper.

  Inert unless `env_var/0` is set: only the probe run creates the tables and sets
  the tracking flag. This runs before user helper code so coverage caused by app
  startup or helper setup is not missed. The tables are owned by the test-helper
  process, which hosts the `at_exit` suite run and so outlives it.
  """
  @spec setup_ast() :: Macro.t()
  def setup_ast do
    env_var = @env_var
    track_key = @track_key
    agg = @agg_table
    attr = @attr_table
    unlabeled_table = @unlabeled_table

    quote do
      if System.get_env(unquote(env_var)) not in [nil, ""] do
        # An umbrella runs every app's `test_helper.exs` in one BEAM, so the tables
        # must be created once and shared. Guard on the aggregate table's existence
        # (all are created together) so the second app's setup is a no-op rather
        # than an `:ets.new` `:badarg`.
        if :ets.whereis(unquote(agg)) == :undefined do
          :ets.new(unquote(agg), [:named_table, :public, :set, write_concurrency: true])
          :ets.new(unquote(attr), [:named_table, :public, :set, write_concurrency: true])

          :ets.new(unquote(unlabeled_table), [
            :named_table,
            :public,
            :set,
            write_concurrency: true
          ])
        end

        :persistent_term.put(unquote(track_key), true)
      end
    end
  end

  @doc """
  The after-suite snippet `Mutare.Sandbox` appends after the target's test helper.

  `ExUnit.after_suite/1` requires ExUnit to have been started, so registration
  stays after the user's helper even though coverage tracking starts before it.
  """
  @spec after_suite_ast() :: Macro.t()
  def after_suite_ast do
    env_var = @env_var
    helper = @helper_module

    quote do
      if System.get_env(unquote(env_var)) not in [nil, ""] do
        ExUnit.after_suite(&unquote(helper).dump/1)
      end
    end
  end

  @doc """
  Combined coverage bootstrap kept for callers that do not need to split setup
  from after-suite registration.
  """
  @spec bootstrap_ast() :: Macro.t()
  def bootstrap_ast do
    quote do
      unquote(setup_ast())
      unquote(after_suite_ast())
    end
  end
end
