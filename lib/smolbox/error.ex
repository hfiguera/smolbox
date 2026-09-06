defmodule SmolBox.Error do
  @moduledoc """
  A redacted operation failure with explicit dispatch evidence.

  Errors contain no remote response bodies, credentials, commands, or file data.
  A transport failure with `:dispatch_uncertain` never authorizes command replay.
  """

  @enforce_keys [:category, :operation]
  defexception [:category, :operation, :exit_code, evidence: :not_dispatched]

  @type category ::
          :validation
          | :unsupported_capability
          | :authentication
          | :admission_exhausted
          | :expired
          | :transport
          | :protocol
          | :output_limit
          | :identity_conflict
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

  @impl Exception
  def message(%__MODULE__{category: category, operation: operation, evidence: evidence}) do
    "SmolBox #{operation} failed: #{category} (#{evidence})"
  end
end
