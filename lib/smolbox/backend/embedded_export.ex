defmodule SmolBox.Backend.EmbeddedExport do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedContext, EmbeddedReply, Features}

  alias SmolBox.Embedded.{
    Call,
    ExportAuthority,
    ExportContract,
    ExportPublication,
    ExportStageCleanup,
    Identity,
    Shape
  }

  alias SmolBox.{Error, Export, ExportReceipt}

  def invoke(context, operation, arguments, budget) do
    if scoped?(context),
      do: execute_authorized(context, operation, arguments, budget),
      else: failure(:unsupported_capability, :not_dispatched)
  end

  # The caller has already checked the machine, receipt and package feature.
  # The Port separately checks the pinned owner and approval for each request.
  def execute_authorized(context, :export_machine, [name, spec, token], budget) do
    with true <- context.export.state == :dispatching,
         true <- name == context.name and spec == context.export.spec,
         true <-
           spec.destination in context.config.export_destinations and ExportContract.token?(token),
         true <- context.export.native_authority.request != nil,
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: spec.timeout_ms) do
      request = %{
        "operation" => "export_machine",
        "receipt" => context.export.native_authority.source,
        "operation_id" => spec.id,
        "request" => context.export.native_authority.request,
        "push_token" => token
      }

      transfer(context, :export_machine, request, budget)
    else
      _ -> failure(:unsupported_capability, :not_dispatched)
    end
  end

  def execute_authorized(context, :qualify_export, [], budget) do
    deadline = now() + min(budget.timeout_ms, 30_000)

    with true <- context.export.state == :accepted,
         true <- context.export.spec.destination in context.config.export_destinations,
         {:ok, budget} <- remaining(budget, deadline),
         context = Call.pin(context, budget),
         true <- context.server != nil and context.epoch != nil,
         bridge = EmbeddedContext.bridge(context),
         true <- function_exported?(bridge, :export_approval, 4),
         {:ok, budget} <- remaining(budget, deadline),
         {:ok, approval} <-
           bridge.export_approval(
             context.server,
             context.export.spec.destination.id,
             context.epoch,
             budget.timeout_ms
           ),
         {:ok, request} <-
           build_request(context.export, approval, EmbeddedContext.resources(context)),
         {:ok, budget} <- remaining(budget, deadline),
         operation = %{
           "operation" => "qualify_export",
           "receipt" => context.export.native_authority.source,
           "request" => request
         },
         :ok <- transfer(context, :qualify_export, operation, budget),
         {:ok, budget} <- remaining(budget, deadline),
         admission =
           operation
           |> Map.put("operation", "admit_export")
           |> Map.put("operation_id", context.export.spec.id),
         :ok <- transfer(context, :admit_export, admission, budget),
         do: {:ok, request},
         else: (
           {:error, %Error{} = error} -> {:error, %{error | operation: :export}}
           _ -> failure(:unsupported_capability, :not_dispatched)
         )
  end

  def execute_authorized(context, :inspect_export, [], budget) do
    with true <- context.export.native_authority.request != nil,
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 16_384),
         do:
           transfer(context, :inspect_export, control(context.export, "inspect_export"), budget),
         else: (_ -> failure(:unsupported_capability, :not_dispatched))
  end

  def execute_authorized(context, :cleanup_export, [export, true], budget) do
    with true <- context.export == export,
         true <- export.state in [:unknown, :published] and export.native_authority.request != nil,
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 16_384),
         do:
           transfer(
             context,
             :cleanup_export,
             Map.put(control(export, "cleanup_export_staging"), "quiesced", true),
             budget
           ),
         else: (_ -> failure(:unsupported_capability, :not_dispatched))
  end

  # Requests carry upper bounds, not promised allocation or source-mode claims.
  # New funded catalogs let the engine divide the grant from actual source data;
  # legacy catalogs preserve their exact source-sized request construction.
  def build_request(export, approval, resources) do
    with :ok <- Export.validate(export),
         %ExportAuthority{} <- export.native_authority,
         true <-
           approval_shape?(approval, export),
         true <- approval["id"] == export.spec.destination.id,
         true <- Shape.resources?(resources),
         maximum =
           min(
             export.spec.destination.resources.disk_gb * 1_073_741_824,
             ExportContract.limits()["staging_bytes"]
           ),
         true <-
           is_integer(approval["max_staging_bytes"]) and
             approval["max_staging_bytes"] in 1..maximum,
         true <- is_integer(approval["max_artifact_bytes"]) and approval["max_artifact_bytes"] > 0,
         raw = (resources["storage_gib"] + resources["overlay_gib"]) * 1_073_741_824,
         request = %{
           "request_sha256" => export.fingerprint,
           "destination_id" => approval["id"],
           "destination_sha256" => approval["destination_sha256"],
           "tag" => export.spec.tag,
           "max_staging_bytes" => approval["max_staging_bytes"],
           "max_artifact_bytes" =>
             min(
               approval["max_artifact_bytes"],
               approval["max_staging_bytes"] -
                 if(Map.has_key?(approval, "conversion_resources"), do: 1, else: raw)
             )
         },
         true <- ExportContract.request?(request),
         do: {:ok, request},
         else: (_ -> failure(:unsupported_capability, :not_dispatched))
  end

  defp approval_shape?(approval, export) do
    fields = ~w(id destination_sha256 max_artifact_bytes max_staging_bytes)

    Shape.keys?(approval, fields) or
      (Shape.keys?(approval, fields ++ ["conversion_resources"]) and
         approval["conversion_resources"] ==
           Map.new(export.spec.destination.resources, fn {key, value} ->
             {Atom.to_string(key), value}
           end))
  end

  def control(export, name),
    do: %{
      "operation" => name,
      "receipt" => export.native_authority.source,
      "operation_id" => export.spec.id,
      "request_sha256" => export.fingerprint
    }

  defp scoped?(context) do
    with true <- EmbeddedContext.scoped?(context) and Features.supports?(context.config, :exports),
         %Export{} = export <- context.export,
         :ok <- Export.validate(export),
         %ExportAuthority{} = authority <- export.native_authority,
         %Identity{} = identity <- context.identity do
      export.machine == {context.spec.scope, context.spec.id} and
        authority.source == identity.receipt
    else
      _ -> false
    end
  end

  defp transfer(context, operation, request, budget) do
    deadline = now() + budget.timeout_ms
    context = Call.pin(context, budget)

    with true <- context.server != nil and context.epoch != nil,
         {:ok, budget} <- remaining(budget, deadline),
         do: decode(context, operation, request, Call.run(context, request, budget)),
         else: (
           {:error, _} = error -> error
           _ -> failure(:unknown, :not_dispatched)
         )
  end

  def decode(
        _context,
        operation,
        _request,
        {:ok, %{"result" => "qualified"} = outcome, empty, nil}
      )
      when operation in [:qualify_export, :admit_export] and map_size(outcome) == 1 and
             empty == %{stdout: <<>>, stderr: <<>>, file: <<>>},
      do: :ok

  def decode(
        context,
        :export_machine,
        request,
        {:ok, %{"result" => "exported", "publication" => wire} = outcome, empty, nil}
      )
      when map_size(outcome) == 2 and empty == %{stdout: <<>>, stderr: <<>>, file: <<>>} do
    with {:ok, proof} <- ExportPublication.from_wire(wire),
         true <- publication_matches?(context, proof),
         true <-
           request["receipt"] == proof.source and request["operation_id"] == proof.operation_id and
             request["request"] == context.export.native_authority.request,
         do: {:ok, receipt(proof)},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  def decode(
        context,
        :inspect_export,
        request,
        {:ok, %{"result" => "export_presence", "publication" => wire} = outcome, empty, nil}
      )
      when map_size(outcome) == 2 and empty == %{stdout: <<>>, stderr: <<>>, file: <<>>} do
    if request == control(context.export, "inspect_export"),
      do: decode_presence(context, wire),
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  def decode(
        context,
        :cleanup_export,
        request,
        {:ok, %{"result" => "export_staging_cleaned", "cleanup" => wire} = outcome, empty, nil}
      )
      when map_size(outcome) == 2 and empty == %{stdout: <<>>, stderr: <<>>, file: <<>>} do
    with true <-
           request == Map.put(control(context.export, "cleanup_export_staging"), "quiesced", true),
         {:ok, proof} <- ExportStageCleanup.from_wire(wire),
         true <-
           ExportStageCleanup.bound?(
             proof,
             context.export.native_authority.source,
             context.export.spec.id,
             context.export.fingerprint
           ),
         do: {:ok, proof},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  def decode(context, operation, request, {:ok, %{"result" => "error"}, _, nil} = result),
    do: EmbeddedReply.decode(context, operation, request, result)

  def decode(_, _, _, {:error, %Error{} = error}), do: {:error, %{error | operation: :export}}
  def decode(_, _, _, _), do: failure(:protocol, :dispatch_uncertain)

  defp decode_presence(_context, nil), do: {:ok, nil}

  defp decode_presence(context, wire) do
    with {:ok, proof} <- ExportPublication.from_wire(wire),
         true <- publication_matches?(context, proof),
         do: {:ok, proof},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  defp publication_matches?(context, proof) do
    export = context.export

    with true <-
           ExportPublication.bound_request?(
             proof,
             export.native_authority.source,
             export.spec.id,
             export.native_authority.request
           ),
         candidate = %{
           export
           | state: if(export.state == :dispatching, do: :verifying, else: export.state),
             receipt: receipt(proof)
         },
         :ok <- Export.validate(candidate) do
      proof.identity["platform"] ==
        if(context.spec.artifact["architecture"] == "x86_64",
          do: "linux/amd64",
          else: "linux/arm64"
        )
    else
      _ -> false
    end
  end

  defp receipt(proof),
    do: %ExportReceipt{
      manifest_sha256: proof.identity["manifest_sha256"],
      size_bytes: proof.identity["size_bytes"],
      platform: proof.identity["platform"],
      native_publication: proof
    }

  defp remaining(budget, deadline) do
    timeout = deadline - now()

    if timeout > 0,
      do: Budget.constrain(budget, timeout_ms: timeout),
      else: failure(:expired, :dispatch_uncertain)
  end

  defp now, do: System.monotonic_time(:millisecond)

  def failure(category, evidence),
    do: {:error, %Error{category: category, operation: :export, evidence: evidence}}
end
