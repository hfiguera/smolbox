defmodule SmolBox.ExportPeer do
  @moduledoc false
  alias SmolBox.{ExportDestination, TestPeer}
  @manifest "application/vnd.oci.image.manifest.v1+json"
  @index "application/vnd.oci.image.index.v1+json"
  @config "application/vnd.smolmachines.machine.config.v1+json"
  @layer "application/vnd.smolmachines.smolmachine.v1"

  def start do
    state =
      ExUnit.Callbacks.start_supervised!(
        {Agent, fn -> %{objects: %{}, token: "export-test-token", publications: 0} end},
        id: make_ref()
      )

    port = TestPeer.start(&serve(&1, state))

    {:ok, destination} =
      ExportDestination.new(
        id: "exports",
        registry: "127.0.0.1:#{port}",
        repository: "team/exports",
        credential_ref: "publisher",
        immutable_tags: true,
        allow_insecure_loopback: true,
        resources: %{slots: 1, cpus: 4, memory_mb: 4608, disk_gb: 128}
      )

    {state, destination}
  end

  def publish(agent, %{"pushToken" => token, "repo" => repo, "tag" => tag}) do
    Agent.get_and_update(agent, &publication(&1, token, repo, tag))
  end

  defp publication(state, token, repo, tag) do
    if token == state.token do
      config =
        Jason.encode!(%{
          "platform" => "linux/amd64",
          "mode" => "container",
          "env" => ["PRIVATE=not-for-records"]
        })

      content = "prepared disk content"

      manifest =
        Jason.encode!(%{
          "schemaVersion" => 2,
          "mediaType" => @manifest,
          "artifactType" => @layer,
          "config" => descriptor(config, @config),
          "layers" => [descriptor(content, @layer)]
        })

      index =
        Jason.encode!(%{
          "schemaVersion" => 2,
          "mediaType" => @index,
          "manifests" => [
            Map.put(descriptor(manifest, @manifest), "platform", %{
              "os" => "linux",
              "architecture" => "amd64"
            })
          ]
        })

      objects = %{
        ("manifests/" <> tag) => {@index, index},
        ("manifests/" <> tag <> "-linux-amd64") => {@manifest, manifest},
        ("manifests/" <> digest(manifest)) => {@manifest, manifest},
        ("blobs/" <> digest(config)) => {"application/octet-stream", config},
        ("blobs/" <> digest(content)) => {"application/octet-stream", content}
      }

      objects =
        Map.new(objects, fn {suffix, value} -> {"/v2/" <> repo <> "/" <> suffix, value} end)

      receipt = %{
        "digest" => digest(manifest),
        "sizeBytes" => byte_size(content),
        "platform" => "linux/amd64",
        "manifest" => config
      }

      {receipt,
       %{
         state
         | objects: Map.merge(state.objects, objects),
           publications: state.publications + 1
       }}
    else
      {%{}, state}
    end
  end

  defp serve(conn, agent) do
    state = Agent.get(agent, & &1)

    if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> state.token] do
      case state.objects[conn.request_path] do
        nil ->
          TestPeer.json(conn, %{}, 404)

        {media, bytes} ->
          conn
          |> Plug.Conn.put_resp_content_type(media)
          |> Plug.Conn.send_resp(200, response_body(conn.method, bytes))
      end
    else
      TestPeer.json(conn, %{}, 401)
    end
  end

  defp response_body("HEAD", _bytes), do: ""
  defp response_body(_method, bytes), do: bytes

  defp descriptor(bytes, media),
    do: %{"mediaType" => media, "digest" => digest(bytes), "size" => byte_size(bytes)}

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
