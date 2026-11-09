defmodule SmolBox.Error do
  @moduledoc """
  A redacted operation failure with explicit dispatch evidence.

  Errors contain no remote response bodies, credentials, commands, or file data.
  A transport failure with `:dispatch_uncertain` never authorizes command replay.
  Machine list decoding failures use `:dispatch_uncertain`; `:not_dispatched`
  is reserved for failures before the request is sent. `:unsupported_network_policy`
  identifies a rejected machine network policy without retaining its remote fields.
  """

  alias SmolBox.Validation

  @enforce_keys [:category, :operation]
  defexception [:category, :operation, :exit_code, evidence: :not_dispatched]

  @type category ::
          :validation
          | :unsupported_capability
          | :unsupported_network_policy
          | :authentication
          | :admission_exhausted
          | :expired
          | :transport
          | :protocol
          | :output_limit
          | :identity_conflict
          | :port_conflict
          | :not_found
          | :store
          | :stale_claim
          | :stale_version
          | :unknown
          | :cleanup
  @type evidence ::
          :not_dispatched
          | :dispatch_uncertain
          | :running_observed
          | :exited
          | :termination_confirmed
          | :unknown
  @type t :: %__MODULE__{
          category: category(),
          operation: atom(),
          exit_code: integer() | nil,
          evidence: evidence()
        }

  @doc false
  def valid?(nil), do: true

  def valid?(%__MODULE__{} = error) do
    Validation.struct_shape?(error, __MODULE__) and error.__exception__ == true and
      error.category in [
        :validation,
        :unsupported_capability,
        :unsupported_network_policy,
        :authentication,
        :admission_exhausted,
        :expired,
        :transport,
        :protocol,
        :output_limit,
        :identity_conflict,
        :port_conflict,
        :not_found,
        :store,
        :unknown,
        :cleanup,
        :stale_claim,
        :stale_version
      ] and
      error.operation in [
        :volume,
        :expand_disks,
        :export,
        :checkpoint,
        :branch,
        :source,
        :prepare_artifact,
        :registry_credentials,
        :images,
        :pull_image,
        :terminal,
        :terminal_close,
        :terminal_idle,
        :terminal_session,
        :terminal_consumer,
        :command,
        :worker,
        :machine_spec,
        :guest_path,
        :exec,
        :exec_stream,
        :execution_spec,
        :manifest,
        :profile,
        :identity,
        :machine,
        :client,
        :create,
        :list,
        :inspect,
        :start,
        :stop,
        :delete,
        :exec_options,
        :upload,
        :download,
        :machine_name,
        :request_size,
        :transport,
        :execution_state,
        :store,
        :claim,
        :reservation,
        :codec,
        :submit,
        :cancel,
        :reconcile,
        :cleanup,
        :artifact_store,
        :runtime
      ] and
      error.evidence in [
        :not_dispatched,
        :dispatch_uncertain,
        :running_observed,
        :exited,
        :termination_confirmed,
        :unknown
      ] and
      (is_nil(error.exit_code) or
         Validation.integer?(error.exit_code, -2_147_483_648, 2_147_483_647))
  end

  def valid?(_error), do: false

  @impl Exception
  def message(%__MODULE__{category: category, operation: operation, evidence: evidence}) do
    "SmolBox #{operation} failed: #{category} (#{evidence})"
  end

  @doc false
  def uncertain(
        {:definitive_rejection, %__MODULE__{evidence: :not_dispatched} = error},
        operation
      ),
      do: {:error, %{error | operation: operation}}

  def uncertain({:error, %__MODULE__{} = error}, operation),
    do: {:error, %{error | operation: operation, evidence: :dispatch_uncertain}}

  def uncertain(result, _operation), do: result
end
