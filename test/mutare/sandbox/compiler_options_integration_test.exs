defmodule Mutare.Sandbox.CompilerOptionsIntegrationTest do
  use ExUnit.Case, async: true

  alias Mutare.{Sandbox, Schema}
  alias Mutare.Sandbox.{CompilerOptions, Command.Invocation}

  @moduletag :runner
  @moduletag timeout: 120_000

  # Observe the compiler option from inside an actual source compilation. A
  # config-only observation misses Mix 1.20 overwriting the global setting.
  @observing_source """
  defmodule InferenceObserved do
    option =
      if :infer_signatures in Code.available_compiler_options(),
        do: Code.get_compiler_option(:infer_signatures),
        else: :unsupported

    File.write!("compiled-options", inspect(option) <> "\\n", [:append])
    def ok, do: :ok
  end
  """

  @test_source """
  defmodule InferenceObservedTest do
    use ExUnit.Case

    test "project options stay consistent on every boot" do
      if :infer_signatures in Code.available_compiler_options() do
        assert Mix.Project.config()[:elixirc_options][:infer_signatures] == false
      end

      assert InferenceObserved.ok() == :ok
    end
  end
  """

  # Keep both option sets and the `xref:` exclusion. This is the only test that checks a
  # seeded cache key against the key Mix forms from the wrapped `project/0`, entry order
  # included: Mix compares the two with `!=`, and the `seed_manifest/1` unit test restates
  # the implementation's `Keyword.put/3`. Mix folds `xref: [exclude: ...]` into
  # `:no_warn_undefined`, appending that entry when the options lack one, so `[]` catches a
  # seed that appends `:infer_signatures` rather than prepending it. The second set catches
  # a wrapper or seed that updates the entry in place, but only while `:infer_signatures`
  # sits behind `:docs`. Elixir 1.20 left inference out of the key, so only 1.18/1.19
  # exercise any of this.
  for options <- [[], [docs: false, infer_signatures: true, no_warn_undefined: [MissingModule]]] do
    @seed_options options
    test "first sandbox compile reuses the target build with options #{inspect(options)}" do
      fixture =
        Mutare.Test.Project.build(:inference_seed, %{
          "mix.exs" => """
          defmodule InferenceSeed.MixProject do
            use Mix.Project
            def project do
              [app: :inference_seed, version: "0.0.0",
               elixirc_options: #{inspect(@seed_options)}, xref: [exclude: [AnotherMissingModule]]]
            end
          end
          """,
          "lib/observed.ex" => @observing_source,
          "lib/untouched.ex" => """
          defmodule Untouched do
            File.write!("untouched-compiles", "compiled\n", [:append])
            def ok, do: :ok
          end
          """,
          "test/observed_test.exs" => @test_source
        })

      {output, status} = Mutare.Test.Project.compile(fixture.project)
      assert status == 0, output
      File.rm!(Path.join(fixture.project, "compiled-options"))
      manifest_rel = "_build/test/lib/inference_seed/.mix/compile.elixir"
      original_manifest = File.read!(Path.join(fixture.project, manifest_rel))

      schema = %Schema{
        sources: %{
          "lib/untouched.ex" => File.read!(Path.join(fixture.project, "lib/untouched.ex"))
        },
        metamutants: %{
          "lib/observed.ex" => @observing_source <> "\n# metamutant\n",
          "lib/untouched.ex" => File.read!(Path.join(fixture.project, "lib/untouched.ex"))
        }
      }

      Sandbox.prepare(fixture.project, schema, sandbox: fixture.sandbox)
      compile_and_observe(fixture.sandbox)
      assert File.read!(Path.join(fixture.sandbox, "untouched-compiles")) == "compiled\n"
      assert File.read!(Path.join(fixture.project, manifest_rel)) == original_manifest

      for opts <- [[], [coverage: coverage(fixture.sandbox)]] do
        {output, status} = Invocation.mix(fixture.sandbox, ["test"], 0, opts)
        assert status == 0, output
        refute output =~ "Compiling "
      end

      # A genuine option change must still invalidate both files, even when it
      # happened after the target build we transplant.
      mix_file = Path.join(fixture.project, "mix.exs")

      File.write!(
        mix_file,
        String.replace(
          File.read!(mix_file),
          "elixirc_options: #{inspect(@seed_options)}",
          "elixirc_options: #{inspect(Keyword.put(@seed_options, :docs, !Keyword.get(@seed_options, :docs, true)))}"
        )
      )

      changed_sandbox = Path.join(fixture.base, "changed-sandbox")
      Sandbox.prepare(fixture.project, schema, sandbox: changed_sandbox)
      compile_and_observe(changed_sandbox)

      assert File.read!(Path.join(changed_sandbox, "untouched-compiles")) ==
               "compiled\ncompiled\n"
    end
  end

  test "default project disables inference during compile and retains it on baseline/probe boots" do
    fixture =
      Mutare.Test.Project.build(:inference_default, %{
        "lib/observed.ex" => @observing_source,
        "test/observed_test.exs" => @test_source
      })

    original = File.read!(Path.join(fixture.project, "mix.exs"))
    prepare(fixture)
    compiled = compile_and_observe(fixture.sandbox)

    manifest = Path.join(fixture.sandbox, "_build/test/lib/inference_default/.mix/compile.elixir")
    before_manifest = File.read!(manifest)

    for opts <- [[], [coverage: coverage(fixture.sandbox)]] do
      {output, status} = Invocation.mix(fixture.sandbox, ["test"], 0, opts)
      assert status == 0, output
      refute output =~ "Compiling "
      assert File.read!(Path.join(fixture.sandbox, "compiled-options")) == compiled
      assert File.read!(manifest) == before_manifest
    end

    # Rematerialising a retained sandbox neither stacks wrappers nor invalidates
    # its unchanged Mix project file.
    mix_file = Path.join(fixture.sandbox, "mix.exs")
    File.touch!(mix_file, {{2001, 1, 1}, {0, 0, 0}})
    before_mix = File.read!(mix_file)
    prepare(fixture)
    assert File.read!(mix_file) == before_mix
    assert File.stat!(mix_file).mtime == {{2001, 1, 1}, {0, 0, 0}}
    assert File.read!(Path.join(fixture.project, "mix.exs")) == original
  end

  test "a keyword-do Mix project disables inference during compilation" do
    fixture =
      Mutare.Test.Project.build(:inference_inline, %{
        "mix.exs" => """
        defmodule InferenceInline.MixProject, do: (
          use Mix.Project
          def project, do: [app: :inference_inline, version: "0.0.0"]
        )
        """,
        "lib/observed.ex" => @observing_source
      })

    prepare(fixture)
    compile_and_observe(fixture.sandbox)
  end

  test "an excluded umbrella template cannot abort project rewriting" do
    fixture =
      Mutare.Test.Umbrella.build(:inference_template, %{
        inference_child: %{files: %{"lib/observed.ex" => @observing_source}},
        template: %{files: %{"mix.exs" => "defmodule <%= @module %>.MixProject do\n"}}
      })

    root_mix = Path.join(fixture.umbrella, "mix.exs")

    File.write!(
      root_mix,
      String.replace(File.read!(root_mix), "apps_path:", "apps: [:inference_child], apps_path:")
    )

    project = Mutare.Project.resolve(fixture.umbrella)
    assert Enum.any?(project.apps, &(&1.dir == "apps/template"))

    Sandbox.prepare(fixture.umbrella, %Schema{}, sandbox: fixture.sandbox, project: project)

    assert File.read!(Path.join(fixture.sandbox, "apps/template/mix.exs")) ==
             File.read!(Path.join(fixture.umbrella, "apps/template/mix.exs"))

    compile_and_observe(fixture.sandbox, "apps/inference_child/compiled-options")
  end

  test "computed explicit options and custom config paths keep other settings" do
    fixture =
      Mutare.Test.Project.build(:inference_custom, %{
        "mix.exs" => """
        Kernel.defmodule InferenceCustom.MixProject do
          use Mix.Project

          def project do
            [app: :inference_custom, version: "0.0.0", config_path: "conf/custom.exs"] ++
              [elixirc_options: compiler_options()]
          end

          defp compiler_options, do: [infer_signatures: true, docs: false, debug_info: false]
        end
        """,
        "conf/custom.exs" => "import Config\n",
        "lib/observed.ex" =>
          @observing_source <>
            """
            defmodule OtherOptionsObserved do
              false = Code.get_compiler_option(:docs)
              false = Code.get_compiler_option(:debug_info)
            end
            """
      })

    original = File.read!(Path.join(fixture.project, "mix.exs"))
    prepare(fixture)
    compile_and_observe(fixture.sandbox)
    assert File.read!(Path.join(fixture.project, "mix.exs")) == original
  end

  test "project defined by an earlier before_compile hook is also wrapped" do
    fixture =
      Mutare.Test.Project.build(:inference_generated, %{
        "mix.exs" => """
        defmodule GeneratedProject do
          defmacro __before_compile__(_) do
            quote do
              def project, do: [app: :inference_generated, version: "0.0.0"]
            end
          end
        end

        defmodule InferenceGenerated.MixProject do
          use Mix.Project
          @before_compile GeneratedProject
        end
        """,
        "lib/observed.ex" => @observing_source
      })

    prepare(fixture)
    compile_and_observe(fixture.sandbox)
  end

  test "umbrella children keep inference off after Mix reloads cached projects" do
    fixture =
      Mutare.Test.Umbrella.build(:inference_umbrella, %{
        inference_child: %{files: %{"lib/observed.ex" => @observing_source}},
        inference_consumer: %{
          deps: [:inference_child],
          files: %{"test/observed_test.exs" => @test_source}
        }
      })

    project = Mutare.Project.resolve(fixture.umbrella)

    Sandbox.prepare(fixture.umbrella, %Schema{},
      sandbox: fixture.sandbox,
      project: project
    )

    compile_and_observe(fixture.sandbox, "apps/inference_child/compiled-options")

    {output, status} = Invocation.mix(fixture.sandbox, ["test"], 0)
    assert status == 0, output
    refute output =~ "Compiling "
  end

  test "a seeded umbrella preserves untouched modules in each app" do
    fixture =
      Mutare.Test.Umbrella.build(:inference_seed_umbrella, %{
        inference_seed_child: %{files: %{"lib/observed.ex" => @observing_source}},
        inference_seed_consumer: %{
          deps: [:inference_seed_child],
          files: %{"test/observed_test.exs" => @test_source}
        }
      })

    for app <- [:inference_seed_child, :inference_seed_consumer] do
      path = Path.join([fixture.umbrella, "apps", to_string(app), "lib/untouched.ex"])
      File.mkdir_p!(Path.dirname(path))

      File.write!(path, """
      defmodule #{Macro.camelize(to_string(app))}.Untouched do
        File.write!("untouched-compiles", "compiled\n", [:append])
        def ok, do: :ok
      end
      """)
    end

    {output, status} = Mutare.Test.Project.compile(fixture.umbrella)
    assert status == 0, output
    File.rm!(Path.join(fixture.umbrella, "apps/inference_seed_child/compiled-options"))

    schema = %Schema{
      metamutants: %{
        "apps/inference_seed_child/lib/observed.ex" => @observing_source <> "\n# metamutant\n"
      }
    }

    Sandbox.prepare(fixture.umbrella, schema,
      sandbox: fixture.sandbox,
      project: Mutare.Project.resolve(fixture.umbrella)
    )

    compile_and_observe(fixture.sandbox, "apps/inference_seed_child/compiled-options")

    for app <- [:inference_seed_child, :inference_seed_consumer] do
      assert File.read!(
               Path.join([fixture.sandbox, "apps", to_string(app), "untouched-compiles"])
             ) == "compiled\n"
    end

    {output, status} = Invocation.mix(fixture.sandbox, ["test"], 0)
    assert status == 0, output
    refute output =~ "Compiling "
  end

  @tag skip:
         if(:module_definition in Code.available_compiler_options(),
           do: false,
           else: "interpreted module definitions require Elixir 1.20"
         )
  test "interpreted module definitions preserve poison recovery and can return to compiled mode" do
    fixture =
      Mutare.Test.Project.build(:inference_interpreted, %{
        "lib/observed.ex" => """
        defmodule InterpretedObserved do
          File.write!("module-mode", inspect(Code.get_compiler_option(:module_definition)))
          def add(a, b), do: a + b
          def gte?(a, b), do: a >= b
        end
        """,
        "test/observed_test.exs" => """
        defmodule InterpretedObservedTest do
          use ExUnit.Case

          test "gte boundary" do
            assert InterpretedObserved.gte?(5, 5)
            refute InterpretedObserved.gte?(4, 5)
          end
        end
        """
      })

    # This remains a target opt-in, not a Mutare default. Restoring :compiled on
    # the same retained sandbox must also restore the ordinary compilation mode.
    for mode <- [:interpreted, :compiled] do
      File.write!(Path.join(fixture.project, "mix.exs"), """
      defmodule InferenceInterpreted.MixProject do
        use Mix.Project

        def project do
          [app: :inference_interpreted, version: "0.0.0",
           elixirc_options: [module_definition: #{inspect(mode)}]]
        end
      end
      """)

      assert {:ok, run} =
               Mutare.run(fixture.project,
                 sandbox: fixture.sandbox,
                 mutators: [Mutare.Test.PoisonMutator, Mutare.Mutators.Relational]
               )

      assert Enum.count(run.results, &(&1.status == :poisoned)) == 1
      assert Enum.count(run.results, &(&1.status == :killed)) == 2
      assert File.read!(Path.join(fixture.sandbox, "module-mode")) == inspect(mode)
    end
  end

  # A coverage-probe boot: the `:coverage` run option, dump landing in the sandbox.
  defp coverage(sandbox),
    do: {Path.join(sandbox, Mutare.Coverage.Recorder.dump_file()), sandbox}

  defp prepare(fixture) do
    Sandbox.prepare(fixture.project, %Schema{}, sandbox: fixture.sandbox)
  end

  defp compile_and_observe(sandbox, observation \\ "compiled-options") do
    {output, status} =
      Invocation.mix(sandbox, ["compile" | CompilerOptions.compile_args()], 0, compile: true)

    assert status == 0, output

    expected =
      if :infer_signatures in Code.available_compiler_options(),
        do: "false\n",
        else: ":unsupported\n"

    assert File.read!(Path.join(sandbox, observation)) == expected
    expected
  end
end
