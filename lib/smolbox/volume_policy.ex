defmodule SmolBox.VolumePolicy do
  @moduledoc """
  Operator approval of one worker's exclusive local volume root on smolvm 1.20.2 or 1.22.0.
  The root must be the canonical upstream volumes directory, free of symlink
  substitution and external writers. The operator must verify file permissions
  across replacement machines. `size_gb` reservations are advisory, not quotas.
  """
  @enforce_keys [:id, :root]
  defstruct @enforce_keys
  @type t :: %__MODULE__{id: String.t(), root: String.t()}
  @spec new(String.t(), String.t()) :: {:ok, t()} | {:error, SmolBox.Error.t()}
  def new(id, root) do
    p = %__MODULE__{id: id, root: root}

    if valid?(p),
      do: {:ok, p},
      else: {:error, %SmolBox.Error{category: :validation, operation: :volume_policy}}
  end

  @doc false
  def valid?(%__MODULE__{} = p),
    do:
      SmolBox.Validation.struct_shape?(p, __MODULE__) and SmolBox.Validation.identifier?(p.id) and
        SmolBox.Mount.path?(p.root) and byte_size(p.root) <= 4059

  def valid?(_), do: false
end
