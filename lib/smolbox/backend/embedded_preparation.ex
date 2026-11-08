defmodule SmolBox.Backend.EmbeddedPreparation do
  @moduledoc false
  alias SmolBox.{ArtifactPreparation, Error, RegistryCredentials, Source, Validation}
  alias SmolBox.Backend.{Budget, EmbeddedReply, Features}
  alias SmolBox.Embedded.{Call, RegistryContract, RegistryPolicy}

  def run(context, arguments, budget) do
    with {:ok, source, request, budget} <- build(context.config, arguments, budget) do
      result = Call.run(context, request, budget)
      decode(context, source, RegistryContract.sanitize(request), result)
    end
  end

  def build(config, [source], budget), do: build(config, [source, []], budget)

  def build(config, [%Source{kind: :registry} = source, options], budget) do
    with :ok <- Source.validate(source),
         true <- Features.supports?(config, :remote_sources),
         true <- Enum.member?(config.sources, source),
         {:ok, credentials} <- credentials(source, options),
         :ok <- RegistryPolicy.validate(config.registry_policy),
         {:ok, budget} <-
           Budget.constrain(budget, max_request_bytes: 24_576, max_response_bytes: 16_384) do
      {:ok, source,
       Map.merge(
         %{"operation" => "prepare_artifact", "source" => RegistryContract.source(source)},
         credentials
       ), budget}
    else
      false ->
        unsupported()

      {:error, %Error{} = error} ->
        {:error, %{error | operation: :prepare_artifact, evidence: :not_dispatched}}
    end
  end

  def build(_config, _arguments, _budget),
    do:
      {:error,
       %Error{category: :validation, operation: :prepare_artifact, evidence: :not_dispatched}}

  def credentials(%Source{credential_ref: nil}, []), do: {:ok, %{}}

  def credentials(%Source{credential_ref: reference}, options) when is_binary(reference) do
    if Validation.keys?(options, [:identity_token]) and
         RegistryCredentials.token?(Keyword.get(options, :identity_token)),
       do:
         {:ok,
          %{
            "credential_ref" => reference,
            "identity_token" => Keyword.fetch!(options, :identity_token)
          }},
       else: credential_error()
  end

  def credentials(_source, _options), do: credential_error()

  defp credential_error,
    do:
      {:error,
       %Error{category: :authentication, operation: :prepare_artifact, evidence: :not_dispatched}}

  def decode(
        _context,
        source,
        request,
        {:ok, %{"result" => "prepared_artifact"} = outcome,
         %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
      ) do
    if RegistryContract.result?(outcome) and outcome["source"] == request["source"] and
         RegistryContract.source(source) == request["source"] do
      ArtifactPreparation.from_wire(source, %{
        "digest" => "sha256:" <> source.content_sha256,
        "sizeBytes" => outcome["size_bytes"],
        "alreadyCached" => outcome["already_cached"]
      })
    else
      invalid()
    end
  end

  def decode(context, _source, request, result),
    do: EmbeddedReply.decode(context, :prepare_artifact, request, result)

  defp unsupported,
    do:
      {:error,
       %Error{
         category: :unsupported_capability,
         operation: :prepare_artifact,
         evidence: :not_dispatched
       }}

  defp invalid,
    do:
      {:error,
       %Error{category: :protocol, operation: :prepare_artifact, evidence: :dispatch_uncertain}}
end
