defmodule Mutare.MacroRouting do
  @moduledoc """
  Capability behaviour for declaring static macro-argument routing.

  A macro can place an argument in a pattern or compile-time DSL position where Mutare's
  ordinary runtime descent would be invalid. A module implementing this behaviour contributes
  declarative routes for those arguments without producing mutations itself.

  The capability is deliberately independent of how the module is enabled:

    * a non-mutating module listed under `:extensions` may implement it alongside
      `Mutare.UseExpansion`;
    * a `Mutare.Mutator` may implement it when its whole-node mutation depends on static routing.

  Enabled mutators and extensions are inspected automatically, so either form still needs only
  one configuration entry.

      defmodule MyApp.GettextExtension do
        @behaviour Mutare.MacroRouting

        @impl Mutare.MacroRouting
        def macro_routes do
          [
            {Gettext.Macros, :gettext, 1, [:skip]},
            {Gettext.Macros, :ngettext, 3, [:skip, :skip, :expression]}
          ]
        end
      end

  Routes here are static vocabulary and may use only `:expression`, `:pattern`,
  `:binding_pattern`, or `:skip`. Host-dependent `:hosted` and `:routing` entries belong to
  `c:Mutare.Mutator.MacroHost.hosted_routes/0`, which ties them explicitly to the mutator that
  supplies `host/2` or `macro_routing/1`.

  See `Mutare.Macro.Spec` for entry forms, wildcards, and argument treatments.
  """

  @doc """
  Return static macro routes as `{module, name, arity, treatment}` or
  `{module, name, treatment}` entries.

  These declarations are global library facts and therefore receive no per-extension or
  per-mutator options. Shape-dependent or selector-hosting routes belong to
  `c:Mutare.Mutator.MacroHost.hosted_routes/0`.
  """
  @callback macro_routes() :: [tuple() | Mutare.Macro.Spec.t()]
end
