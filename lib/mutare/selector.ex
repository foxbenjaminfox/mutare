defmodule Mutare.Selector do
  @moduledoc """
  Runtime selection of the active mutant.

  The active mutant is constant for an entire suite run, so it is read once from
  the environment at boot and stashed in `:persistent_term` (O(1) reads, built
  for write-once/read-many). Every selector site in the metamutant reads this
  key on each execution.

  This module owns both sides of that contract: `Mutare.Metamutant` uses its key
  and baseline when building selectors, while `Mutare.Sandbox` renders
  `bootstrap_ast/0` into the target project's dependency-free test bootstrap.

  ## Self-hosting: a private key for the suite-under-test

  When the target *is* Mutare, the suite-under-test contains Mutare's own tests,
  many of which drive selection directly (`put/1`, building fixtures via
  `Mutare.Transform`) to exercise the machinery. If those tests wrote the *same*
  `:persistent_term` slot the harness uses to hold the mutant-under-test, they
  would clobber it mid-run — the active mutant would silently revert to baseline
  and every mutant whose killing test ran afterwards would register a **false
  survivor** (see `NOTES.md`, "Self-hosting").

  So the *runtime* key is configurable: `key/0` returns `default_key/0`
  (`:mutare_active`, the harness key) unless `override_env/0` names another, in
  which case the suite plays in that private slot. `Mutare.Sandbox.Command` sets
  that env var (to `suite_key/0`) on every sandbox `mix` it spawns, so the
  suite-under-test reads/writes `:mutare_active__suite` while the *real*
  metamutant — whose sites and bootstrap bake `default_key/0` as literals at
  transform time, in the harness process where the override is unset — keeps
  reading `:mutare_active`. The two never collide. On a normal target there is no
  `Mutare.Selector` compiled in, so the env is inert.
  """

  @key :mutare_active
  @env_var "MUTANT_UNDER_TEST"
  @baseline 0
  # The env var that lets a sandbox suite-under-test select on a private key (see
  # the moduledoc). Set by `Mutare.Sandbox.Command` on every sandbox `mix`; unset
  # in the harness process, so harness-side site/bootstrap baking keeps `@key`.
  @override_env "MUTARE_SELECTOR_KEY"
  @suite_key "mutare_active__suite"

  @doc """
  The `:persistent_term` key the metamutant reads at runtime.

  `default_key/0` (`:mutare_active`) unless `override_env/0` names another — the
  one knob self-hosting needs so the suite-under-test does not clobber the
  harness's active-mutant slot (see the moduledoc).
  """
  @spec key() :: atom()
  def key do
    case System.get_env(@override_env) do
      nil -> @key
      "" -> @key
      name -> String.to_atom(name)
    end
  end

  @doc "The harness selection key (`:mutare_active`) — the default `key/0`, env-independent."
  @spec default_key() :: atom()
  def default_key, do: @key

  @doc "Env var a sandbox run sets to give the suite-under-test a private selection key."
  @spec override_env() :: String.t()
  def override_env, do: @override_env

  @doc "The private key (`override_env/0`'s value) the suite-under-test selects on under dogfooding."
  @spec suite_key() :: String.t()
  def suite_key, do: @suite_key

  @doc "The environment variable a runner sets to pick the active mutant."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc "The baseline id (no mutant active)."
  @spec baseline() :: non_neg_integer()
  def baseline, do: @baseline

  @doc """
  Dependency-free code that reads the selector environment variable and stores
  the active mutant id.

  `Mutare.Sandbox` renders this AST directly into the target project's test
  bootstrap, so the target does not need Mutare as a dependency.
  """
  @spec bootstrap_ast() :: Macro.t()
  def bootstrap_ast do
    key = @key
    env_var = @env_var
    baseline = @baseline

    quote do
      :persistent_term.put(
        unquote(key),
        case System.get_env(unquote(env_var)) do
          nil -> unquote(baseline)
          "" -> unquote(baseline)
          raw -> String.to_integer(raw)
        end
      )
    end
  end

  @doc "Set the active mutant id directly for in-process execution."
  @spec put(non_neg_integer()) :: :ok
  # Writes `key/0` — the *runtime* key, so under dogfooding this lands in the
  # suite-under-test's private slot (`suite_key/0`), not the harness's
  # `:mutare_active`. That key isolation is why this is no longer `# mutare:ignore`d:
  # exercising `put/1` used to clobber the harness's active mutant (a false
  # survivor), but now it cannot, so its guard is honestly killable when dogfooding.
  def put(id) when is_integer(id) and id >= 0, do: :persistent_term.put(key(), id)

  @doc "The active mutant id for in-process execution (`0` if unset)."
  @spec active() :: non_neg_integer()
  def active, do: :persistent_term.get(key(), @baseline)
end
