defmodule SmolBox.ExportDestination do
  @moduledoc """
  Host approval for publishing exports to one registry repository.

  `immutable_tags: true` attests that the registry rejects tag replacement and
  the repository is controlled by this store authority. smolvm publishes both
  the requested tag and a platform tag. SmolBox checks both before dispatch, but
  only the registry policy can fence an unrelated writer racing those checks.

  `credential_ref` resolves a pre-scoped OCI bearer with pull and push permission.
  It is not the identity token used by artifact preparation. `resources` reserves
  additional slots, CPU, memory and disk for the helper and staging. The operator
  must size these for the worker's export helper overrides, source layers and
  temporary copies; these declarations are admission accounting, not host quotas.
  Retained registry bytes are owned and accounted for by the host registry.
  """
  alias SmolBox.{Error, Source, Validation, Worker}

  @enforce_keys [:id, :registry, :repository, :credential_ref, :resources, :immutable_tags]
  @derive {Inspect, only: [:id, :registry, :repository]}
  defstruct @enforce_keys ++ [allow_insecure_loopback: false, ca_cert_file: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          registry: String.t(),
          repository: String.t(),
          credential_ref: String.t(),
          resources: SmolBox.Store.capacity(),
          immutable_tags: true,
          allow_insecure_loopback: boolean(),
          ca_cert_file: String.t() | nil
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) do
    if Validation.keys?(options, @enforce_keys ++ [:allow_insecure_loopback, :ca_cert_file]) and
         Enum.all?(@enforce_keys, &Keyword.has_key?(options, &1)) do
      destination = struct!(__MODULE__, options)
      with :ok <- validate(destination), do: {:ok, destination}
    else
      invalid()
    end
  end

  @doc false
  def validate(%__MODULE__{} = destination) do
    with true <- Validation.struct_shape?(destination, __MODULE__),
         true <- Validation.identifier?(destination.id),
         true <- Validation.identifier?(destination.credential_ref),
         true <- destination.immutable_tags == true,
         true <- resources?(destination.resources),
         true <- Validation.text?(destination.registry, 260),
         true <- Validation.text?(destination.repository, 256),
         {:ok, _source} <-
           Source.registry(
             id: destination.id,
             reference: reference(destination, "sha256:" <> String.duplicate("0", 64)),
             content_sha256: String.duplicate("0", 64),
             architecture: "x86_64"
           ),
         true <-
           destination.ca_cert_file == nil or
             (Validation.text?(destination.ca_cert_file, 4096) and
                String.starts_with?(destination.ca_cert_file, "/")),
         {:ok, _worker} <- endpoint(%{destination | ca_cert_file: nil}, "validation-token") do
      :ok
    else
      _invalid -> invalid()
    end
  end

  def validate(_destination), do: invalid()

  @doc false
  def reference(destination, digest),
    do: destination.registry <> "/" <> destination.repository <> "@" <> digest

  @doc false
  def endpoint(destination, token) do
    scheme = if destination.allow_insecure_loopback, do: "http", else: "https"

    options = [
      token: token,
      allow_insecure_loopback: destination.allow_insecure_loopback,
      max_response_bytes: 1_048_576
    ]

    options =
      if destination.ca_cert_file,
        do: Keyword.put(options, :ca_cert_file, destination.ca_cert_file),
        else: options

    Worker.new("export-registry", scheme <> "://" <> destination.registry, options)
  end

  @doc false
  def resources?(%{slots: slots, cpus: cpus, memory_mb: memory, disk_gb: disk} = resources) do
    map_size(resources) == 4 and Validation.integer?(slots, 1, 1_048_576) and
      Validation.integer?(cpus, 4, 1_048_576) and
      Validation.integer?(memory, 1152, 1_048_576) and
      Validation.integer?(disk, 64, 1_048_576)
  end

  def resources?(_resources), do: false
  defp invalid, do: {:error, %Error{category: :validation, operation: :export}}
end
