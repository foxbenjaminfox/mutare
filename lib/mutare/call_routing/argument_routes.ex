defmodule Mutare.CallRouting.ArgumentRoutes do
  @moduledoc """
  The resolved argument treatments returned by
  `c:Mutare.CallRouting.route_arguments/1`.

  One treatment per entry of `Mutare.CallRouting.Call.arguments`, in order. `new/2` validates
  that shape immediately (and normalizes each treatment — a keyed refinement written
  `[leading, key: treatment, …]` is stored in its internal form); Mutare validates callback
  results again at the boundary.
  """

  alias Mutare.CallRouting.Call
  alias Mutare.CallRouting.Spec

  @opaque t :: %__MODULE__{treatments: [Mutare.CallRouting.treatment()]}

  @enforce_keys [:treatments]
  defstruct [:treatments]

  @doc """
  Build the routes for `call`: one treatment per argument, in argument order — the order a
  static route declaration uses.
  """
  @spec new(Call.t(), [Mutare.CallRouting.treatment()]) :: t()
  def new(%Call{} = call, treatments) when is_list(treatments) do
    expected = length(call.arguments)

    if length(treatments) != expected do
      raise ArgumentError,
            "expected #{expected} argument treatments, got #{length(treatments)}: " <>
              inspect(treatments)
    end

    %__MODULE__{treatments: Enum.map(treatments, &normalize!/1)}
  end

  @doc "The treatments, aligned with the call's arguments."
  @spec treatments(t()) :: [Mutare.CallRouting.treatment()]
  def treatments(%__MODULE__{treatments: treatments}), do: treatments

  # Validate a (possibly forged — the struct can be built by hand) routes value against the concrete
  # call, returning the routes with every treatment normalized, or a description of what is wrong.
  @doc false
  @spec validate(term(), Call.t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{treatments: treatments}, %Call{} = call) when is_list(treatments) do
    cond do
      length(treatments) != length(call.arguments) ->
        {:error, "must contain one treatment per call argument"}

      not Enum.all?(treatments, &valid_treatment?/1) ->
        {:error, "contains an unrecognised treatment"}

      true ->
        {:ok, %__MODULE__{treatments: Enum.map(treatments, &normalize!/1)}}
    end
  end

  def validate(%__MODULE__{}, _call), do: {:error, "contains a non-list treatments field"}

  def validate(_other, _call),
    do: {:error, "must return a Mutare.CallRouting.ArgumentRoutes value"}

  # One vocabulary, one validator: `Mutare.CallRouting.Spec.normalize_position!/1` is what a static
  # route's positions go through, so a classifier's dynamic treatments are held to the same grammar
  # (and get the same pointed messages — a `:skip` here names `:raw`).
  defp normalize!(treatment) do
    Spec.normalize_position!(treatment)
  rescue
    error in ArgumentError ->
      reraise ArgumentError,
              [message: "invalid argument treatment: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  defp valid_treatment?(treatment) do
    _ = Spec.normalize_position!(treatment)
    true
  rescue
    ArgumentError -> false
  end
end
