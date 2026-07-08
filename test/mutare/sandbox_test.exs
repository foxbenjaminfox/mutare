defmodule Mutare.SandboxTest do
  use ExUnit.Case, async: true

  alias Mutare.{Project, Sandbox, Schema}
  alias Mutare.Test.Umbrella

  setup do
    base =
      Path.join(System.tmp_dir!(), "mutare_sandbox_test_#{System.unique_integer([:positive])}")

    project = Path.join(base, "project")
    marker = Path.join(project, "keep.txt")

    File.mkdir_p!(project)
    File.write!(marker, "keep")

    on_exit(fn -> File.rm_rf!(base) end)

    %{base: base, marker: marker, project: project, schema: %Schema{}}
  end

  test "rejects the project root before deleting anything", context do
    assert_unsafe(context.project, context.project, context.schema, "is the project root")
    assert File.read!(context.marker) == "keep"
  end

  test "rejects a sandbox inside the project before deleting anything", context do
    sandbox = Path.join(context.project, "sandbox")
    sandbox_marker = Path.join(sandbox, "keep.txt")
    File.mkdir_p!(sandbox)
    File.write!(sandbox_marker, "keep")

    assert_unsafe(context.project, sandbox, context.schema, "is inside the project root")
    assert File.read!(sandbox_marker) == "keep"
  end

  test "rejects a sandbox that contains the project before deleting anything", context do
    assert_unsafe(context.project, context.base, context.schema, "contains the project root")
    assert File.read!(context.marker) == "keep"
  end

  test "resolves symlinked parents when checking for a nested sandbox", context do
    project_alias = Path.join(context.base, "project_alias")
    :ok = File.ln_s(context.project, project_alias)

    sandbox = Path.join(project_alias, "sandbox")

    assert_unsafe(context.project, sandbox, context.schema, "is inside the project root")
    assert File.read!(context.marker) == "keep"
  end

  test "checks where a final symlink will be replaced after deletion", context do
    outside = Path.join(context.base, "outside")
    sandbox = Path.join(context.project, "sandbox_link")
    File.mkdir_p!(outside)
    :ok = File.ln_s(outside, sandbox)

    assert_unsafe(context.project, sandbox, context.schema, "is inside the project root")
    assert File.read_link!(sandbox) == outside
  end

  test "allows a sibling sandbox", context do
    sandbox = Path.join(context.base, "sandbox")

    assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox
    assert File.read!(Path.join(sandbox, "keep.txt")) == "keep"
  end

  @marker ".mutare_sandbox"
  @lock ".mutare_sandbox.lock"

  test "creates the sandbox and leaves an ownership marker when it is absent", context do
    sandbox = Path.join(context.base, "sandbox")
    refute File.exists?(sandbox)

    assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox
    assert File.read!(Path.join(sandbox, "keep.txt")) == "keep"
    assert File.regular?(Path.join(sandbox, @marker))
  end

  test "acquires and releases an internal lock for an explicit sandbox", context do
    sandbox = Path.join(context.base, "sandbox")

    lock = Sandbox.acquire_lock(context.project, sandbox: sandbox)
    lock_dir = Path.join(sandbox, @lock)

    assert File.dir?(lock_dir)
    assert File.read!(Path.join(lock_dir, "owner")) =~ "pid=#{System.pid()}"

    assert :ok = Sandbox.release_lock(lock)
    refute File.exists?(lock_dir)
  end

  test "refuses a reusable sandbox while its internal lock owner is live", context do
    sandbox = Path.join(context.base, "sandbox")
    lock = Sandbox.acquire_lock(context.project, sandbox: sandbox)

    try do
      assert_raise ArgumentError, ~r/already in use by Mutare process #{System.pid()}/, fn ->
        Sandbox.acquire_lock(context.project, sandbox: sandbox)
      end
    after
      Sandbox.release_lock(lock)
    end
  end

  test "reclaims an internal lock whose recorded pid is gone", context do
    sandbox = Path.join(context.base, "sandbox")
    lock_dir = Path.join(sandbox, @lock)
    File.mkdir_p!(lock_dir)

    File.write!(
      Path.join(lock_dir, "owner"),
      "host=\npid=99999999\nstart_time=\ntoken=dead\n"
    )

    lock = Sandbox.acquire_lock(context.project, sandbox: sandbox)

    try do
      assert File.read!(Path.join(lock_dir, "owner")) =~ "pid=#{System.pid()}"
    after
      Sandbox.release_lock(lock)
    end
  end

  test "does not create a lock inside a non-empty unowned sandbox path", context do
    sandbox = Path.join(context.base, "sandbox")
    bystander = Path.join(sandbox, "important.txt")
    File.mkdir_p!(sandbox)
    File.write!(bystander, "precious")

    assert_refused_lock(context.project, sandbox)
    assert File.read!(bystander) == "precious"
    refute File.exists?(Path.join(sandbox, @lock))
  end

  test "preserves the active internal lock when resetting an owned explicit sandbox", context do
    sandbox = Path.join(context.base, "sandbox")
    assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox
    stale = Path.join(sandbox, "stale.txt")
    File.write!(stale, "stale")

    lock = Sandbox.acquire_lock(context.project, sandbox: sandbox)
    lock_dir = Path.join(sandbox, @lock)

    try do
      assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox
      assert File.dir?(lock_dir)
      refute File.exists?(stale)
      assert File.read!(Path.join(sandbox, "keep.txt")) == "keep"
    after
      Sandbox.release_lock(lock)
    end
  end

  test "auto-generates a fresh sandbox path salted with the OS pid", context do
    # No explicit `:sandbox` → a throwaway temp dir. `System.unique_integer/1`
    # repeats across BEAM instances, so the OS pid is what keeps two concurrent
    # `mix mutare` runs from colliding on the same path (and wiping each other).
    sandbox = Sandbox.prepare(context.project, context.schema)
    on_exit(fn -> File.rm_rf!(sandbox) end)

    assert Path.basename(sandbox) =~ ~r/^mutare_sandbox_#{System.pid()}_\d+$/
    assert File.read!(Path.join(sandbox, "keep.txt")) == "keep"
    assert File.regular?(Path.join(sandbox, @marker))
  end

  test "rematerialize/2 rewrites only changed metamutants and reuses the path", context do
    schema = %Schema{metamutants: %{"lib/a.ex" => "defmodule A do\n  def x, do: 1\nend\n"}}
    sandbox = Path.join(context.base, "sandbox")
    assert Sandbox.prepare(context.project, schema, sandbox: sandbox) == sandbox

    path = Path.join(sandbox, "lib/a.ex")
    # Backdate the metamutant so a no-op rewrite is detectable: `put_if_changed`
    # leaves an unchanged file untouched, so its mtime must survive.
    backdated = 946_684_800
    File.touch!(path, backdated)

    # Same schema → not rewritten (mtime preserved), and the path is returned.
    assert Sandbox.rematerialize(sandbox, schema) == sandbox
    assert File.stat!(path, time: :posix).mtime == backdated

    # Changed metamutant → rewritten in place.
    changed = %Schema{metamutants: %{"lib/a.ex" => "defmodule A do\n  def x, do: 2\nend\n"}}
    assert Sandbox.rematerialize(sandbox, changed) == sandbox
    assert File.read!(path) =~ "do: 2"
    refute File.stat!(path, time: :posix).mtime == backdated
  end

  test "adopts an existing empty directory", context do
    sandbox = Path.join(context.base, "sandbox")
    File.mkdir_p!(sandbox)

    assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox
    assert File.read!(Path.join(sandbox, "keep.txt")) == "keep"
    assert File.regular?(Path.join(sandbox, @marker))
  end

  test "reuses a marked sandbox, clearing its stale contents", context do
    sandbox = Path.join(context.base, "sandbox")

    # First run marks and populates it.
    assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox
    stale = Path.join(sandbox, "stale.txt")
    File.write!(stale, "stale")

    # Second run on the same (now owned) path wipes the stale file and rebuilds.
    assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox
    refute File.exists?(stale)
    assert File.read!(Path.join(sandbox, "keep.txt")) == "keep"
    assert File.regular?(Path.join(sandbox, @marker))
  end

  test "refuses a non-empty directory it does not own, untouched", context do
    sandbox = Path.join(context.base, "sandbox")
    bystander = Path.join(sandbox, "important.txt")
    File.mkdir_p!(sandbox)
    File.write!(bystander, "precious")

    assert_refused(context.project, sandbox, context.schema)
    assert File.read!(bystander) == "precious"
    refute File.exists?(Path.join(sandbox, @marker))
  end

  test "refuses a directory whose marker has foreign contents", context do
    sandbox = Path.join(context.base, "sandbox")
    File.mkdir_p!(sandbox)
    File.write!(Path.join(sandbox, @marker), "not really ours")
    File.write!(Path.join(sandbox, "important.txt"), "precious")

    assert_refused(context.project, sandbox, context.schema)
    assert File.read!(Path.join(sandbox, "important.txt")) == "precious"
  end

  test "refuses a regular file at the sandbox path, untouched", context do
    sandbox = Path.join(context.base, "sandbox")
    File.write!(sandbox, "i am a file")

    assert_refused(context.project, sandbox, context.schema)
    assert File.read!(sandbox) == "i am a file"
  end

  test "injects the bootstrap into every umbrella app's helper, not a root one" do
    %{umbrella: umbrella, sandbox: sandbox} =
      Umbrella.build(:bootstrap_demo, %{
        core: %{files: %{"lib/core.ex" => "defmodule Core do\n  def f, do: 1\nend\n"}},
        web: %{deps: [:core], files: %{"lib/web.ex" => "defmodule Web do\n  def g, do: 2\nend\n"}}
      })

    project = Project.resolve(umbrella)
    schema = Schema.build(umbrella, project: project)

    assert Sandbox.prepare(umbrella, schema, sandbox: sandbox, project: project) == sandbox

    for app <- ["core", "web"] do
      helper = File.read!(Path.join(sandbox, "apps/#{app}/test/test_helper.exs"))
      assert helper =~ "injected by Mutare: select the active mutant"
      assert helper =~ "injected by Mutare: coverage setup"
      # The app's own helper content is preserved.
      assert helper =~ "ExUnit.start()"
    end

    # An umbrella has no root suite, so no root helper should be created.
    refute File.exists?(Path.join(sandbox, "test/test_helper.exs"))
  end

  @selector_comment "select the active mutant from the environment"
  @owner_watch_comment "halt when the spawning Mutare process dies"

  describe "config injection (owner-death watcher)" do
    test "prefixes an existing config, preserving the target's own content", context do
      config = Path.join(context.project, "config/config.exs")
      File.mkdir_p!(Path.dirname(config))
      File.write!(config, "import Config\n\nconfig :demo, key: :value\n")

      sandbox = Path.join(context.base, "sandbox")
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox)

      injected = File.read!(Path.join(sandbox, "config/config.exs"))
      # Watcher first — armed before any target config code that might raise.
      assert String.starts_with?(injected, "# ---- injected by Mutare: #{@owner_watch_comment}")
      assert injected =~ "config :demo, key: :value"

      # The other two snippets riding the same "config runs before the compilers"
      # property: type-signature inference off (diagnostics-only; pathological on
      # metamutant-shaped code — `CompilerOptions.infer_signatures_off_ast/0`) and
      # the compile's wall-clock cap (`Invocation.compile_watcher_ast/0`, armed
      # only by the runner's compile invocation).
      assert injected =~ "Code.put_compiler_option(:infer_signatures, false)"

      assert injected =~
               Macro.to_string(Mutare.Sandbox.Command.Invocation.compile_watcher_ast())
    end

    test "replaces a copied config symlink before injecting", context do
      original = "import Config\n\nconfig :shared, key: :value\n"
      outside = Path.join(context.base, "shared_config.exs")
      File.write!(outside, original)

      config = Path.join(context.project, "config/config.exs")
      File.mkdir_p!(Path.dirname(config))
      :ok = File.ln_s(outside, config)

      sandbox = Path.join(context.base, "sandbox")
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox)

      sandbox_config = Path.join(sandbox, "config/config.exs")
      assert %File.Stat{type: :regular} = File.lstat!(sandbox_config)
      assert File.read!(outside) == original

      injected = File.read!(sandbox_config)
      assert String.starts_with?(injected, "# ---- injected by Mutare: #{@owner_watch_comment}")
      assert injected =~ "config :shared, key: :value"
    end

    test "recreates a symlinked config directory before injecting", context do
      original = "import Config\n\nconfig :shared, dir: true\n"
      outside_dir = Path.join(context.base, "shared_config_dir")
      File.mkdir_p!(outside_dir)
      File.write!(Path.join(outside_dir, "config.exs"), original)

      :ok = File.ln_s(outside_dir, Path.join(context.project, "config"))

      sandbox = Path.join(context.base, "sandbox")
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox)

      sandbox_config_dir = Path.join(sandbox, "config")
      sandbox_config = Path.join(sandbox_config_dir, "config.exs")

      assert %File.Stat{type: :directory} = File.lstat!(sandbox_config_dir)
      assert %File.Stat{type: :regular} = File.lstat!(sandbox_config)
      assert File.read!(Path.join(outside_dir, "config.exs")) == original

      injected = File.read!(sandbox_config)
      assert String.starts_with?(injected, "# ---- injected by Mutare: #{@owner_watch_comment}")
      assert injected =~ "config :shared, dir: true"
    end

    test "generates a config when the target ships none", context do
      refute File.exists?(Path.join(context.project, "config"))

      sandbox = Path.join(context.base, "sandbox")
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox)

      injected = File.read!(Path.join(sandbox, "config/config.exs"))
      # Mix loads the default `config_path` whenever the file exists, so the
      # generated file is picked up without touching the target's `mix.exs`.
      assert injected =~ "import Config"
      assert injected =~ @owner_watch_comment
    end

    test "injects exactly once across repeated kept runs", context do
      config = Path.join(context.project, "config/config.exs")
      File.mkdir_p!(Path.dirname(config))
      File.write!(config, "import Config\n")

      sandbox = Path.join(context.base, "sandbox")
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)

      injected = File.read!(Path.join(sandbox, "config/config.exs"))
      occurrences = injected |> String.split(@owner_watch_comment) |> length()
      assert occurrences == 2, "expected one injected block, got #{occurrences - 1}"
    end

    test "a custom config_path target still gets the default placement, untouched elsewhere",
         context do
      # Deliberately unresolved (see `config_files/1`): divining a custom
      # `config_path` would mean parsing or evaluating the target's `mix.exs`.
      # The injected default-path file is dead weight mix never loads; the
      # target's real config is not modified, and `mix test` runs stay covered
      # by the test-bootstrap copy of the watcher.
      File.write!(Path.join(context.project, "mix.exs"), """
      defmodule Demo.MixProject do
        use Mix.Project
        def project, do: [app: :demo, version: "0.1.0", config_path: "conf/main.exs"]
      end
      """)

      custom = Path.join(context.project, "conf/main.exs")
      File.mkdir_p!(Path.dirname(custom))
      File.write!(custom, "import Config\n\nconfig :demo, key: :value\n")

      sandbox = Path.join(context.base, "sandbox")
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox)

      assert File.read!(Path.join(sandbox, "config/config.exs")) =~ @owner_watch_comment
      # The real (custom-path) config is copied verbatim, never prefixed.
      assert File.read!(Path.join(sandbox, "conf/main.exs")) ==
               "import Config\n\nconfig :demo, key: :value\n"
    end
  end

  describe "keep_sandbox: true" do
    test "preserves a previous build between runs, but a fresh run wipes it", context do
      sandbox = Path.join(context.base, "sandbox")

      assert Sandbox.prepare(context.project, context.schema,
               sandbox: sandbox,
               keep_sandbox: true
             ) ==
               sandbox

      # Seed a compiled artifact the way `mix compile` would, under an excluded dir.
      cached = Path.join(sandbox, "_build/test/keep")
      File.mkdir_p!(Path.dirname(cached))
      File.write!(cached, "cached")

      # A second kept run reuses the directory in place — the build survives.
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      assert File.read!(cached) == "cached"

      # A fresh (default) run on the same owned path wipes everything.
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox)
      refute File.exists?(cached)
    end

    test "leaves unchanged files untouched but rewrites changed ones", context do
      sandbox = Path.join(context.base, "sandbox")
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)

      kept = Path.join(sandbox, "keep.txt")
      past = 1_700_000_000
      File.touch!(kept, past)

      # Re-materialising with identical content must not rewrite the file (so its
      # mtime is unchanged and mix would skip recompiling it).
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      assert File.stat!(kept, time: :posix).mtime == past

      # Changing the source content does rewrite it.
      File.write!(context.marker, "changed")
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      assert File.read!(kept) == "changed"
      assert File.stat!(kept, time: :posix).mtime != past
    end

    test "prunes files removed from the source since the last run", context do
      sandbox = Path.join(context.base, "sandbox")
      gone = Path.join(context.project, "gone.txt")
      File.write!(gone, "x")

      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      assert File.exists?(Path.join(sandbox, "gone.txt"))

      File.rm!(gone)
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      refute File.exists?(Path.join(sandbox, "gone.txt"))
    end

    test "injects the bootstrap exactly once across repeated runs", context do
      sandbox = Path.join(context.base, "sandbox")
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)

      helper = File.read!(Path.join(sandbox, "test/test_helper.exs"))
      occurrences = helper |> String.split(@selector_comment) |> length()
      assert occurrences == 2, "expected one bootstrap block, got #{occurrences - 1}"
    end

    test "reuses the coverage helper at a stable path (no accumulation)", context do
      sandbox = Path.join(context.base, "sandbox")
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)

      assert File.regular?(Path.join(sandbox, "lib/__mutare__/coverage_helper.ex"))
      refute File.exists?(Path.join(sandbox, "lib/__mutare__/coverage_helper_1.ex"))
    end

    test "with no :sandbox, derives a stable per-project temp dir", context do
      first = Sandbox.prepare(context.project, context.schema, keep_sandbox: true)
      on_exit(fn -> File.rm_rf!(first) end)
      second = Sandbox.prepare(context.project, context.schema, keep_sandbox: true)

      assert first == second
      assert String.starts_with?(first, System.tmp_dir!())
    end

    test "materializes umbrella helpers and support app without accumulating" do
      %{umbrella: umbrella, sandbox: sandbox} =
        Umbrella.build(:kept_bootstrap_demo, %{
          core: %{files: %{"lib/core.ex" => "defmodule Core do\n  def f, do: 1\nend\n"}},
          web: %{files: %{"lib/web.ex" => "defmodule Web do\n  def g, do: 2\nend\n"}}
        })

      project = Project.resolve(umbrella)
      schema = Schema.build(umbrella, project: project)

      assert Sandbox.prepare(umbrella, schema,
               sandbox: sandbox,
               project: project,
               keep_sandbox: true
             ) == sandbox

      assert Sandbox.prepare(umbrella, schema,
               sandbox: sandbox,
               project: project,
               keep_sandbox: true
             ) == sandbox

      for app <- ["core", "web"] do
        helper = File.read!(Path.join(sandbox, "apps/#{app}/test/test_helper.exs"))
        assert helper =~ "injected by Mutare: select the active mutant"
        assert helper =~ "injected by Mutare: coverage setup"
        assert helper =~ "ExUnit.start()"
      end

      refute File.exists?(Path.join(sandbox, "test/test_helper.exs"))
      assert File.regular?(Path.join(sandbox, "apps/mutare_support/mix.exs"))
      assert File.regular?(Path.join(sandbox, "apps/mutare_support/lib/mutare_cov.ex"))
      refute File.exists?(Path.join(sandbox, "apps/mutare_support_1"))
    end
  end

  describe "dependency build seeding" do
    test "seeds a dependency's compiled build into the sandbox", context do
      seed_dep(context.project, "dep_a")
      sandbox = Path.join(context.base, "sandbox")

      assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox

      assert File.read!(Path.join(sandbox, "_build/test/lib/dep_a/ebin/dep_a.app")) ==
               "{application, dep_a, []}."
    end

    test "seeds only deps/ entries, never the app's own build", context do
      # A real dependency (under deps/) and an app build dir that is *not* a dep
      # (e.g. the project's own app, or an umbrella app under apps/).
      seed_dep(context.project, "dep_a")
      app_ebin = Path.join([context.project, "_build/test/lib/app_self/ebin"])
      File.mkdir_p!(app_ebin)
      File.write!(Path.join(app_ebin, "app_self.app"), "{application, app_self, []}.")

      sandbox = Path.join(context.base, "sandbox")
      assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox

      # The dep is seeded; the app's own build is left out so mix must (re)compile
      # the metamutant rather than risk serving a stale original beam.
      assert File.exists?(Path.join(sandbox, "_build/test/lib/dep_a/ebin/dep_a.app"))
      refute File.exists?(Path.join(sandbox, "_build/test/lib/app_self"))
    end

    test "skips a dependency with no compiled artifacts (dev-only / uncompiled)", context do
      # Listed under deps/ but never built in the test env — nothing to seed, no crash.
      File.mkdir_p!(Path.join([context.project, "deps", "dev_only"]))
      sandbox = Path.join(context.base, "sandbox")

      assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox
      refute File.exists?(Path.join(sandbox, "_build/test/lib/dev_only"))
    end

    test "a dependency-free project (no deps/) seeds nothing and still prepares", context do
      sandbox = Path.join(context.base, "sandbox")

      assert Sandbox.prepare(context.project, context.schema, sandbox: sandbox) == sandbox
      refute File.exists?(Path.join(sandbox, "_build"))
    end

    test "keep_sandbox: does not clobber a dep build already in the sandbox", context do
      seed_dep(context.project, "dep_a")
      sandbox = Path.join(context.base, "sandbox")

      # First kept run seeds the dep (the sandbox starts with no `_build`).
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      seeded = Path.join(sandbox, "_build/test/lib/dep_a/ebin/dep_a.app")
      assert File.exists?(seeded)

      # Simulate the sandbox having recompiled the dep itself (newer artifact).
      File.write!(seeded, "{application, dep_a, [recompiled]}.")

      # A second kept run must leave the preserved build alone (idempotent seed).
      Sandbox.prepare(context.project, context.schema, sandbox: sandbox, keep_sandbox: true)
      assert File.read!(seeded) == "{application, dep_a, [recompiled]}."
    end
  end

  describe "app build seeding" do
    test "seeds the build and deletes only the metamutant's beam", context do
      project = context.project
      # The mutated app: a real beam for the metamutant file and one for an untouched file.
      put_app_beam(project, "myapp", "lib/foo.ex", "Foo#{uniq()}")
      put_app_beam(project, "myapp", "lib/bar.ex", "Bar#{uniq()}")
      # The manifest carries a *bare* absolute project root (the real staleness gate) plus
      # an absolute sub-path, mirroring how mix records them.
      put_app_manifest(project, "myapp", [Path.expand(project), abs(project, "lib/bar.ex")])

      schema = %Schema{metamutants: %{"lib/foo.ex" => "defmodule Foo do\n  def x, do: 2\nend\n"}}
      sandbox = Path.join(context.base, "sandbox")

      # No scoping flag: the gate is outcome-based (1 of 2 modules mutated → worth it).
      Sandbox.prepare(project, schema, sandbox: sandbox)

      app_build = Path.join(sandbox, "_build/test/lib/myapp")
      # The app build is seeded, the metamutant's beam removed (so mix must recompile it
      # from the metamutant), the untouched file's beam kept (reused, not recompiled).
      assert File.dir?(app_build)
      assert beams(app_build) |> Enum.any?(&(&1 =~ "Bar"))
      refute beams(app_build) |> Enum.any?(&(&1 =~ "Foo"))

      # The manifest is relocated: both the bare root and root-prefixed paths now name the
      # sandbox, not the original project — without which mix would recompile everything.
      term =
        Path.join(app_build, ".mix/compile.elixir") |> File.read!() |> :erlang.binary_to_term()

      assert inspect(term) =~ Path.expand(sandbox)
      refute inspect(term) =~ Path.expand(project)
    end

    test "seeds despite a struct in the manifest (a captured compile_env value)", context do
      project = context.project
      # A module's `Application.compile_env/2` value is recorded in the Elixir manifest, so
      # a config regex (or Range/MapSet) lands in the term. The relocation walk must skip
      # such structs, not crash on `Map.new/2` and fall back to a cold compile.
      put_app_beam(project, "myapp", "lib/foo.ex", "Foo#{uniq()}")
      put_app_beam(project, "myapp", "lib/bar.ex", "Bar#{uniq()}")

      regex = ~r/^[\w:, '"_\-.\p{Hebrew}]+$/u

      put_app_manifest(project, "myapp", [
        Path.expand(project),
        abs(project, "lib/bar.ex"),
        regex,
        1..10,
        MapSet.new([1, 2])
      ])

      schema = %Schema{metamutants: %{"lib/foo.ex" => "defmodule Foo do\n  def x, do: 2\nend\n"}}
      sandbox = Path.join(context.base, "sandbox")

      Sandbox.prepare(project, schema, sandbox: sandbox)

      app_build = Path.join(sandbox, "_build/test/lib/myapp")
      # The seed survived (not torn down to a cold compile): build present, metamutant beam
      # deleted, untouched beam kept.
      assert File.dir?(app_build)
      assert beams(app_build) |> Enum.any?(&(&1 =~ "Bar"))
      refute beams(app_build) |> Enum.any?(&(&1 =~ "Foo"))

      term =
        Path.join(app_build, ".mix/compile.elixir") |> File.read!() |> :erlang.binary_to_term()

      # The path is relocated; the structs round-trip untouched.
      assert inspect(term) =~ Path.expand(sandbox)
      refute inspect(term) =~ Path.expand(project)
      assert {:manifest, [_, _, ^regex, 1..10//1, mapset]} = term
      assert mapset == MapSet.new([1, 2])
    end

    test "seeds a `--only`/`paths:`-narrowed run (not just `--line`/`--since`)", context do
      project = context.project
      # `--only` narrows discovery via `:paths` (no `:only_files`/`:only_lines` set), so a
      # flag-based gate would miss it — the outcome-based gate sees 1 of 3 modules mutated.
      put_app_beam(project, "myapp", "lib/foo.ex", "Foo#{uniq()}")
      put_app_beam(project, "myapp", "lib/bar.ex", "Bar#{uniq()}")
      put_app_beam(project, "myapp", "lib/baz.ex", "Baz#{uniq()}")
      put_app_manifest(project, "myapp", [Path.expand(project)])

      schema = %Schema{metamutants: %{"lib/foo.ex" => "defmodule Foo do\n  def x, do: 2\nend\n"}}
      sandbox = Path.join(context.base, "sandbox")

      Sandbox.prepare(project, schema, sandbox: sandbox, paths: ["lib/foo.ex"])

      app_build = Path.join(sandbox, "_build/test/lib/myapp")
      assert File.dir?(app_build)
      refute beams(app_build) |> Enum.any?(&(&1 =~ "Foo"))
      assert beams(app_build) |> Enum.any?(&(&1 =~ "Bar"))
      assert beams(app_build) |> Enum.any?(&(&1 =~ "Baz"))
    end

    test "does not seed when --no-seed-app-build (seed_app_build: false)", context do
      project = context.project
      # Same setup as the happy path (the gate would otherwise seed), but opted out.
      put_app_beam(project, "myapp", "lib/foo.ex", "Foo#{uniq()}")
      put_app_beam(project, "myapp", "lib/bar.ex", "Bar#{uniq()}")
      put_app_manifest(project, "myapp", [Path.expand(project)])

      schema = %Schema{metamutants: %{"lib/foo.ex" => "defmodule Foo do\n  def x, do: 2\nend\n"}}
      sandbox = Path.join(context.base, "sandbox")

      Sandbox.prepare(project, schema, sandbox: sandbox, seed_app_build: false)

      refute File.exists?(Path.join(sandbox, "_build/test/lib/myapp"))
    end

    test "skips seeding when most of the app would be recompiled anyway", context do
      project = context.project
      # Both modules mutated (2 of 2): seeding then deleting both beams is a cold compile
      # plus the copy + scan overhead, so the gate declines and leaves the build unseeded.
      put_app_beam(project, "myapp", "lib/foo.ex", "Foo#{uniq()}")
      put_app_beam(project, "myapp", "lib/bar.ex", "Bar#{uniq()}")
      put_app_manifest(project, "myapp", [Path.expand(project)])

      schema = %Schema{
        metamutants: %{
          "lib/foo.ex" => "defmodule Foo do\n  def x, do: 2\nend\n",
          "lib/bar.ex" => "defmodule Bar do\n  def x, do: 2\nend\n"
        }
      }

      sandbox = Path.join(context.base, "sandbox")
      Sandbox.prepare(project, schema, sandbox: sandbox)

      refute File.exists?(Path.join(sandbox, "_build/test/lib/myapp"))
    end

    test "tears the seed down when a metamutant's beam can't be found (fail-safe)", context do
      project = context.project
      # Enough untouched modules to clear the worth-it gate, but *no* beam for the
      # metamutant file: we cannot guarantee it would recompile, so the whole seed must be
      # abandoned (a cold compile) rather than risk serving a stale original beam.
      put_app_beam(project, "myapp", "lib/bar.ex", "Bar#{uniq()}")
      put_app_beam(project, "myapp", "lib/baz.ex", "Baz#{uniq()}")
      put_app_beam(project, "myapp", "lib/qux.ex", "Qux#{uniq()}")
      put_app_manifest(project, "myapp", [Path.expand(project)])

      schema = %Schema{metamutants: %{"lib/foo.ex" => "defmodule Foo do\n  def x, do: 2\nend\n"}}
      sandbox = Path.join(context.base, "sandbox")

      Sandbox.prepare(project, schema, sandbox: sandbox)

      refute File.exists?(Path.join(sandbox, "_build/test/lib/myapp"))
    end

    test "keep_sandbox: does not clobber an app build already in the sandbox", context do
      project = context.project
      put_app_beam(project, "myapp", "lib/foo.ex", "Foo#{uniq()}")
      put_app_beam(project, "myapp", "lib/bar.ex", "Bar#{uniq()}")
      put_app_manifest(project, "myapp", [Path.expand(project)])

      schema = %Schema{metamutants: %{"lib/foo.ex" => "defmodule Foo do\n  def x, do: 2\nend\n"}}
      sandbox = Path.join(context.base, "sandbox")
      opts = [sandbox: sandbox, keep_sandbox: true]

      # First kept run seeds the app build (deleting the metamutant beam).
      Sandbox.prepare(project, schema, opts)
      app_build = Path.join(sandbox, "_build/test/lib/myapp")
      assert File.dir?(app_build)

      # Mark the preserved build (as the in-sandbox compile would have) and re-run: an
      # already-present app build is left untouched, like the dep seed.
      witness = Path.join(app_build, "ebin/recompiled.txt")
      File.write!(witness, "kept")
      Sandbox.prepare(project, schema, opts)
      assert File.read!(witness) == "kept"
    end

    test "reports the seeded outcome (reused/recompiled counts) on :on_phase", context do
      project = context.project
      put_app_beam(project, "myapp", "lib/foo.ex", "Foo#{uniq()}")
      put_app_beam(project, "myapp", "lib/bar.ex", "Bar#{uniq()}")
      put_app_manifest(project, "myapp", [Path.expand(project)])

      schema = %Schema{metamutants: %{"lib/foo.ex" => "defmodule Foo do\n  def x, do: 2\nend\n"}}
      sandbox = Path.join(context.base, "sandbox")

      # 2 app beams, one mutated: the metamutant beam recompiles, the untouched one is reused.
      assert %{outcome: :seeded, reused: 1, recompiled: 1} =
               capture_seed(project, schema, sandbox: sandbox)
    end

    test "reports :skipped when --no-seed-app-build opts out", context do
      project = context.project
      put_app_beam(project, "myapp", "lib/foo.ex", "Foo#{uniq()}")
      put_app_beam(project, "myapp", "lib/bar.ex", "Bar#{uniq()}")
      put_app_manifest(project, "myapp", [Path.expand(project)])

      schema = %Schema{metamutants: %{"lib/foo.ex" => "defmodule Foo do\n  def x, do: 2\nend\n"}}
      sandbox = Path.join(context.base, "sandbox")

      assert %{outcome: :skipped} =
               capture_seed(project, schema, sandbox: sandbox, seed_app_build: false)
    end

    test "reports :skipped when most of the app would recompile anyway", context do
      project = context.project
      put_app_beam(project, "myapp", "lib/foo.ex", "Foo#{uniq()}")
      put_app_beam(project, "myapp", "lib/bar.ex", "Bar#{uniq()}")
      put_app_manifest(project, "myapp", [Path.expand(project)])

      # Both modules mutated (2 of 2) → past the worth-it fraction → cold compile.
      schema = %Schema{
        metamutants: %{
          "lib/foo.ex" => "defmodule Foo do\n  def x, do: 2\nend\n",
          "lib/bar.ex" => "defmodule Bar do\n  def x, do: 2\nend\n"
        }
      }

      sandbox = Path.join(context.base, "sandbox")
      assert %{outcome: :skipped} = capture_seed(project, schema, sandbox: sandbox)
    end

    test "seeds a majority-but-not-all run (3 of 4) — the raised fraction gate", context do
      project = context.project
      # 3 of 4 modules mutated (f = 0.75): the measured overhead (~0.1 ms/beam) is negligible
      # against reusing the 4th, so the gate (0.9) seeds — where the old 0.5 gate cold-compiled.
      for m <- ~w(a b c d), do: put_app_beam(project, "myapp", "lib/#{m}.ex", "M#{m}#{uniq()}")
      put_app_manifest(project, "myapp", [Path.expand(project)])

      schema = %Schema{
        metamutants:
          Map.new(~w(a b c), &{"lib/#{&1}.ex", "defmodule M#{&1} do\n  def x, do: 2\nend\n"})
      }

      sandbox = Path.join(context.base, "sandbox")

      assert %{outcome: :seeded, reused: 1, recompiled: 3} =
               capture_seed(project, schema, sandbox: sandbox)
    end

    test "reports the :fallback outcome when a metamutant beam can't be matched", context do
      project = context.project
      # Enough untouched modules to clear the gate, but no beam for the metamutant file: the
      # seed is torn down (a cold compile) and the otherwise-silent fallback is surfaced.
      put_app_beam(project, "myapp", "lib/bar.ex", "Bar#{uniq()}")
      put_app_beam(project, "myapp", "lib/baz.ex", "Baz#{uniq()}")
      put_app_manifest(project, "myapp", [Path.expand(project)])

      schema = %Schema{metamutants: %{"lib/foo.ex" => "defmodule Foo do\n  def x, do: 2\nend\n"}}
      sandbox = Path.join(context.base, "sandbox")

      assert %{outcome: :fallback, reason: reason} =
               capture_seed(project, schema, sandbox: sandbox)

      assert reason =~ "could not be matched"
      # Fallback means torn down: the run proceeds as a cold compile, no seeded build left.
      refute File.exists?(Path.join(sandbox, "_build/test/lib/myapp"))
    end

    test "umbrella: one app's partial miss cold-compiles only that app, not its siblings" do
      %{umbrella: umbrella, sandbox: sandbox} =
        Umbrella.build(:seed_partial_demo, %{
          core: %{files: %{"lib/core.ex" => "defmodule Core do\n  def f, do: 1\nend\n"}},
          web: %{
            deps: [:core],
            files: %{"lib/web.ex" => "defmodule Web do\n  def g, do: 2\nend\n"}
          }
        })

      project = Project.resolve(umbrella)

      # Each app: one beam for a real file plus a spare (to clear the worth-it gate).
      put_app_beam(umbrella, "core", "apps/core/lib/core.ex", "Core#{uniq()}")
      put_app_beam(umbrella, "core", "apps/core/lib/core_util.ex", "CoreUtil#{uniq()}")
      put_app_beam(umbrella, "web", "apps/web/lib/web.ex", "Web#{uniq()}")
      put_app_beam(umbrella, "web", "apps/web/lib/web_util.ex", "WebUtil#{uniq()}")
      put_app_manifest(umbrella, "core", [Path.expand(umbrella)])
      put_app_manifest(umbrella, "web", [Path.expand(umbrella)])

      # core's metamutant matches its beam (clean); web's metamutant has no beam (a miss).
      schema = %Schema{
        metamutants: %{
          "apps/core/lib/core.ex" => "defmodule Core do\n  def f, do: 2\nend\n",
          "apps/web/lib/web_missing.ex" => "defmodule WebMissing do\n  def h, do: 9\nend\n"
        }
      }

      summary = capture_seed(umbrella, schema, sandbox: sandbox, project: project)

      # Per-app: core kept (1 reused, 1 recompiled), web torn down — not the whole umbrella.
      assert %{outcome: :partial, reused: 1, recompiled: 1, fell_back: 1} = summary

      core_build = Path.join(sandbox, "_build/test/lib/core")
      assert File.dir?(core_build)
      refute beams(core_build) |> Enum.any?(&(&1 =~ "Core."))
      assert beams(core_build) |> Enum.any?(&(&1 =~ "CoreUtil"))

      # web is the only app that cold-compiles.
      refute File.exists?(Path.join(sandbox, "_build/test/lib/web"))
    end

    test "umbrella: all apps seeding cleanly report an aggregate :seeded summary" do
      %{umbrella: umbrella, sandbox: sandbox} =
        Umbrella.build(:seed_clean_demo, %{
          core: %{files: %{"lib/core.ex" => "defmodule Core do\n  def f, do: 1\nend\n"}},
          web: %{
            deps: [:core],
            files: %{"lib/web.ex" => "defmodule Web do\n  def g, do: 2\nend\n"}
          }
        })

      project = Project.resolve(umbrella)

      put_app_beam(umbrella, "core", "apps/core/lib/core.ex", "Core#{uniq()}")
      put_app_beam(umbrella, "core", "apps/core/lib/core_util.ex", "CoreUtil#{uniq()}")
      put_app_beam(umbrella, "web", "apps/web/lib/web.ex", "Web#{uniq()}")
      put_app_beam(umbrella, "web", "apps/web/lib/web_util.ex", "WebUtil#{uniq()}")
      put_app_manifest(umbrella, "core", [Path.expand(umbrella)])
      put_app_manifest(umbrella, "web", [Path.expand(umbrella)])

      # One metamutant per app, each matching its beam.
      schema = %Schema{
        metamutants: %{
          "apps/core/lib/core.ex" => "defmodule Core do\n  def f, do: 2\nend\n",
          "apps/web/lib/web.ex" => "defmodule Web do\n  def g, do: 3\nend\n"
        }
      }

      # 2 reused (the two *_util spares), 2 recompiled (core.ex + web.ex), both apps kept.
      assert %{outcome: :seeded, reused: 2, recompiled: 2} =
               capture_seed(umbrella, schema, sandbox: sandbox, project: project)

      assert File.dir?(Path.join(sandbox, "_build/test/lib/core"))
      assert File.dir?(Path.join(sandbox, "_build/test/lib/web"))
    end
  end

  # Run `Sandbox.prepare/3` with an `:on_phase` hook and return the app-build seed's summary
  # (the `{:seed_app_build, summary}` detail event `--verbose` renders).
  defp capture_seed(project, schema, opts) do
    test_pid = self()

    hook = fn
      {:seed_app_build, summary} -> send(test_pid, {:captured_seed, summary})
      _ -> :ok
    end

    Sandbox.prepare(project, schema, Keyword.put(opts, :on_phase, hook))
    assert_receive {:captured_seed, summary}
    summary
  end

  defp uniq, do: System.unique_integer([:positive])

  defp abs(project, rel), do: Path.join(Path.expand(project), rel)

  defp beams(app_build),
    do: Path.wildcard(Path.join(app_build, "ebin/*.beam")) |> Enum.map(&Path.basename/1)

  # Lay down a *real* compiled beam for `module` (so `:beam_lib` can read its embedded
  # source path) under the app's `_build/test/lib/<app>/ebin`, sourced from `rel`.
  defp put_app_beam(project, app, rel, module) do
    source = Path.join(project, rel)
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "defmodule #{module} do\n  def x, do: 1\nend\n")

    [{mod, bin}] = Code.compile_file(source)
    :code.purge(mod)
    :code.delete(mod)

    ebin = Path.join([project, "_build/test/lib", app, "ebin"])
    File.mkdir_p!(ebin)
    File.write!(Path.join(ebin, "Elixir.#{module}.beam"), bin)
  end

  # A stand-in compile manifest carrying absolute source `paths` (the only thing the
  # relocation rewrites); a plain term, since the rewrite is structure-agnostic.
  defp put_app_manifest(project, app, paths) do
    mix_dir = Path.join([project, "_build/test/lib", app, ".mix"])
    File.mkdir_p!(mix_dir)
    File.write!(Path.join(mix_dir, "compile.elixir"), :erlang.term_to_binary({:manifest, paths}))
  end

  # Lay down a fake dependency: a `deps/<name>` source dir and its compiled
  # artifact under the project's `_build/test/lib/<name>`, the way mix would.
  defp seed_dep(project, name) do
    File.mkdir_p!(Path.join([project, "deps", name]))
    ebin = Path.join([project, "_build/test/lib", name, "ebin"])
    File.mkdir_p!(ebin)
    File.write!(Path.join(ebin, "#{name}.app"), "{application, #{name}, []}.")
  end

  defp assert_refused(root, sandbox, schema) do
    error =
      assert_raise ArgumentError, fn ->
        Sandbox.prepare(root, schema, sandbox: sandbox)
      end

    assert Exception.message(error) =~ "refusing to use sandbox"
  end

  defp assert_refused_lock(root, sandbox) do
    error =
      assert_raise ArgumentError, fn ->
        Sandbox.acquire_lock(root, sandbox: sandbox)
      end

    assert Exception.message(error) =~ "refusing to use sandbox"
  end

  defp assert_unsafe(root, sandbox, schema, relation) do
    error =
      assert_raise ArgumentError, fn ->
        Sandbox.prepare(root, schema, sandbox: sandbox)
      end

    assert Exception.message(error) =~ "unsafe sandbox path"
    assert Exception.message(error) =~ relation
  end
end
