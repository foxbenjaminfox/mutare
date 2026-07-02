defmodule Mutare.EnvironmentTest do
  use ExUnit.Case, async: true

  alias Mutare.{EnvironmentError, Extension, Mutators}
  alias Mutare.Mutator.Spec

  alias Mutare.Test.{
    EnvironmentExtension,
    EnvironmentMutator,
    MalformedEnvironmentMutator,
    MissingEnvironmentExtension,
    MissingEnvironmentInitMutator,
    MissingEnvironmentMutator,
    PartialEnvironmentMutator
  }

  describe "EnvironmentError.verify!/1" do
    test "a module without required_modules/0 is assumed environment-independent" do
      assert EnvironmentError.verify!(Mutare.Mutators.Arithmetic) == :ok
    end

    test "an unloadable module passes unchecked (other validation reports it)" do
      assert EnvironmentError.verify!(Mutare.Test.AbsentLibrary.Plugin) == :ok
    end

    test "satisfied requirements pass" do
      assert EnvironmentError.verify!(EnvironmentMutator) == :ok
    end

    test "a missing module raises with structured fields" do
      error =
        assert_raise EnvironmentError, fn ->
          EnvironmentError.verify!(MissingEnvironmentMutator)
        end

      assert error.plugin == MissingEnvironmentMutator

      assert error.missing == [
               Mutare.Test.AbsentLibrary.Schema,
               Mutare.Test.AbsentLibrary.Query
             ]
    end

    test "the core-owned message names the plugin, the modules, and the deployment requirement" do
      message =
        assert_raise(EnvironmentError, fn ->
          EnvironmentError.verify!(MissingEnvironmentMutator)
        end)
        |> Exception.message()

      assert message =~
               "Mutare.Test.MissingEnvironmentMutator requires " <>
                 "Mutare.Test.AbsentLibrary.Schema and Mutare.Test.AbsentLibrary.Query, " <>
                 "which are not loadable in this Mutare process"

      assert message =~ "must run as a dependency of the app under test"
      assert message =~ "External-source operation is not supported"
    end

    test "names only the missing modules, not the whole declared set" do
      message =
        assert_raise(EnvironmentError, fn ->
          EnvironmentError.verify!(PartialEnvironmentMutator)
        end)
        |> Exception.message()

      # Enum is declared but loadable; only the absent module is reported (singular verb).
      assert message =~ "requires Mutare.Test.AbsentLibrary.Query, which is not loadable"
      refute message =~ "Enum"
    end

    test "a malformed required_modules/0 return is rejected loudly" do
      assert_raise ArgumentError,
                   ~r/MalformedEnvironmentMutator\.required_modules\/0 must return a list of modules/,
                   fn -> EnvironmentError.verify!(MalformedEnvironmentMutator) end
    end
  end

  describe "mutator spec resolution" do
    test "a mutator with a satisfied environment resolves normally" do
      assert [%Spec{module: EnvironmentMutator, name: :environment}] =
               Mutators.resolve([EnvironmentMutator])
    end

    test "a bare entry with a missing environment aborts resolution" do
      assert_raise EnvironmentError, fn -> Mutators.resolve([MissingEnvironmentMutator]) end
    end

    test "a configured {module, opts} entry is checked too" do
      assert_raise EnvironmentError, fn ->
        Mutators.resolve([{MissingEnvironmentMutator, as: :renamed}])
      end
    end

    test "the environment is checked before init/1 runs" do
      # The fixture's init/1 always raises; resolution must fail on the deployment error,
      # never reach whatever init/1 does without the library.
      assert_raise EnvironmentError, fn ->
        Mutators.resolve([{MissingEnvironmentInitMutator, option: 1}])
      end
    end
  end

  describe "extension validation" do
    test "an extension with a satisfied environment validates normally" do
      assert [%Extension.Spec{module: EnvironmentExtension}] =
               Extension.validate!([EnvironmentExtension])
    end

    test "an extension with a missing environment aborts validation" do
      assert_raise EnvironmentError, fn -> Extension.validate!([MissingEnvironmentExtension]) end
    end

    test "a {module, opts} extension entry is checked too" do
      assert_raise EnvironmentError, fn ->
        Extension.validate!([{MissingEnvironmentExtension, domain: "errors"}])
      end
    end
  end
end
