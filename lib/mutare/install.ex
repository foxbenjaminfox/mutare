defmodule Mutare.Install do
  @moduledoc false
  # The dependency lines Mutare suggests, kept in one place. `mix mutare.install` writes
  # them, its fallback (when igniter is missing) prints them, and `mix check` fails unless
  # the README's install snippet is `readme_snippet/0` verbatim — so the release commit
  # that bumps `@version` in mix.exs cannot leave any of them behind.

  @version Mix.Project.config()[:version]

  # Companion packages release independently of Mutare, so they are suggested with an
  # open requirement: `mix deps.get` resolves whatever version is current and compatible
  # (each companion pins the Mutare versions it supports in its own mix.exs). This keeps
  # the two uncoupled — a Mutare release never has to re-pin or re-release the companions
  # in lockstep, and a companion release needs no Mutare release to be picked up.
  @companion_requirement ">= 0.0.0"

  # Each companion package under the `mix mutare.install` detection key that adds it, in
  # the order the installer adds them (and the README's table lists them).
  @companions [
    plug: :mutare_plug,
    phoenix: :mutare_phoenix,
    phoenix_live_view: :mutare_phoenix_live_view,
    ecto: :mutare_ecto,
    oban: :mutare_oban,
    decimal: :mutare_decimal,
    swoosh: :mutare_swoosh,
    phoenix_swoosh: :mutare_phoenix_swoosh,
    gettext: :mutare_gettext,
    phoenix_ecto: :mutare_phoenix_ecto
  ]

  @doc "This build's version."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The requirement to suggest for this build of Mutare: `requirement/1` of `version/0`."
  @spec requirement() :: String.t()
  def requirement, do: requirement(@version)

  @doc """
  The requirement to suggest for `version`: compatible releases from `version` on.

  On 0.x a minor release may break, so the requirement names the full version, which
  holds the window to that minor (`0.4.3` ⇒ `~> 0.4.3`, i.e. `>= 0.4.3 and < 0.5.0`);
  `~> 0.4` would admit 0.5. From 1.0 a minor is compatible, so major.minor is suggested
  (`1.2.3` ⇒ `~> 1.2`) — `~> 1.2.3` would shut out 1.3.

  A pre-release keeps its release's window, floored at the pre-release itself
  (`0.5.0-rc.1` ⇒ `~> 0.5.0-rc.1`, `1.2.0-rc.1` ⇒ `~> 1.2-rc.1`). A requirement that names
  a pre-release is what lets Hex resolve one at all, and the window then admits the later
  pre-releases and the final release, but not the next breaking one.
  """
  @spec requirement(String.t()) :: String.t()
  def requirement(version) do
    %Version{major: major, minor: minor, patch: patch, pre: pre} = Version.parse!(version)

    window = if major == 0, do: "0.#{minor}.#{patch}", else: "#{major}.#{minor}"
    "~> " <> window <> pre_suffix(pre)
  end

  defp pre_suffix([]), do: ""
  defp pre_suffix(pre), do: "-" <> Enum.join(pre, ".")

  @doc "The requirement every companion package is suggested with."
  @spec companion_requirement() :: String.t()
  def companion_requirement, do: @companion_requirement

  @doc "Each companion package under the installer's detection key that adds it."
  @spec companions() :: [{atom(), atom()}]
  def companions, do: @companions

  @doc "The `deps/0` entry for `name` at `requirement`, scoped as the installer scopes it."
  @spec dep_line(atom(), String.t()) :: String.t()
  def dep_line(name, requirement) do
    "{#{inspect(name)}, #{inspect(requirement)}, only: [:dev, :test], runtime: false}"
  end

  @doc "The README's by-hand install snippet: Mutare, then every companion commented out."
  @spec readme_snippet() :: String.t()
  def readme_snippet do
    companions =
      for {_framework, package} <- @companions,
          do: "# #{dep_line(package, @companion_requirement)}\n"

    IO.iodata_to_binary([
      "# mix.exs\n",
      dep_line(:mutare, requirement()),
      "\n# Optionally, also:\n"
      | companions
    ])
  end
end
