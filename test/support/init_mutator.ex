defmodule Mutare.Test.InitMutator do
  @moduledoc """
  A reference custom mutator with a parsed option surface, used in tests to exercise
  `c:Mutare.Mutator.init/1`: options are validated once, when the `{module, opts}` entry
  is resolved to a `Mutare.Mutator.Spec` (an invalid option raises there, at startup),
  and every `mutate/2` reads the normalized `context.config` instead of re-parsing
  `context.opts`.
  """
  @behaviour Mutare.Mutator

  @impl Mutare.Mutator
  def name, do: :initialized

  @impl Mutare.Mutator
  def init(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "Mutare.Test.InitMutator options must be a keyword list, got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- [:replacement] do
      [] ->
        %{replacement: Keyword.get(opts, :replacement)}

      unknown ->
        raise ArgumentError,
              "unknown Mutare.Test.InitMutator options: #{inspect(unknown)} — " <>
                "the only option is :replacement"
    end
  end

  # The parsed config arrives on every offered node; no per-node option parsing.
  @impl Mutare.Mutator
  def mutate({:__block__, _meta, [n]}, %{config: %{replacement: replacement}})
      when is_integer(n) and is_integer(replacement) do
    # Clean meta so the new value renders (not the original token).
    [{:__block__, [], [replacement]}]
  end

  def mutate(_node, _context), do: :skip
end
