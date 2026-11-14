defmodule SmolBox.Test.NodeAuthorityPeer do
  @moduledoc false
  alias SmolBox.Kubernetes.{Config, Observation}
  alias SmolBox.Kubernetes.NodeAuthority.JSON
  alias SmolBox.Test.Kubernetes, as: Fixture
  alias SmolBox.Test.NodeAuthority, as: Authority
  alias SmolBox.TestPeer

  @executable Path.expand("kubernetes_node_peer.py", __DIR__)

  # This is a framed SSH stand-in, never physical node evidence. All API/node
  # observations are test-owned; the SDK protocol/Port path is the production one.
  def start(kube, peer, directory) do
    File.mkdir_p!(directory)
    executable = Path.join(directory, "ssh-peer")
    File.cp!(@executable, executable)
    File.chmod!(executable, 0o700)
    binding = Config.binding(kube)
    configuration = put_in(Authority.vectors()["configuration"]["binding"], wire(binding))
    {:ok, configuration_sha} = JSON.digest(configuration["configuration"])
    fields = Authority.vectors()["identity_fields"]

    fields = %{
      fields
      | "binding_generation" => binding.generation,
        "configuration_sha256" => configuration_sha
    }

    {:ok, generation} = JSON.digest(fields)

    {:ok, context} =
      Authority.context(ssh_executable: executable, authority_generation: generation)

    state =
      ExUnit.Callbacks.start_supervised!(
        {Agent, fn -> %{mode: :normal, requests: [], last: nil} end},
        id: make_ref()
      )

    port = TestPeer.start(&handle(&1, state, peer, binding, context))

    File.write!(
      Path.join(directory, "response.json"),
      Jason.encode!(%{mode: "authority", endpoint: "http://127.0.0.1:#{port}/node"})
    )

    {%{kube | node_evidence: {SmolBox.Kubernetes.NodeAuthority, context}}, state, context}
  end

  def uid do
    <<first::binary-size(8), second::binary-size(4), third::binary-size(4),
      fourth::binary-size(4), last::binary-size(12)>> =
      :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    Enum.join([first, second, third, fourth, last], "-")
  end

  def observation(binding, uid, generation, now) do
    sid = :crypto.hash(:sha256, uid) |> Base.encode16(case: :lower)
    original = Fixture.observation(binding, uid)
    process = hd(original.processes)

    %{
      original
      | observer_epoch: generation,
        observed_at_ms: now,
        sandbox_ids: [sid],
        processes: [%{process | sandbox_id: sid, vm_directory: Observation.vm_directory(sid)}],
        interfaces: [%{sandbox_id: sid, name: "veth" <> binary_part(sid, 0, 8), ifindex: 9}]
    }
  end

  def requests(state), do: Agent.get(state, &Enum.reverse(&1.requests))
  def mode(state, mode), do: Agent.update(state, &%{&1 | mode: mode})

  defp handle(conn, state, peer, binding, context) do
    {:ok, bytes, conn} = Plug.Conn.read_body(conn, length: 65_536)
    request = Jason.decode!(bytes)
    snapshot = Agent.get_and_update(state, &{&1, %{&1 | requests: [request | &1.requests]}})
    pod = Agent.get(peer, & &1.pod)

    base =
      Map.take(
        request,
        ~w(version action nonce binding_generation authority_generation verifier_manifest_sha256)
      )

    base =
      Map.merge(base, %{
        "binding_generation" => binding.generation,
        "authority_generation" => context.authority_generation,
        "verifier_manifest_sha256" => context.verifier_manifest_sha256
      })

    response = reply(base, request, pod, binding, context, snapshot)
    Agent.update(state, &%{&1 | last: response})
    TestPeer.json(conn, response)
  end

  defp reply(_base, _, _, _, _, %{mode: :replay, last: response}) when not is_nil(response),
    do: response

  defp reply(base, _, _, _, _, %{mode: :missing}), do: reject(base)
  defp reply(_, _, _, _, _, %{mode: :corrupt}), do: %{"invalid_enrollment_response" => true}

  defp reply(base, request, pod, binding, context, snapshot) do
    case value(request, pod, binding, context, snapshot.mode) do
      {:ok, value} ->
        base =
          case snapshot.mode do
            :changed_epoch ->
              Map.put(base, "authority_generation", String.duplicate("f", 64))

            :changed_manifest ->
              Map.put(base, "verifier_manifest_sha256", String.duplicate("f", 64))

            _ ->
              base
          end

        Map.merge(base, %{
          "ok" => true,
          "error" => nil,
          "value" => value,
          "journal" => %{
            "history_epoch" => "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "watermark" => 2,
            "prefix_sha256" => String.duplicate("a", 64)
          }
        })

      :error ->
        reject(base)
    end
  end

  defp reject(base),
    do:
      Map.merge(base, %{"ok" => false, "error" => "unavailable", "journal" => nil, "value" => nil})

  defp value(%{"action" => "check"}, pod, _, context, mode),
    do:
      {:ok,
       %{
         observer_epoch: context.authority_generation,
         complete_history: mode != :incomplete,
         idle: pod == nil
       }}

  defp value(
         %{"action" => "capture", "arguments" => %{"pod_uid" => uid}},
         pod,
         binding,
         context,
         mode
       ) do
    if get_in(pod || %{}, ["metadata", "uid"]) == uid do
      time = System.system_time(:millisecond) - if(mode == :stale, do: 10_000, else: 0)
      {:ok, observation(binding, uid, context.authority_generation, time) |> wire()}
    else
      :error
    end
  end

  defp value(%{"action" => "cleanup", "arguments" => %{"receipt" => receipt}}, nil, _, _, mode)
       when mode != :proof_unavailable do
    capture = receipt["observation"]

    {:ok,
     %{
       "version" => 3,
       "observed_at_ms" => System.system_time(:millisecond),
       "observer_epoch" => capture["observer_epoch"],
       "api_absent" => true,
       "complete_history" => true,
       "terminated_processes" => capture["processes"],
       "absent_records" => capture["sandbox_ids"],
       "absent_shares" => capture["sandbox_ids"],
       "absent_vm_directories" => Enum.sort(Enum.map(capture["processes"], & &1["vm_directory"]))
     }}
  end

  defp value(_, _, _, _, _), do: :error
  defp wire(value), do: value |> Map.from_struct() |> Jason.encode!() |> Jason.decode!()
end
