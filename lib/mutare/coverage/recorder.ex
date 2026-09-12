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

  The spliced expression (`record_ast/3`) is two nested short-circuits:

      case :erlang.==(mutare_active, 0) do
        true ->
          case :persistent_term.get(:mutare_track, false) do
            true -> <helper>.hit([<ids>])
            _ -> false
          end

        _ -> false
      end

    * per-mutant runs (a local id in the selected file, `:inactive` elsewhere)
      leave on the comparison with zero — ~zero hot-loop cost;
    * the baseline green run and Mutare's own unit tests (`:mutare_track` unset)
      leave on the persistent-term read — the helper is never *called*;
    * only the probe run (`MUTARE_COVERAGE` set → `:mutare_track` true,
      `mutare_active == 0`) records.

  They are `case`s, not `and`s: the record is spliced into the target's own modules,
  where a narrowed or replaced `Kernel` import would redefine `and` under it, and
  `:erlang.andalso` — the form `and` compiles to in a guard — is undefined in a body.
  A special form is the one thing no import can redirect. The comparison is an explicit
  `:erlang` call for the same reason, and it keeps the outer `case` from ever reading as a
  hoisted selector (`case mutare_active do`).

  Schema emission supplies a namespace to `record_ast/3`, producing
  `hit(namespace, local_ids)`. The helper keeps a seen-cache per namespace and
  qualifies an id as `{namespace, local_id}` only when recording it to ETS, so
  local id 1 in two files stays two hits; the dump groups local ids by namespace.
  `Mutare.Coverage` flattens them and maps them back to the current run's report
  ids before test selection.
  """

  alias Mutare.AST
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
  @test_table HelperTemplate.test_table()
  @wholefile_table HelperTemplate.wholefile_table()
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
  # So fixture emission and the *stand-in's* module name are configurable: `fixture_module/0` returns
  # `helper_module/0` unless `fixture_override_env/0` names another.
  # `Mutare.Sandbox.Command` sets that env var (to `suite_fixture_module/0`) on
  # every sandbox `mix`, so the suite-under-test's stand-in compiles under a private
  # name (`:mutare_cov__suite_fixture`) and never collides with the real helper the
  # sandbox writes. Harness-built metamutants and the bootstrap keep the real
  # helper (the override is unset there). Transforms built by the suite-under-test
  # call its private stand-in instead: fixture hits must not pollute the outer
  # probe with unrelated runtime ids and invalidate its coverage mapping.
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
  The helper used by emitted fixture code and Mutare's `test/support/mutare_cov.ex` stand-in.

  `helper_module/0` (`:mutare_cov`) unless `fixture_override_env/0` names another —
  the one knob self-hosting needs so the stand-in does not collide with the real
  helper the sandbox writes (see the constant's comment above).
  """
  @spec fixture_module() :: module()
  def fixture_module, do: Mutare.Env.atom(@fixture_override_env, @helper_module)

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
  Catch-all clause pattern that binds the selector subject to `var`.

  `Mutare.Transform` uses this instead of `_` so `record_ast/2` can read the
  active id without a second `:persistent_term` lookup. Pass the same per-file
  variable to this function and to `record_ast/2`.
  """
  @spec catch_all_pattern(atom()) :: Macro.t()
  def catch_all_pattern(var \\ @var_name), do: {var, [], nil}

  @doc """
  AST that records coverage for this selector's mutant ids.

  `Mutare.Transform` prepends this expression to a selector catch-all body. It
  records only when the selector is at baseline and the coverage probe has enabled
  tracking; see the moduledoc for the full gate.

  `var` must be the variable introduced by `catch_all_pattern/1`. The AST is
  built directly so it can share that binding and splice `ids` as a literal list
  of integers.

  `namespace` selects the helper's `hit/2` form; `nil` retains standalone `hit/1`.

  Literals use clean metadata (`Mutare.AST.literal/1`); a bare integer can render badly
  when this expression is emitted as a statement in a generated function body.

  The comparison is an explicit `:erlang` call (`Mutare.AST.erlang_call/2`) and the two
  short-circuits are nested `case`s: special forms and remote calls alone — never a
  `Kernel` operator, which a narrowed import could redefine, and never `:erlang.andalso`,
  which Elixir accepts only inside a guard (see the moduledoc). `record_var/1` recognises
  exactly this shape, so the two must move together.
  """
  @spec record_ast([pos_integer()], atom(), String.t() | nil) :: Macro.t()
  def record_ast(ids, var \\ @var_name, namespace \\ nil) when is_list(ids) do
    track_read =
      {{:., [], [:persistent_term, :get]}, [], [AST.literal(@track_key), AST.literal(false)]}

    args =
      if is_nil(namespace),
        do: [ids_literal(ids)],
        else: [AST.literal(namespace), ids_literal(ids)]

    hit_call = {{:., [], [fixture_module(), :hit]}, [], args}

    active_zero = AST.erlang_call(:==, [{var, [], nil}, AST.literal(0)])
    when_true(active_zero, when_true(track_read, hit_call))
  end

  # `case <condition> do true -> <body>; _ -> false end`: the body runs only when the condition
  # holds. `when_true_args/1` is its inverse.
  defp when_true(condition, body) do
    clauses = [
      {:->, [], [[AST.literal(true)], body]},
      {:->, [], [[{:_, [], nil}], AST.literal(false)]}
    ]

    {:case, [], [condition, [do: clauses]]}
  end

  # `{:ok, condition, body}` for a node `when_true/2` built, seen through the literal wrappers a
  # reparse adds (the `:do` key, the clause list, the `true`). The `_ -> false` arm is checked
  # by its head alone.
  defp when_true_args({:case, _meta, [condition, [{key, clauses}]]}) do
    with true <- AST.key_atom(key) == :do,
         [{:->, _, [[on], body]}, {:->, _, [[{:_, _, ctx}], _false]}] when is_atom(ctx) <-
           AST.unwrap_literal(clauses),
         true <- AST.unwrap_literal(on) do
      {:ok, condition, body}
    else
      _ -> :error
    end
  end

  defp when_true_args(_node), do: :error

  @doc """
  Return the dispatch variable read by a coverage record, or `nil`.

  This is the inverse of `record_ast/3`. A coverage record has this shape:

      case :erlang.==(<var>, 0) do
        true ->
          case :persistent_term.get(<track_key>, false) do
            true -> <helper>.hit(<ids>)
            _ -> false
          end

        _ -> false
      end

  `<var>` is the file's dispatch variable, possibly salted. The internal
  `<track_key>` read identifies a real coverage record, which is how
  `Mutare.Metamutant.pattern_subject?/2` tells a generated tupled-case wrapper from
  a source-level `case` that only looks similar.

  The helper call is not part of recognition; that keeps self-hosting helper-name
  overrides from changing the result. Literal `{:__block__, _, [literal]}`
  wrappers added during reparse are accepted.
  """
  @spec record_var(Macro.t()) :: atom() | nil
  def record_var(node) do
    with {:ok, active_zero, tracked} <- when_true_args(node),
         {:ok, [{var, _, ctx}, zero]} when is_atom(var) and is_atom(ctx) <-
           AST.erlang_call_args(active_zero, :==),
         0 <- AST.unwrap_literal(zero),
         {:ok, track_read, _hit} <- when_true_args(tracked),
         true <- track_read?(track_read) do
      var
    else
      _ -> nil
    end
  end

  defp track_read?({{:., _, [mod, :get]}, _, [key | _]}),
    do: AST.unwrap_literal(mod) == :persistent_term and AST.unwrap_literal(key) == @track_key

  defp track_read?(_), do: false

  # Build the ids list AST so `Sourceror.to_string` renders it as a list literal
  # (`[91, 92]`), never a charlist. A *bare* list of small integers triggers the
  # "small-int list is a charlist" heuristic (`[91, 92]` → `~c"[\\"`), whose
  # rendering can splice an unbalanced quote/backslash into the metamutant and
  # break its re-parse. Wrapping each id in a `:__block__` node leaves them
  # ordinary integers at compile time while keeping the rendered form a list.
  defp ids_literal(ids), do: Enum.map(ids, &{:__block__, [], [&1]})

  @doc """
  AST for the `@compile {:no_warn_undefined, {<helper>, :hit, 1}}` attribute.

  `Mutare.Transform` prepends this to every metamutant module body. Selector
  catch-alls call the generated coverage helper's `hit/1`; in an umbrella that
  helper can live in a generated sibling app, so the mutated app may compile before
  the helper and trigger a benign xref warning. The call resolves at runtime. This
  attribute suppresses only that compile-time warning and is harmless when the
  helper is compiled in the same app.
  """
  @spec no_warn_attr_ast(String.t() | nil) :: Macro.t()
  def no_warn_attr_ast(namespace \\ nil) do
    helper = fixture_module()
    arity = if is_nil(namespace), do: 1, else: 2

    quote do
      @compile {:no_warn_undefined, {unquote(helper), :hit, unquote(arity)}}
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
  Source for the dependency-free coverage helper written into the sandbox.

  The source comes from `Mutare.Coverage.HelperTemplate`, a normal
  compile-checked module. Only its `defmodule` line is rewritten to
  `helper_module/0` (`:mutare_cov`).

  The helper's `hit/1` writes coverage to shared ETS tables. Its `dump/1`
  callback, registered with `ExUnit.after_suite/1`, writes `dump_file/0` and
  maps each test module back to its source file.
  """
  @spec helper_source() :: String.t()
  def helper_source, do: @helper_source

  @doc """
  Setup AST prepended before the target's test helper.

  It is inert unless `env_var/0` is set. During the coverage probe it creates the
  ETS tables and enables the tracking flag before user helper code runs, so app
  startup and helper setup can be attributed. The tables are owned by the
  test-helper process, which outlives the suite run.
  """
  @spec setup_ast() :: Macro.t()
  def setup_ast do
    env_var = @env_var
    track_key = @track_key
    agg = @agg_table
    attr = @attr_table
    unlabeled_table = @unlabeled_table
    test_table = @test_table
    wholefile_table = @wholefile_table

    quote do
      if System.get_env(unquote(env_var)) not in [nil, ""] do
        # An umbrella runs every app's `test_helper.exs` in one BEAM, so the tables
        # must be created once and shared. Guard on the aggregate table's existence
        # (all are created together) so the second app's setup is a no-op rather
        # than an `:ets.new` `:badarg`.
        if :ets.whereis(unquote(agg)) == :undefined do
          for table <- [
                unquote(agg),
                unquote(attr),
                unquote(unlabeled_table),
                unquote(test_table),
                unquote(wholefile_table)
              ] do
            :ets.new(table, [:named_table, :public, :set, write_concurrency: true])
          end
        end

        :persistent_term.put(unquote(track_key), true)
      end
    end
  end

  @doc """
  After-suite AST appended after the target's test helper.

  `ExUnit.after_suite/1` requires ExUnit to be started, so the dump callback is
  registered after the user's helper even though coverage tracking starts before
  it.
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
end
