defmodule Mutare.Test.EnvironmentMutator do
  @moduledoc """
  The reference `c:Mutare.Mutator.required_modules/0` mutator: it declares a loadable
  environment, so spec resolution passes the declarative environment guard and builds the
  spec as for any mutator.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :environment

  @impl Mutare.Mutator
  def required_modules, do: [Enum, String]

  @impl Mutare.Mutator
  def mutate(_node), do: :skip
end

defmodule Mutare.Test.MissingEnvironmentMutator do
  @moduledoc """
  A mutator whose declared environment cannot be satisfied — both required modules are
  absent — so resolving it must abort with the core-owned `Mutare.EnvironmentError`
  naming the plugin, the missing modules, and the deployment requirement.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :missing_environment

  @impl Mutare.Mutator
  def required_modules, do: [Mutare.Test.AbsentLibrary.Schema, Mutare.Test.AbsentLibrary.Query]

  @impl Mutare.Mutator
  def mutate(_node), do: :skip
end

defmodule Mutare.Test.PartialEnvironmentMutator do
  @moduledoc """
  A mutator declaring one loadable and one absent module — the error must name only the
  missing one, not the whole declared set.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :partial_environment

  @impl Mutare.Mutator
  def required_modules, do: [Enum, Mutare.Test.AbsentLibrary.Query]

  @impl Mutare.Mutator
  def mutate(_node), do: :skip
end

defmodule Mutare.Test.MissingEnvironmentInitMutator do
  @moduledoc """
  A mutator with both a missing environment and an `init/1` that always raises — pins that
  the environment guard runs *before* `c:Mutare.Mutator.init/1`, so a plugin whose library
  is absent fails on the deployment error, never on whatever its `init/1` does without it.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :missing_environment_init

  @impl Mutare.Mutator
  def required_modules, do: [Mutare.Test.AbsentLibrary.Schema]

  @impl Mutare.Mutator
  def init(_opts), do: raise("init/1 must not run when the environment is missing")

  @impl Mutare.Mutator
  def mutate(_node), do: :skip
end

defmodule Mutare.Test.MalformedEnvironmentMutator do
  @moduledoc """
  A mutator whose `required_modules/0` violates the contract (a bare module, not a list) —
  the guard must reject it loudly rather than crash or silently pass.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :malformed_environment

  @impl Mutare.Mutator
  def required_modules, do: Enum

  @impl Mutare.Mutator
  def mutate(_node), do: :skip
end

defmodule Mutare.Test.EnvironmentExtension do
  @moduledoc """
  A non-mutating routing extension with a satisfied declared environment —
  `required_modules/0` is recognized by export (extensions implement no behaviour that
  declares it), and `Mutare.Extension.validate!/1` passes it.
  """
  @behaviour Mutare.CallRouting

  def required_modules, do: [Enum]

  @impl Mutare.CallRouting
  def call_routes, do: [{Mutare.Test.SomeDSL, :env_frag, 1, [:raw]}]
end

defmodule Mutare.Test.MissingEnvironmentExtension do
  @moduledoc """
  A non-mutating routing extension whose declared environment is absent —
  `Mutare.Extension.validate!/1` must abort with `Mutare.EnvironmentError` before its
  routes are ever collected.
  """
  @behaviour Mutare.CallRouting

  def required_modules, do: [Mutare.Test.AbsentLibrary.Macros]

  @impl Mutare.CallRouting
  def call_routes, do: [{Mutare.Test.AbsentLibrary.Macros, :frag, 1, [:raw]}]
end
