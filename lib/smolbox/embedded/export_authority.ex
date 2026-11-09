defmodule SmolBox.Embedded.ExportAuthority do
  @moduledoc false
  alias SmolBox.Embedded.{
    ExportContract,
    ExportPublication,
    ExportStageCleanup,
    NativeGrowth,
    Shape
  }

  alias SmolBox.{Export, ExportReceipt, Validation}

  @enforce_keys [:source]
  @derive {Inspect, only: []}
  defstruct [:source, request: nil, cleanup: nil]

  def enroll(%{backend_assignment: %{version: 2}} = machine) do
    with {:ok, source, _, _} <- NativeGrowth.head(machine),
         true <- Shape.receipt?(source, 2) and source["material"] != nil,
         do: {:ok, %__MODULE__{source: source}},
         else: (_ -> :error)
  end

  def enroll(%{backend_assignment: nil}), do: {:ok, nil}
  def enroll(_), do: :error

  def valid?(%{__struct__: Export, native_authority: nil, receipt: receipt}),
    do: receipt == nil or receipt.native_publication == nil

  def valid?(%{__struct__: Export, native_authority: %__MODULE__{} = authority} = export) do
    Validation.struct_shape?(authority, __MODULE__) and Shape.receipt?(authority.source, 2) and
      authority.source["material"] != nil and request?(export, authority.request) and
      publication?(export) and cleanup?(export)
  end

  def valid?(_), do: false

  def entry_valid?(%{__struct__: Export, native_authority: nil}, %{backend_assignment: nil}),
    do: true

  def entry_valid?(
        %{__struct__: Export, native_authority: %__MODULE__{source: source}} = export,
        %{
          backend_assignment: %{version: 2},
          created_machine: %{backend_identity: %{receipt: origin}}
        } = machine
      ) do
    receipts =
      [origin] ++
        Enum.flat_map(Map.values(machine.captures) ++ Map.values(machine.disk_expansions), fn
          %{native_transition: %{receipt: receipt}} -> [receipt]
          _ -> []
        end)

    Shape.receipt?(origin, 2) and Map.delete(source, "material") == Map.delete(origin, "material") and
      source in receipts and
      (export.receipt == nil or
         export.receipt.platform ==
           if(machine.spec.artifact["architecture"] == "x86_64",
             do: "linux/amd64",
             else: "linux/arm64"
           ))
  end

  def entry_valid?(_, _), do: false

  def freeze_request(
        %{__struct__: Export, native_authority: %__MODULE__{request: nil} = authority} = export,
        request
      ),
      do: if(request?(export, request), do: {:ok, %{authority | request: request}}, else: :error)

  def freeze_request(
        %{__struct__: Export, native_authority: %__MODULE__{request: request} = authority},
        request
      ),
      do: {:ok, authority}

  def freeze_request(%{__struct__: Export, native_authority: nil}, nil), do: {:ok, nil}
  def freeze_request(_, _), do: :error

  def freeze_cleanup(%{__struct__: Export, native_authority: nil}, nil), do: {:ok, nil}

  def freeze_cleanup(
        %{__struct__: Export, native_authority: %__MODULE__{cleanup: cleanup} = authority},
        cleanup
      ),
      do: {:ok, authority}

  def freeze_cleanup(
        %{__struct__: Export, native_authority: %__MODULE__{cleanup: nil} = authority} = export,
        cleanup
      ) do
    if authority.request != nil and
         ExportStageCleanup.bound?(cleanup, authority.source, export.spec.id, export.fingerprint),
       do: {:ok, %{authority | cleanup: cleanup}},
       else: :error
  end

  def freeze_cleanup(_, _), do: :error

  defp request?(export, nil), do: export.state in [:accepted, :failed, :cancelled]

  defp request?(export, request) do
    maximum =
      min(
        export.spec.destination.resources.disk_gb * 1_073_741_824,
        ExportContract.limits()["staging_bytes"]
      )

    ExportContract.request?(request) and request["request_sha256"] == export.fingerprint and
      request["destination_id"] == export.spec.destination.id and
      request["tag"] == export.spec.tag and
      request["max_staging_bytes"] <= maximum
  end

  defp publication?(%{receipt: nil} = export),
    do: export.state not in [:verifying, :published, :completed]

  defp publication?(
         %{receipt: %ExportReceipt{native_publication: proof}, native_authority: authority} =
           export
       ) do
    identity = if match?(%ExportPublication{}, proof), do: proof.identity, else: %{}

    ExportPublication.bound_request?(proof, authority.source, export.spec.id, authority.request) and
      identity["registry"] == export.spec.destination.registry and
      identity["repository"] == export.spec.destination.repository and
      identity["manifest_sha256"] == export.receipt.manifest_sha256 and
      identity["size_bytes"] == export.receipt.size_bytes and
      identity["platform"] == export.receipt.platform and result_matches?(export.result, identity)
  end

  defp result_matches?(nil, _identity), do: true

  defp result_matches?(result, identity),
    do:
      result.config_sha256 == identity["config_sha256"] and
        result.content_sha256 == identity["content_sha256"]

  defp cleanup?(%{native_authority: %{cleanup: nil}} = export),
    do: export.state not in [:completed, :resolved_unknown]

  defp cleanup?(%{native_authority: authority} = export),
    do:
      export.state in [:completed, :resolved_unknown] and authority.request != nil and
        ExportStageCleanup.bound?(
          authority.cleanup,
          authority.source,
          export.spec.id,
          export.fingerprint
        )
end
