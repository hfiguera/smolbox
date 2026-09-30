defmodule SmolBox.Volume do
  @moduledoc """
  Durable identity, attachment and accounting for a worker-local volume.
  Creating, deleting and unknown records retain their full reservation. No
  operation is replayed automatically. Deleted identities remain tombstones.
  """
  alias SmolBox.{Error, Validation, VolumePolicy}

  @enforce_keys [
    :scope,
    :id,
    :worker_id,
    :worker_volume_id,
    :policy,
    :size_gb,
    :fingerprint,
    :accepted_at_ms,
    :updated_at_ms
  ]
  @derive {Inspect, only: [:scope, :id, :worker_id, :state, :version, :attached_to]}
  defstruct @enforce_keys ++
              [
                state: :creating,
                version: 1,
                attached_to: nil,
                last_error: nil,
                request_version: nil
              ]

  @type key :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          scope: String.t(),
          id: String.t(),
          worker_id: String.t(),
          worker_volume_id: String.t(),
          policy: VolumePolicy.t(),
          size_gb: pos_integer(),
          fingerprint: String.t(),
          accepted_at_ms: non_neg_integer(),
          updated_at_ms: non_neg_integer(),
          state: :creating | :ready | :deleting | :unknown | :deleted,
          version: pos_integer(),
          attached_to: key() | nil,
          last_error: Error.t() | nil,
          request_version: pos_integer() | nil
        }
  @doc false
  def path(v), do: v.policy.root <> "/" <> v.worker_volume_id
  @doc false
  def key(v), do: {v.scope, v.id}
  @doc false
  def resources(v),
    do: %{
      slots: 0,
      cpus: 0,
      memory_mb: 0,
      disk_gb: if(v.state == :deleted, do: 0, else: v.size_gb)
    }

  @doc false
  def validate(%__MODULE__{} = v) do
    if Validation.struct_shape?(v, __MODULE__) and identity?(v) and lifecycle?(v) and
         attachment_valid?(v), do: :ok, else: error(:validation)
  end

  def validate(_), do: error(:validation)

  defp identity?(v) do
    Enum.all?([v.scope, v.id, v.worker_id], &Validation.identifier?/1) and
      is_binary(v.worker_volume_id) and Regex.match?(~r/\Asbv-[0-9a-f]{32}\z/, v.worker_volume_id) and
      VolumePolicy.valid?(v.policy) and Validation.integer?(v.size_gb, 1, 1024) and
      is_binary(v.fingerprint) and Regex.match?(~r/\A[0-9a-f]{64}\z/, v.fingerprint)
  end

  defp lifecycle?(v) do
    v.state in [:creating, :ready, :deleting, :unknown, :deleted] and
      Validation.integer?(v.version, 1, 9_007_199_254_740_991) and
      Validation.timestamp?(v.accepted_at_ms) and Validation.timestamp?(v.updated_at_ms) and
      v.updated_at_ms >= v.accepted_at_ms and receipt?(v)
  end

  defp receipt?(v) do
    (v.request_version == nil or Validation.integer?(v.request_version, 1, v.version)) and
      (v.last_error == nil or SmolBox.ExecutionValidation.error?(v.last_error))
  end

  defp attachment_valid?(v),
    do: attachment?(v.attached_to, v.scope) and (v.attached_to == nil or v.state == :ready)

  defp attachment?(nil, _), do: true
  defp attachment?({scope, id}, scope), do: Validation.identifier?(id)
  defp attachment?(_, _), do: false
  @doc false
  def update(v, changes, now) do
    next =
      struct!(
        v,
        Map.merge(changes, %{version: v.version + 1, updated_at_ms: max(now, v.updated_at_ms)})
      )

    with :ok <- validate(next), do: {:ok, next}
  end

  defp error(category), do: {:error, %Error{category: category, operation: :volume}}
end
