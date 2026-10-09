defmodule Mutare.Transform.Inputs do
  @moduledoc false
  # The keyword boundary for one transform pass. Defaults and validation belong here;
  # downstream stages read this value rather than interpreting the original options again.
  # `config` is a template: the source's generated names and ignore directives are added
  # after parsing. Its ID origin also seeds ClaimState, so those cannot start apart.
  #
  # Constructed anew for every pass, including invariant re-emission and deferred site
  # rendering. Mutator initialization and extension declarations retain their per-pass
  # execution; neither resolved registries nor callback results are cached across passes.

  alias Mutare.{Extension, Lifting, Mutator, Mutators}
  alias Mutare.CallRouting.Registry
  alias Mutare.Transform.{ClaimState, Config, Diagnostics}
  alias Mutare.Transform.Resolve.ArgumentMarks

  @enforce_keys [:config, :sink, :selection, :expand_uses, :extensions, :call_routes, :marks]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          config: Config.t(),
          sink: ClaimState.sink(),
          selection: Mutare.LineScope.t() | nil,
          expand_uses: boolean(),
          extensions: [Extension.Spec.t()],
          call_routes: Registry.registry(),
          marks: ArgumentMarks.t()
        }

  @default_mutators Mutators.all()

  @spec new(keyword()) :: t()
  def new(opts) do
    defaults = %Config{}
    verify? = Keyword.get(opts, :verify_invariants, defaults.verify_invariants)

    config = %Config{
      file: Keyword.get(opts, :file, defaults.file),
      runtime_namespace: Keyword.get(opts, :runtime_namespace, defaults.runtime_namespace),
      id_origin: Keyword.get(opts, :start_id, defaults.id_origin),
      skip_ids: Keyword.get(opts, :skip_ids, defaults.skip_ids),
      emit_ids: Keyword.get(opts, :emit_ids, defaults.emit_ids),
      clean_functions: Keyword.get(opts, :clean_functions, defaults.clean_functions),
      skip_regions: Keyword.get(opts, :skip_regions, defaults.skip_regions),
      clean_threshold: Keyword.get(opts, :clean_threshold, defaults.clean_threshold),
      warnings: Keyword.get(opts, :warnings, defaults.warnings),
      render_site_code:
        Keyword.get(opts, :render_site_code, defaults.render_site_code) or verify?,
      summarize_sites: Keyword.get(opts, :summarize_sites, defaults.summarize_sites),
      verify_invariants: verify?
    }

    # Resolution invokes user callbacks too. Keep their advisories under the same policy
    # as the ensuing walk, including when a host enters a nested transform.
    Diagnostics.with_warnings(config.warnings, fn ->
      config = %{
        config
        | mutators: opts |> Keyword.get(:mutators, @default_mutators) |> Mutators.resolve(),
          skip_lifting:
            opts
            |> Keyword.get(:skip_lifting, defaults.skip_lifting)
            |> Lifting.validate_skip_lifting!()
      }

      extensions = opts |> Keyword.get(:extensions, []) |> Extension.validate!()
      routes = Registry.build(Keyword.get(opts, :call_routes, []), config.mutators, extensions)

      marks =
        ArgumentMarks.build(
          config.mutators,
          opts |> Keyword.get(:argument_marks, []) |> Mutator.validate_argument_marks!()
        )

      %__MODULE__{
        config: config,
        sink: Keyword.get(opts, :sink, :render),
        selection: Keyword.get(opts, :selection),
        expand_uses: Keyword.get(opts, :expand_uses, true),
        extensions: extensions,
        call_routes: routes,
        marks: marks
      }
    end)
  end
end
