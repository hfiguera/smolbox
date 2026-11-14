defmodule SmolBox.Kubernetes.Config do
  @moduledoc """
  Explicit host-approved target for the single-node Kubernetes development preview.

  Configuration names an HTTPS API with a trusted CA, credential provider, exact
  cluster/namespace/node/RuntimeClass incarnations and pinned runtime/guard
  identity. `sources` approves public OCI platform manifests containing the
  qualified Python helper prerequisites; it does not discover images or tags.

  Profiles are offline, two-vCPU/1-GiB guests with 20/10-GiB disks and 512-MiB
  host overhead. Capacity is exactly one slot. Kubernetes scheduler memory must
  also include the qualified 512-MiB RuntimeClass overhead. Fractional CPU and
  filesystem headroom remain administrator declarations, not hard quotas.

  Construction validates data without network access or credential resolution.
  Backend admission stays disabled until the complete preview is qualified.
  """
  alias SmolBox.Backend.Budget
  alias SmolBox.{Error, Profile, Source, Validation}
  alias SmolBox.Kubernetes.{Binding, Credentials, NodeEvidence, Shape}
  alias SmolBox.Runtime.Approvals

  @required [
    :id,
    :api_server,
    :ca_file,
    :credential_provider,
    :cluster_id,
    :cluster_anchor_uid,
    :namespace,
    :namespace_uid,
    :node_name,
    :node_uid,
    :node_boot_id,
    :runtime_class,
    :runtime_class_uid,
    :runtime_policy_digest,
    :runtime_identity,
    :sources,
    :profiles,
    :node_evidence
  ]
  @defaults [
    architecture: "x86_64",
    platform: :linux,
    runtime_version: "1.34.0",
    qualification: :development,
    draining: false,
    capacity: %{slots: 1, cpus: 2, memory_mb: 1536, disk_gb: 30},
    allocation_floor: %{storage_gb: 20, overlay_gb: 10, host_overhead_mb: 512},
    budget: %Budget{
      timeout_ms: 300_000,
      max_request_bytes: 2_097_152,
      max_response_bytes: 2_097_152
    }
  ]
  @enforce_keys @required
  @derive {Inspect, only: [:id, :architecture, :qualification]}
  defstruct @required ++ @defaults
  @type t :: %__MODULE__{}

  @doc "Validate an enrolled target; no credential or node callback is invoked."
  def new(options),
    do: Validation.construct(__MODULE__, options, @required, Keyword.keys(@defaults))

  @doc false
  def validate(%__MODULE__{} = value) do
    if Validation.struct_shape?(value, __MODULE__) and identity?(value) and
         connection?(value) and catalogs?(value) and resources?(value),
       do: :ok,
       else: invalid()
  end

  def validate(_value), do: invalid()

  @doc false
  def binding(%__MODULE__{} = value) do
    case Binding.new(binding_fields(value)) do
      {:ok, binding} -> binding
      {:error, error} -> raise error
    end
  end

  @doc false
  def profile?(%Profile{} = profile),
    do:
      Profile.validate(profile) == :ok and profile.network == :offline and
        profile.guest_paths == nil and fixed_shape?(profile) and file_limits?(profile)

  def profile?(_profile), do: false

  defp identity?(value),
    do:
      value.runtime_version == "1.34.0" and value.architecture == "x86_64" and
        value.platform == :linux and value.qualification == :development and
        is_boolean(value.draining) and match?({:ok, _}, Binding.new(binding_fields(value)))

  defp connection?(value),
    do:
      endpoint?(value.api_server) and Shape.absolute_path?(value.ca_file) and
        Credentials.valid?(value.credential_provider) and NodeEvidence.valid?(value.node_evidence) and
        Budget.valid?(value.budget) and value.budget.max_request_bytes <= 2_097_152 and
        value.budget.max_response_bytes <= 2_097_152

  defp catalogs?(value),
    do:
      sources?(value.sources) and Approvals.profiles?(value.profiles) and
        Enum.all?(value.profiles, &profile?/1)

  defp sources?(sources),
    do:
      Validation.list?(sources, 32) and sources != [] and
        Enum.all?(sources, fn source ->
          Source.validate(source) == :ok and source.kind == :oci and
            source.architecture == "x86_64"
        end) and Approvals.unique?(sources, & &1.id)

  defp fixed_shape?(profile),
    do:
      Map.take(profile, [:cpus, :memory_mb, :storage_gb, :overlay_gb, :host_overhead_mb]) ==
        %{cpus: 2, memory_mb: 1024, storage_gb: 20, overlay_gb: 10, host_overhead_mb: 512}

  defp file_limits?(profile),
    do:
      profile.max_file_bytes <= 1_048_576 and profile.max_total_file_bytes <= 4_194_304 and
        profile.max_output_bytes <= 1_048_576

  defp binding_fields(value),
    do:
      value
      |> Map.from_struct()
      |> Map.take([
        :cluster_id,
        :cluster_anchor_uid,
        :namespace,
        :namespace_uid,
        :node_name,
        :node_uid,
        :node_boot_id,
        :runtime_class,
        :runtime_class_uid,
        :runtime_policy_digest,
        :runtime_identity
      ])
      |> Map.put(:target_id, value.id)
      |> Map.to_list()

  defp resources?(value),
    do:
      value.capacity == %{slots: 1, cpus: 2, memory_mb: 1536, disk_gb: 30} and
        value.allocation_floor == %{storage_gb: 20, overlay_gb: 10, host_overhead_mb: 512}

  defp endpoint?(value) when is_binary(value) do
    uri = URI.parse(value)

    Validation.text?(value, 2048) and uri.scheme == "https" and
      Validation.text?(uri.host, 253) and uri.host != "" and
      Validation.integer?(uri.port, 1, 65_535) and uri.path in [nil, "", "/"] and
      uri.userinfo == nil and uri.query == nil and uri.fragment == nil
  rescue
    _invalid -> false
  end

  defp endpoint?(_value), do: false
  defp invalid, do: {:error, %Error{category: :validation, operation: :worker}}
end
