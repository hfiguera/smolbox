defmodule SmolBox.Source do
  @moduledoc """
  Immutable provisioning sources, separate from input and output file storage.

  `local/1` describes an operator-verified `.smolmachine` on a worker. Its
  `sha256` is the file's content digest. `artifact/1` preserves the existing
  three-key local artifact identity and excludes the worker-specific path.

  `registry/1` describes a prepared artifact in an OCI registry. Its reference
  must name a platform manifest by SHA-256, and `content_sha256` identifies the
  `.smolmachine` blob within that manifest. `oci/1` describes a container image
  by platform manifest digest. Remote `sha256` values identify the manifest,
  never a layer or the image configuration. Tags and index references are not
  resolved by these constructors. Operators must select and approve the platform
  manifest, including its architecture, before registering a source.

  References use an explicit lowercase registry and repository, followed by
  `@sha256:` and 64 lowercase hexadecimal digits. No scheme, credentials, tag,
  query, fragment, implicit registry, or implicit `library/` namespace is added.
  For example, use `registry.example.com/team/app@sha256:…`.

  Construction validates identity, not availability or content. It does not
  grant network access, attest an artifact, or contact a registry. Approval and
  credentials belong to the host's worker configuration. Secrets are never
  part of a source or its durable artifact identity.

  Prepared registry sources may include a safe `:credential_ref` resolved by
  `SmolBox.RegistryCredentials` in host worker configuration. The reference is
  immutable intent; its current token value is never stored in this type.
  """

  alias SmolBox.{ArtifactPath, Error, Validation}

  @enforce_keys [:kind, :id, :sha256, :architecture]
  @derive {Inspect, only: [:kind, :id, :architecture]}
  defstruct @enforce_keys ++ [:path, :reference, :content_sha256, :credential_ref]

  @type kind :: :local | :registry | :oci
  @type t :: %__MODULE__{
          kind: kind(),
          id: String.t(),
          sha256: String.t(),
          architecture: String.t(),
          path: String.t() | nil,
          reference: String.t() | nil,
          content_sha256: String.t() | nil,
          credential_ref: String.t() | nil
        }

  @doc "Describe a local prepared file using `:id`, `:path`, `:sha256` and `:architecture`."
  @spec local(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def local(options), do: build(:local, options, [:id, :sha256, :architecture, :path])

  @doc """
  Describe a registry artifact using `:id`, `:reference`, `:architecture` and
  `:content_sha256`. The manifest digest is extracted from the pinned reference.
  """
  @spec registry(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def registry(options),
    do:
      build(:registry, options, [:id, :reference, :architecture, :content_sha256], [
        :credential_ref
      ])

  @doc "Describe an OCI platform manifest using `:id`, `:reference` and `:architecture`."
  @spec oci(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def oci(options), do: build(:oci, options, [:id, :reference, :architecture])

  @doc "Revalidate all fields, including consistency between reference and manifest digest."
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = source) do
    if Validation.struct_shape?(source, __MODULE__) and
         Validation.identifier?(source.id) and Validation.digest?(source.sha256) and
         source.architecture in ["x86_64", "aarch64"] and fields?(source),
       do: :ok,
       else: invalid()
  end

  def validate(_source), do: invalid()

  @doc "Return the guest OCI platform; macOS workers also run Linux guests."
  @spec oci_platform(t()) :: String.t()
  def oci_platform(%__MODULE__{architecture: "x86_64"}), do: "linux/amd64"
  def oci_platform(%__MODULE__{architecture: "aarch64"}), do: "linux/arm64"

  @doc "Return the path-independent, credential-free artifact identity for a validated source."
  @spec artifact(t()) :: %{String.t() => String.t()}
  def artifact(%__MODULE__{} = source) do
    identity = %{
      "id" => source.id,
      "sha256" => source.sha256,
      "architecture" => source.architecture
    }

    case source.kind do
      :local ->
        identity

      :oci ->
        Map.merge(identity, %{"kind" => "oci", "reference" => source.reference})

      :registry ->
        identity =
          Map.merge(identity, %{
            "kind" => "registry",
            "reference" => source.reference,
            "content_sha256" => source.content_sha256
          })

        if source.credential_ref,
          do: Map.put(identity, "credential_ref", source.credential_ref),
          else: identity
    end
  end

  @doc false
  @spec from_artifact(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_artifact(%{"kind" => kind} = artifact) when kind in ["oci", "registry"] do
    options = [
      id: artifact["id"],
      reference: artifact["reference"],
      architecture: artifact["architecture"]
    ]

    result =
      if kind == "oci",
        do: oci(options),
        else:
          registry(
            options ++
              [
                content_sha256: artifact["content_sha256"],
                credential_ref: artifact["credential_ref"]
              ]
          )

    with {:ok, source} <- result,
         true <- artifact(source) == artifact do
      {:ok, source}
    else
      _invalid -> invalid()
    end
  end

  def from_artifact(_artifact), do: invalid()

  @doc false
  def remote?(%{"kind" => kind}) when kind in ["registry", "oci"], do: true
  def remote?(_artifact), do: false

  defp build(kind, options, keys, optional \\ []) do
    if Validation.keys?(options, keys ++ optional) and
         Enum.all?(keys, &Keyword.has_key?(options, &1)) do
      fields =
        if kind == :local,
          do: options,
          else: Keyword.put(options, :sha256, digest(options[:reference]))

      source = struct!(__MODULE__, [{:kind, kind} | fields])
      with :ok <- validate(source), do: {:ok, source}
    else
      invalid()
    end
  end

  defp fields?(
         %{kind: :local, reference: nil, content_sha256: nil, credential_ref: nil} = source
       ),
       do: ArtifactPath.valid?(source.path, :image)

  defp fields?(%{kind: :oci, path: nil, content_sha256: nil, credential_ref: nil} = source),
    do: digest(source.reference) == source.sha256

  defp fields?(%{kind: :registry, path: nil} = source),
    do:
      digest(source.reference) == source.sha256 and Validation.digest?(source.content_sha256) and
        (source.credential_ref == nil or Validation.identifier?(source.credential_ref))

  defp fields?(_source), do: false

  defp digest(reference) when is_binary(reference) and byte_size(reference) <= 1024 do
    case String.split(reference, "@sha256:") do
      [location, digest] ->
        if Validation.digest?(digest) and location?(location), do: digest

      _invalid ->
        nil
    end
  end

  defp digest(_reference), do: nil

  defp location?(location) do
    case String.split(location, "/", parts: 2) do
      [registry, repository] -> registry?(registry) and repository?(repository)
      _invalid -> false
    end
  end

  defp registry?(registry) do
    case String.split(registry, ":") do
      [host] -> host?(host)
      [host, port] -> host?(host) and port?(port)
      _invalid -> false
    end
  end

  defp host?(host) do
    byte_size(host) <= 253 and (host == "localhost" or String.contains?(host, ".")) and
      Enum.all?(String.split(host, "."), fn label ->
        byte_size(label) in 1..63 and
          Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, label)
      end)
  end

  defp port?(port) do
    case Integer.parse(port) do
      {number, ""} -> number in 1..65_535 and Integer.to_string(number) == port
      _invalid -> false
    end
  end

  defp repository?(repository),
    do:
      Regex.match?(
        ~r/\A[a-z0-9]+(?:(?:[._]|__|[-]+)[a-z0-9]+)*(?:\/[a-z0-9]+(?:(?:[._]|__|[-]+)[a-z0-9]+)*)*\z/,
        repository
      )

  defp invalid, do: {:error, %Error{category: :validation, operation: :source}}
end
