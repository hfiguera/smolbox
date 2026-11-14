defmodule SmolBox.KubernetesPeer do
  @moduledoc false
  alias SmolBox.Kubernetes.Enrollment
  alias SmolBox.Test.Kubernetes, as: Fixture
  alias SmolBox.TestPeer

  defmodule Credentials do
    @moduledoc false
    def resolve(token, _budget), do: {:ok, token}
  end

  def start(tls) do
    {:ok, base} = Fixture.config(credential_provider: {Credentials, "token-a"})
    objects = objects(base)

    state =
      ExUnit.Callbacks.start_supervised!(
        {Agent,
         fn ->
           %{
             objects: objects,
             requests: [],
             pod: nil,
             ready: false,
             mode: :normal,
             overrides: %{},
             expected_token: "token-a"
           }
         end},
        id: make_ref()
      )

    port =
      TestPeer.start(&handle(&1, state), scheme: :https, certfile: tls.cert, keyfile: tls.key)

    digest = Enrollment.policy_digest(objects.runtime, objects.policy)

    {:ok, config} =
      Fixture.config(
        api_server: "https://localhost:#{port}",
        ca_file: tls.ca,
        credential_provider: {Credentials, "token-a"},
        runtime_policy_digest: digest
      )

    {config, state}
  end

  def objects(config) do
    namespace = fn name, uid ->
      %{
        "apiVersion" => "v1",
        "kind" => "Namespace",
        "metadata" => %{"name" => name, "uid" => uid},
        "status" => %{"phase" => "Active"}
      }
    end

    %{
      version: %{"gitVersion" => config.runtime_identity["k3s_version"]},
      anchor: namespace.("kube-system", config.cluster_anchor_uid),
      namespace: namespace.(config.namespace, config.namespace_uid),
      node: %{
        "metadata" => %{
          "name" => config.node_name,
          "uid" => config.node_uid,
          "labels" => %{
            "kubernetes.io/hostname" => config.node_name,
            "kubernetes.io/arch" => "amd64",
            "smolvm-runtime" => "true"
          }
        },
        "spec" => %{},
        "status" => %{
          "nodeInfo" => %{
            "bootID" => config.node_boot_id,
            "architecture" => "amd64",
            "operatingSystem" => "linux",
            "kubeletVersion" => config.runtime_identity["k3s_version"],
            "containerRuntimeVersion" =>
              "containerd://" <> config.runtime_identity["containerd_version"]
          },
          "conditions" =>
            Enum.map(
              [
                {"Ready", "True"},
                {"MemoryPressure", "False"},
                {"DiskPressure", "False"},
                {"PIDPressure", "False"}
              ],
              fn {kind, status} -> %{"type" => kind, "status" => status} end
            )
        }
      },
      runtime: %{
        "metadata" => %{"name" => config.runtime_class, "uid" => config.runtime_class_uid},
        "handler" => "smolvm",
        "overhead" => %{"podFixed" => %{"cpu" => "250m", "memory" => "512Mi"}},
        "scheduling" => %{
          "nodeSelector" => %{
            "kubernetes.io/hostname" => config.node_name,
            "kubernetes.io/arch" => "amd64",
            "smolvm-runtime" => "true"
          }
        }
      },
      policy: %{
        "metadata" => %{
          "name" => "offline",
          "namespace" => config.namespace,
          "uid" => "policy-uid"
        },
        "spec" => %{"podSelector" => %{}, "policyTypes" => ["Ingress", "Egress"]}
      }
    }
  end

  def effective(manifest, ready \\ false) do
    manifest
    |> put_in(["metadata", "uid"], "pod-original")
    |> put_in(["spec", "nodeSelector", "smolvm-runtime"], "true")
    |> put_in(["spec", "overhead"], %{"cpu" => "250m", "memory" => "512Mi"})
    |> put_in(["spec", "nodeName"], "smolbox-k3s")
    |> Map.put("status", status(manifest, ready))
  end

  defp status(manifest, true),
    do: %{
      "phase" => "Running",
      "conditions" => [%{"type" => "Ready", "status" => "True"}],
      "containerStatuses" => [
        %{
          "name" => "workload",
          "ready" => true,
          "started" => true,
          "restartCount" => 0,
          "image" => "sha256:" <> Fixture.digest(),
          "imageID" => hd(manifest["spec"]["containers"])["image"],
          "containerID" => "containerd://" <> Fixture.digest(),
          "state" => %{"running" => %{"startedAt" => "2026-11-13T00:00:00Z"}}
        }
      ]
    }

  defp status(_manifest, false), do: %{"phase" => "Pending", "containerStatuses" => []}

  def requests(state), do: Agent.get(state, &Enum.reverse(&1.requests))
  def change(state, function), do: Agent.update(state, function)

  defp handle(conn, state) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    token = Plug.Conn.get_req_header(conn, "authorization")

    request = %{
      method: conn.method,
      path: conn.request_path,
      query: conn.query_string,
      body: if(body == "", do: nil, else: Jason.decode!(body)),
      auth: token
    }

    snapshot = Agent.get_and_update(state, &{&1, %{&1 | requests: [request | &1.requests]}})
    override = snapshot.overrides[{conn.method, conn.request_path}]

    cond do
      token != ["Bearer " <> snapshot.expected_token] -> TestPeer.json(conn, %{}, 401)
      is_function(override, 1) -> override.(conn)
      true -> route(conn, request, state, snapshot)
    end
  end

  defp object_key(path) do
    cond do
      path == "/version" -> :version
      path == "/api/v1/namespaces/kube-system" -> :anchor
      path == "/api/v1/namespaces/smolbox-preview" -> :namespace
      String.starts_with?(path, "/api/v1/nodes/") -> :node
      String.starts_with?(path, "/apis/node.k8s.io/") -> :runtime
      String.contains?(path, "/networkpolicies/") -> :policy
      true -> nil
    end
  end

  defp route(conn, %{method: "GET", path: path}, _state, snapshot) do
    key = object_key(path)

    case snapshot.objects[key] do
      nil -> get_pod(conn, snapshot)
      object -> TestPeer.json(conn, object)
    end
  end

  defp route(conn, %{method: "POST", body: manifest}, state, snapshot) do
    if snapshot.pod do
      TestPeer.json(conn, %{}, 409)
    else
      pod = effective(manifest, snapshot.ready)
      Agent.update(state, &%{&1 | pod: pod})
      if snapshot.mode == :lost_create, do: exit(:normal), else: TestPeer.json(conn, pod, 201)
    end
  end

  defp route(conn, %{method: "DELETE", body: body}, state, snapshot) do
    cond do
      snapshot.pod == nil ->
        TestPeer.json(conn, %{}, 404)

      body["preconditions"]["uid"] != snapshot.pod["metadata"]["uid"] ->
        TestPeer.json(conn, %{}, 409)

      snapshot.mode == :finalizer ->
        TestPeer.json(conn, snapshot.pod)

      true ->
        Agent.update(state, &%{&1 | pod: nil})
        TestPeer.json(conn, %{"kind" => "Status", "status" => "Success"})
    end
  end

  defp get_pod(conn, snapshot) do
    cond do
      String.ends_with?(conn.request_path, "/pods") ->
        TestPeer.json(conn, %{
          "kind" => "PodList",
          "metadata" => %{"resourceVersion" => "42"},
          "items" => if(snapshot.pod, do: [snapshot.pod], else: [])
        })

      snapshot.pod == nil ->
        TestPeer.json(conn, %{}, 404)

      true ->
        TestPeer.json(conn, snapshot.pod)
    end
  end
end
