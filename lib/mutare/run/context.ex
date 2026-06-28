defmodule Mutare.Run.Context do
  @moduledoc """
  The **runtime wiring** for a mutation run: the validated `Mutare.Options`
  (configuration) bundled with the things that are *not* configuration — the
  resolved `Mutare.Project` (copy-root + mutate-scope, derived from the target
  path and `--app`/`--workspace`) and the four optional live-progress hooks
  (`reporter`, `on_phase`, `on_start`, `on_scan`).

  `on_phase` receives both the phase-transition atoms (`:compiling` → `:baseline`
  → `:coverage_probe` → `{:running, total}`) and structured **detail** events the
  runner fires alongside them — `{:compiled, ms}`, `{:baseline_done, ms}`,
  `{:coverage_done, summary}`, `{:run_config, cfg}` — carrying the behind-the-scenes
  numbers `--verbose` renders. A custom hook should ignore events it doesn't know
  (the in-tree consumer, `Mutare.Report.Live`, has a catch-all).

  Splitting these off `Mutare.Options` keeps that struct pure configuration. The
  pipeline (`Mutare.Schema`, `Mutare.Sandbox`, `Mutare.Runner`) threads a
  `Run.Context`, reading config from `context.options` and wiring from the
  context's own fields.

  ## Wrap-at-boundary

  `new/1` is the normalization boundary, mirroring `Mutare.Options.new/1`: it
  accepts an existing `Run.Context` (idempotent), a bare `Mutare.Options` (no
  wiring), or a keyword list. For a keyword list it **splits** the wiring keys
  (`:project` + the hooks) from the configuration keys, validating the former here
  and routing the latter through `Mutare.Options.new/1`. So an existing
  keyword-list call site — `Schema.build(root, project: p, mutators: m)` — keeps
  working unchanged: the wiring rides into the context, the rest into options.

  `new/2` is the convenience the Mix task uses to attach wiring to an already
  resolved `Options` (`Run.Context.new(options, project: project)`).
  """

  alias Mutare.{Options, Project}

  @type hook :: (term() -> any()) | nil

  @type t :: %__MODULE__{
          options: Options.t(),
          project: Project.t() | nil,
          reporter: hook(),
          on_phase: hook(),
          on_start: hook(),
          on_scan: hook(),
          defer_site_code: boolean()
        }

  defstruct options: %Options{},
            project: nil,
            reporter: nil,
            on_phase: nil,
            on_start: nil,
            on_scan: nil,
            # Whether the scan should **defer** rendering each site's before/after diff text,
            # re-deriving it later only for the sites a reporter actually shows (`Mutare.Runner.Hydrate`).
            # A run-mode decision, not user config: the Mix task sets it `true` only when it knows the
            # active reporters need code for survivors alone (no `--verbose`, no `:json`/`:html`), so the
            # build skips the per-mutant `Sourceror` render that dominates it. `false` (the default) keeps
            # the eager behaviour — what every library caller and a custom `:reporter` hook (which may read
            # any result's code) safely gets. Read by `Mutare.Schema` (scan) and `Mutare.Runner` (hydration).
            defer_site_code: false

  # The wiring keys, split out of a keyword list before the rest goes to `Options.new/1`. Anything
  # not here is a configuration key (or an unknown key `Options` rejects).
  @context_keys [:project, :reporter, :on_phase, :on_start, :on_scan, :defer_site_code]

  @doc """
  Normalize an input into a `Run.Context`.

  Accepts an existing `Run.Context` (returned as-is), a `Mutare.Options` (wrapped
  with no wiring), or a keyword list (wiring keys split out and validated, the
  rest validated through `Mutare.Options.new/1`).

      iex> ctx = Mutare.Run.Context.new(mutators: [:arithmetic], on_scan: fn _ -> :ok end)
      iex> {Enum.map(ctx.options.mutators, & &1.name), is_function(ctx.on_scan, 1)}
      {[:arithmetic], true}

      iex> ctx = Mutare.Run.Context.new(workers: 2)
      iex> Mutare.Run.Context.new(ctx) == ctx
      true
  """
  @spec new(t() | Options.t() | keyword()) :: t()
  def new(%__MODULE__{} = context), do: context
  def new(%Options{} = options), do: %__MODULE__{options: options}

  def new(opts) when is_list(opts) do
    {wiring, config} = Keyword.split(opts, @context_keys)
    build(Options.new(config), wiring)
  end

  @doc """
  Build a `Run.Context` from already-resolved `options` (an `Options` or a keyword
  list) plus a keyword list of wiring (`:project` and/or the hooks).
  """
  @spec new(Options.t() | keyword(), keyword()) :: t()
  def new(%Options{} = options, wiring) when is_list(wiring), do: build(options, wiring)

  def new(opts, wiring) when is_list(opts) and is_list(wiring),
    do: build(Options.new(opts), wiring)

  defp build(%Options{} = options, wiring) do
    %__MODULE__{
      options: options,
      project: validate_project!(wiring[:project]),
      reporter: validate_callback!(:reporter, wiring[:reporter]),
      on_phase: validate_callback!(:on_phase, wiring[:on_phase]),
      on_start: validate_callback!(:on_start, wiring[:on_start]),
      on_scan: validate_callback!(:on_scan, wiring[:on_scan]),
      defer_site_code: wiring[:defer_site_code] == true
    }
  end

  @doc """
  The 1-arity hook bound to `field` (`:reporter`/`:on_phase`/`:on_start`/`:on_scan`),
  or a no-op when unset — so `Mutare.Runner` and `Mutare.Schema` invoke it
  unconditionally without each re-stating the `|| fn _ -> :ok end` default. The
  single home for that default.
  """
  @spec hook(t(), atom()) :: (term() -> any())
  def hook(%__MODULE__{} = context, field) do
    # mutare:ignore[convention, return_value] the no-op's return is discarded (side-effect-only hook)
    Map.get(context, field) || fn _ -> :ok end
  end

  @doc """
  Ensure the context carries a `Mutare.Project`, resolving one from `root` if it is
  unset. The entry points (`Mutare.Runner.run/2`, the Mix task) resolve the project
  from the target path + scope flags; the direct `Mutare.run/2` API leaves it `nil`,
  so it is resolved here as a single-app project at `root`.
  """
  @spec ensure_project(t(), Path.t()) :: t()
  def ensure_project(%__MODULE__{project: nil} = context, root),
    do: %{context | project: Project.resolve(root)}

  def ensure_project(%__MODULE__{} = context, _root), do: context

  # --- wiring validators (the config validators live in `Mutare.Options.Registry`) ---

  defp validate_callback!(_field, nil), do: nil
  defp validate_callback!(_field, fun) when is_function(fun, 1), do: fun

  defp validate_callback!(field, fun) do
    raise ArgumentError, "#{inspect(field)} must be a 1-arity function, got: #{inspect(fun)}"
  end

  # Derived state, not raw user config: the entry points resolve a `Mutare.Project` from the target
  # path + scope flags and set it here. `nil` is treated as a single-app project downstream.
  defp validate_project!(nil), do: nil
  defp validate_project!(%Project{} = project), do: project

  defp validate_project!(other) do
    raise ArgumentError, ":project must be a Mutare.Project or nil, got: #{inspect(other)}"
  end
end
