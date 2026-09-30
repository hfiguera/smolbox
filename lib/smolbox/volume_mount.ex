defmodule SmolBox.VolumeMount do
  @moduledoc "A volume ID in the machine's authorized scope and its guest target. Attachments last until verified machine deletion, including while stopped."
  alias SmolBox.{Mount, Validation}
  @enforce_keys [:volume_id, :target]
  defstruct @enforce_keys ++ [readonly: false]
  @type t :: %__MODULE__{volume_id: String.t(), target: String.t(), readonly: boolean()}
  @spec new(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, SmolBox.Error.t()}
  def new(id, target, options \\ []) do
    if Validation.keys?(options, [:readonly]) do
      m = struct!(__MODULE__, [volume_id: id, target: target] ++ options)
      if valid?(m), do: {:ok, m}, else: invalid()
    else
      invalid()
    end
  end

  @doc false
  def valid?(%__MODULE__{} = m),
    do:
      Validation.struct_shape?(m, __MODULE__) and Validation.identifier?(m.volume_id) and
        Mount.target?(m.target) and is_boolean(m.readonly)

  def valid?(_), do: false
  @doc false
  def valid_list?(mounts),
    do:
      Validation.list?(mounts, 8) and Enum.all?(mounts, &valid?/1) and Mount.targets?(mounts) and
        length(Enum.uniq_by(mounts, & &1.volume_id)) == length(mounts) and
        mounts == Enum.sort_by(mounts, & &1.target)

  @doc false
  def normalize(mounts) do
    if Validation.list?(mounts, 8) and Enum.all?(mounts, &valid?/1) do
      sorted = Enum.sort_by(mounts, & &1.target)
      if valid_list?(sorted), do: {:ok, sorted}, else: invalid()
    else
      invalid()
    end
  end

  defp invalid, do: {:error, %SmolBox.Error{category: :validation, operation: :volume_mount}}
end
