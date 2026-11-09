Code.require_file("examples/embedded_port/lib/volume_control.ex")
Code.require_file("examples/embedded_port/lib/volume_demo.ex")

defmodule SmolBox.EmbeddedVolumeExampleTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.SDKIdentity
  alias SmolBox.Example.{EmbeddedVolumeControl, EmbeddedVolumes}
  alias SmolBox.Test.EmbeddedPackage

  setup do
    root = Path.expand(".local/volume-example-" <> Base.encode16(:crypto.strong_rand_bytes(8)))
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp publish(root, request, mode \\ 0o600) do
    path = Path.join(root, "control.json")
    File.write!(path, Jason.encode!(request))
    File.chmod!(path, mode)
  end

  test "private status requests are consumed once, and duplicate IDs cannot replay", %{root: root} do
    request = %{"request_id" => "status1", "action" => "status"}
    assert :none = EmbeddedVolumeControl.receive_request(root)
    publish(root, request)
    assert {:ok, ^request} = EmbeddedVolumeControl.receive_request(root)
    assert :none = EmbeddedVolumeControl.receive_request(root)
    publish(root, request)
    assert :rejected = EmbeddedVolumeControl.receive_request(root)
    assert :none = EmbeddedVolumeControl.receive_request(root)
  end

  test "only scoped known mutation IDs and positive exact versions parse", %{root: root} do
    for {action, id} <- [
          {"stop_machine", "original"},
          {"delete_machine", "readonly"},
          {"delete_volume", "data"}
        ] do
      request = %{
        "request_id" => String.replace(action, "_", ""),
        "action" => action,
        "id" => id,
        "version" => 7
      }

      publish(root, request)
      assert {:ok, ^request} = EmbeddedVolumeControl.receive_request(root)
    end

    base = %{"request_id" => "bad", "action" => "delete_volume", "id" => "data", "version" => 7}

    for request <- [
          Map.put(base, "version", 0),
          Map.put(base, "version", "7"),
          Map.put(base, "id", "foreign"),
          Map.put(base, "scope", "other"),
          Map.put(base, "request_id", "../outside"),
          Map.put(base, "action", "resolve_delete")
        ] do
      publish(root, request)
      assert :rejected = EmbeddedVolumeControl.receive_request(root)
    end
  end

  test "control refuses redirected, public or oversized requests", %{root: root} do
    publish(root, %{"request_id" => "public", "action" => "close"}, 0o644)
    assert :rejected = EmbeddedVolumeControl.receive_request(root)
    outside = Path.join(root, "outside.json")
    File.write!(outside, Jason.encode!(%{"request_id" => "link", "action" => "close"}))
    File.chmod!(outside, 0o600)
    File.ln_s!(outside, Path.join(root, "control.json"))
    assert :rejected = EmbeddedVolumeControl.receive_request(root)
    assert File.exists?(outside)
    File.write!(Path.join(root, "control.json"), String.duplicate(" ", 4097))
    File.chmod!(Path.join(root, "control.json"), 0o600)
    assert :rejected = EmbeddedVolumeControl.receive_request(root)
  end

  test "a consumed dangling-link ID is still a replay fence", %{root: root} do
    File.ln_s!(Path.join(root, "absent"), Path.join(root, "control-processed-same.json"))
    publish(root, %{"request_id" => "same", "action" => "close"})
    assert :rejected = EmbeddedVolumeControl.receive_request(root)
  end

  test "close invokes the original cleanup predicate and exits normally only on success", %{
    root: root
  } do
    publish(root, %{"request_id" => "close1", "action" => "close"})
    parent = self()
    context = %{root: root, scope: "test"}

    assert :ok =
             EmbeddedVolumeControl.wait(context, fn ^context ->
               send(parent, :verified)
               :ok
             end)

    assert_received :verified
    result = Path.join(root, "control-result-close1.json") |> File.read!() |> Jason.decode!()
    assert result == %{"status" => "closed"}
  end

  test "admission retry requires pre-entry rejection plus an unchanged durable record" do
    rejected = {:error, %SmolBox.Error{category: :admission_exhausted, operation: :reconcile}}
    Process.put(:volume_attempts, [rejected, {:ok, :completed}])

    call = fn ->
      [next | rest] = Process.get(:volume_attempts)
      Process.put(:volume_attempts, rest)
      next
    end

    assert {:ok, :completed} = EmbeddedVolumes.retry_admission(call, fn -> true end)
    assert Process.get(:volume_attempts) == []
    assert ^rejected = EmbeddedVolumes.retry_admission(fn -> rejected end, fn -> false end)

    assert ^rejected =
             EmbeddedVolumes.retry_admission(
               fn -> rejected end,
               fn -> flunk("no guard beyond bound") end,
               0
             )

    uncertain =
      {:error,
       %SmolBox.Error{
         category: :admission_exhausted,
         operation: :volume,
         evidence: :dispatch_uncertain
       }}

    assert ^uncertain =
             EmbeddedVolumes.retry_admission(fn -> uncertain end, fn ->
               flunk("uncertain entry cannot retry")
             end)
  end

  test "failure diagnostics preserve rejection evidence without argument values or paths" do
    rejected = %SmolBox.Error{category: :admission_exhausted, operation: :volume}
    secret = "private-owner-token"
    error = %MatchError{term: {:error, rejected}}
    stack = [{__MODULE__, :fake, [secret], [file: "/private/" <> secret, line: 7]}]
    diagnostic = EmbeddedVolumes.diagnostics(error, stack)

    assert diagnostic.rejected == %{
             category: :admission_exhausted,
             operation: :volume,
             evidence: :not_dispatched
           }

    assert [%{arity: 1, line: 7}] = diagnostic.frames
    refute Jason.encode!(diagnostic) =~ secret
  end

  test "phase and checkpoint rejection precede helper launch", %{root: root} do
    sdk =
      SDKIdentity.implemented("1.22.0", "9f446ae00219148ca4a703914f44a8e2fab11655")
      |> put_in(["feature_versions", "volumes"], 1)

    target = EmbeddedPackage.create(protocol_major: 2, platform: :linux, sdk_identity: sdk)
    on_exit(fn -> File.rm_rf!(target.package_path) end)
    target = EmbeddedVolumes.configure(target, "/srv/smolvm/volumes")
    assert target.volume_policy.root == "/srv/smolvm/volumes"
    output = Path.join(root, "not-created")
    assert_raise MatchError, fn -> EmbeddedVolumes.run(target, output, phase: :prepare) end

    assert_raise File.Error, fn ->
      EmbeddedVolumes.run(target, output,
        phase: :resume,
        store: {SmolBox.Store.Memory, :absent},
        mode: :durable,
        fingerprint_key: String.duplicate("k", 32),
        expected_records: Path.join(root, "absent")
      )
    end

    refute File.exists?(output)
    assert EmbeddedPackage.received(target) == []
  end
end
