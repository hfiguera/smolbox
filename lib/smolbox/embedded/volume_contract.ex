defmodule SmolBox.Embedded.VolumeContract do
  @moduledoc false
  alias SmolBox.Embedded.Shape
  alias SmolBox.{Mount, Validation}

  @observations ~w(inspect_provision inspect_deletion inspect_abort)
  @simple ~w(provision delete qualify_deletion) ++ @observations
  @u64 18_446_744_073_709_551_615
  @u32 4_294_967_295
  @statuses %{
    "provision" => ~w(provisioned),
    "delete" => ~w(deleted),
    "resolve_deletion" => ~w(deleted),
    "abort_staging" => ~w(aborted),
    "inspect_provision" => ~w(provisioned absent unverified),
    "inspect_deletion" => ~w(deleted unverified),
    "inspect_abort" => ~w(aborted unverified),
    "qualify_deletion" => ~w(qualified)
  }

  def request?(request, budget),
    do:
      Shape.keys?(request, ~w(policy_id intent action)) and
        Shape.id?(request["policy_id"]) and intent?(request["intent"]) and
        action?(request["action"]) and
        Validation.integer?(budget, 1, if(observation?(request), do: 30_000, else: 86_400_000))

  def observation?(%{"action" => %{"action" => action}}), do: action in @observations
  def observation?(_), do: false

  def intent?(intent),
    do:
      Shape.keys?(intent, ~w(worker_volume_id size_gb)) and
        volume_id?(intent["worker_volume_id"]) and
        Validation.integer?(intent["size_gb"], 1, 1024)

  def result?(%{"result" => "volume", "volume" => volume} = outcome),
    do: Shape.keys?(outcome, ~w(result volume)) and volume?(volume)

  def result?(_), do: false

  def matches?(outcome, request, domain) do
    result?(outcome) and request?(request, 1) and
      outcome["volume"]["status"] in Map.fetch!(@statuses, request["action"]["action"]) and
      backing_matches?(backing(outcome), request, domain)
  end

  # Catalog validation is additional to wire correlation: callers cannot choose
  # a root, and a valid proof from a different approved-root location is rejected.
  def approved?(request, %{id: id, root: root}),
    do:
      request?(request, 1) and request["policy_id"] == id and
        policy?(%{"id" => id, "root" => root})

  def approved?(_, _), do: false

  def approved_result?(outcome, %{id: id, root: root}) do
    result?(outcome) and
      case backing(outcome) do
        nil -> true
        proof -> proof["policy"] == %{"id" => id, "root" => root}
      end
  end

  def approved_result?(_, _), do: false

  def backing(%{"volume" => %{"status" => "deleted", "proof" => proof}}),
    do: proof["provision"]["backing"]

  def backing(%{"volume" => %{"status" => status, "proof" => proof}})
      when status in ~w(provisioned qualified aborted),
      do: proof["backing"]

  def backing(_), do: nil

  defp volume_id?("sbv-" <> suffix), do: Shape.hex?(suffix, 32)
  defp volume_id?(_), do: false

  defp action?(%{"action" => action} = value) when action in @simple,
    do: Shape.keys?(value, ~w(action))

  defp action?(%{"action" => action, "quiesced" => true} = value)
       when action in ~w(resolve_deletion abort_staging),
       do: Shape.keys?(value, ~w(action quiesced))

  defp action?(_), do: false

  defp policy?(policy),
    do:
      Shape.keys?(policy, ~w(id root)) and Shape.id?(policy["id"]) and
        Mount.path?(policy["root"]) and byte_size(policy["root"]) <= 4059

  defp backing?(proof),
    do:
      Shape.keys?(
        proof,
        ~w(schema target_id domain_generation policy intent owner_token root_device root_inode device inode mode)
      ) and
        proof["schema"] === 1 and Shape.id?(proof["target_id"]) and
        Shape.hex?(proof["domain_generation"], 32) and policy?(proof["policy"]) and
        intent?(proof["intent"]) and Shape.hex?(proof["owner_token"], 64) and
        physical_identity?(proof)

  defp physical_identity?(proof),
    do:
      Validation.integer?(proof["root_device"], 0, @u64) and
        Validation.integer?(proof["root_inode"], 1, @u64) and
        Validation.integer?(proof["inode"], 1, @u64) and
        proof["device"] === proof["root_device"] and proof["mode"] === 448

  defp account?(account),
    do:
      Shape.keys?(account, ~w(uid gid)) and Validation.integer?(account["uid"], 1, @u32) and
        Validation.integer?(account["gid"], 0, @u32)

  defp provision?(proof),
    do:
      Shape.keys?(proof, ~w(schema backing account)) and proof["schema"] === 1 and
        backing?(proof["backing"]) and account?(proof["account"])

  defp deletion?(proof),
    do:
      Shape.keys?(proof, ~w(schema operation_id provision)) and proof["schema"] === 1 and
        Shape.hex?(proof["operation_id"], 32) and provision?(proof["provision"])

  defp abort?(proof),
    do:
      Shape.keys?(proof, ~w(schema operation_id backing account)) and proof["schema"] === 1 and
        Shape.hex?(proof["operation_id"], 32) and backing?(proof["backing"]) and
        account?(proof["account"])

  defp volume?(%{"status" => status} = volume) when status in ~w(absent unverified),
    do: Shape.keys?(volume, ~w(status))

  defp volume?(%{"status" => status, "proof" => proof} = volume),
    do: Shape.keys?(volume, ~w(status proof)) and proof?(status, proof)

  defp volume?(_), do: false
  defp proof?(status, proof) when status in ~w(provisioned qualified), do: provision?(proof)
  defp proof?("deleted", proof), do: deletion?(proof)
  defp proof?("aborted", proof), do: abort?(proof)
  defp proof?(_, _), do: false

  defp backing_matches?(nil, _request, _domain), do: true

  defp backing_matches?(proof, request, domain),
    do:
      proof["target_id"] == domain["target_id"] and
        proof["domain_generation"] == domain["generation"] and
        proof["policy"]["id"] == request["policy_id"] and proof["intent"] == request["intent"]
end
