defmodule Mutare.CLI.DiagnosticsTest do
  # The stderr warnings for configuration that matched nothing: `:call_routes` and `:argument_marks`
  # entries (the `:skip_lifting` mirrors). The detection lives in `Mutare.Schema` (see
  # `schema_test.exs`); this pins the wording a user sees.
  #
  # `async: false`: these capture the global `:stderr` device — one of them to assert it stays
  # *empty*, which any concurrently running module's `IO.warn` would break.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mutare.CLI.Diagnostics
  alias Mutare.{Options, Schema}

  test "an ineffective :call_routes entry is named as the user wrote it" do
    schema = %Schema{
      ineffective_call_routes: [
        Mutare.CallRouting.Spec.new(Mixpanel, :track, 2, :skip),
        Mutare.CallRouting.Spec.new(Ecto.Query, :*, :any, :raw)
      ]
    }

    err = capture_io(:stderr, fn -> Diagnostics.surface(schema, Options.new([])) end)

    assert err =~ "warning: :call_routes entry {Mixpanel, :track, 2} matched no call"
    assert err =~ "warning: :call_routes entry {Ecto.Query, :*, :any} matched no call"
    assert err =~ "a piped receiver counts toward it"
  end

  test "an ineffective :argument_marks entry names the label too" do
    schema = %Schema{ineffective_argument_marks: [{MyApp.Cache, :put, 2, [1], :timeout}]}

    err = capture_io(:stderr, fn -> Diagnostics.surface(schema, Options.new([])) end)

    assert err =~ "warning: :argument_marks entry MyApp.Cache.put/2 (:timeout) matched no call"
  end

  test "nothing ineffective prints nothing, and --strict-ignores leaves config warnings alone" do
    assert capture_io(:stderr, fn -> Diagnostics.surface(%Schema{}, Options.new([])) end) == ""

    # Config entries are warning-only even under `--strict-ignores`, which is scoped to the
    # `# mutare:` comment namespace.
    schema = %Schema{
      ineffective_call_routes: [Mutare.CallRouting.Spec.new(Mixpanel, :track, 2, :skip)]
    }

    capture_io(:stderr, fn ->
      assert :ok = Diagnostics.surface(schema, Options.new(strict_ignores: true))
    end)
  end
end
