Code.require_file("examples/embedded_port/lib/branch_control.ex")
Code.require_file("examples/embedded_port/lib/branch_demo.ex")

defmodule SmolBox.EmbeddedBranchExampleTest do
  use ExUnit.Case, async: true
  alias SmolBox.Example.{EmbeddedBranchControl, EmbeddedBranches}
  alias SmolBox.Test.EmbeddedPackage

  test "installed workflow compiles without warnings in a fresh BEAM" do
    paths = :code.get_path() |> Enum.map(&List.to_string/1) |> Enum.filter(&File.dir?/1)

    code = """
    {:ok, modules, %{compile_warnings: [], runtime_warnings: []}} =
      Kernel.ParallelCompiler.compile(System.argv(), return_diagnostics: true)
    true = length(modules) == 2
    IO.puts("cold branch workflow compile passed")
    """

    args =
      Enum.flat_map(paths, &["-pa", &1]) ++
        ["-e", code] ++
        Enum.map(
          ~w(branch_control.ex branch_demo.ex),
          &Path.expand("examples/embedded_port/lib/" <> &1)
        )

    {output, status} =
      System.cmd(System.find_executable("elixir"), args,
        env: [{"ERL_FLAGS", "+S 2:2"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "cold branch workflow compile passed"
  end

  defmodule ShutdownPeer do
    def health(server) do
      Agent.get_and_update(server, fn [status | rest] -> {{:ok, %{status: status}}, rest} end)
    end
  end

  defmodule ShutdownAdmissionPeer do
    use GenServer
    def start_link(options), do: GenServer.start_link(__MODULE__, options)
    def init(options), do: {:ok, %{replies: options[:replies], attempts: 0, releases: 0}}

    def handle_call({:native_acquire, _id}, _from, state) do
      [reply | rest] = state.replies
      replies = if rest == [], do: [reply], else: rest
      {:reply, reply, %{state | replies: replies, attempts: state.attempts + 1}}
    end

    def handle_call({:native_release, _id}, _from, state),
      do: {:reply, :ok, %{state | releases: state.releases + 1}}

    def handle_call(:counts, _from, state),
      do: {:reply, Map.take(state, [:attempts, :releases]), state}
  end

  test "normal close waits only for undispatched admission and enters its original callback once" do
    busy = shutdown_busy(:not_dispatched)
    coordinator = start_supervised!({ShutdownAdmissionPeer, replies: [busy, busy, :ok]})
    epoch = make_ref()

    assert :ok =
             EmbeddedBranches.shutdown_authority(
               coordinator,
               "original",
               System.monotonic_time(:millisecond) + 1000,
               fn ->
                 send(self(), {:shutdown_entered, epoch})
                 :ok
               end
             )

    assert_receive {:shutdown_entered, ^epoch}
    refute_receive {:shutdown_entered, _}, 0
    assert GenServer.call(coordinator, :counts) == %{attempts: 3, releases: 1}
  end

  test "an entered normal close result is never replayed even when it resembles admission rejection" do
    coordinator = start_supervised!({ShutdownAdmissionPeer, replies: [:ok]})
    error = shutdown_busy(:not_dispatched)

    assert ^error =
             EmbeddedBranches.shutdown_authority(
               coordinator,
               "original",
               System.monotonic_time(:millisecond) + 1000,
               fn ->
                 send(self(), :shutdown_entered)
                 error
               end
             )

    assert_receive :shutdown_entered
    refute_receive :shutdown_entered, 0
    assert GenServer.call(coordinator, :counts) == %{attempts: 1, releases: 1}
  end

  test "expired or uncertain normal-close admission cannot enter the shutdown callback" do
    coordinator = start_supervised!({ShutdownAdmissionPeer, replies: [:ok]})

    assert {:error, %{category: :expired, evidence: :not_dispatched}} =
             EmbeddedBranches.shutdown_authority(
               coordinator,
               "original",
               System.monotonic_time(:millisecond) - 1,
               fn -> flunk("expired close entered") end
             )

    assert GenServer.call(coordinator, :counts) == %{attempts: 0, releases: 0}
    uncertain = shutdown_busy(:dispatch_uncertain)
    other = start_supervised!({ShutdownAdmissionPeer, replies: [uncertain]}, id: :uncertain)

    assert ^uncertain =
             EmbeddedBranches.shutdown_authority(
               other,
               "original",
               System.monotonic_time(:millisecond) + 1000,
               fn -> flunk("uncertain close entered") end
             )

    assert GenServer.call(other, :counts) == %{attempts: 1, releases: 0}
  end

  test "continuously busy normal-close admission cannot renew its captured deadline" do
    coordinator =
      start_supervised!({ShutdownAdmissionPeer, replies: [shutdown_busy(:not_dispatched)]})

    entered = System.monotonic_time(:millisecond)

    assert {:error, %{category: :expired, evidence: :not_dispatched}} =
             EmbeddedBranches.shutdown_authority(coordinator, "original", entered + 50, fn ->
               flunk("busy close entered")
             end)

    assert System.monotonic_time(:millisecond) - entered < 1000
    assert %{attempts: attempts, releases: 0} = GenServer.call(coordinator, :counts)
    assert attempts >= 1
  end

  defp shutdown_busy(evidence),
    do:
      {:error,
       %SmolBox.Error{
         category: :admission_exhausted,
         operation: :reconcile,
         evidence: evidence
       }}

  test "normal protocol shutdown waits through channel draining before stopping supervision" do
    server =
      start_supervised!({Agent, fn -> [:unavailable, :closing, :unavailable, :stopped] end})

    assert :ok =
             EmbeddedBranches.await_stopped(
               ShutdownPeer,
               server,
               System.monotonic_time(:millisecond) + 1000
             )

    assert Agent.get(server, & &1) == []
  end

  test "a failed or expired shutdown does not authorize supervision stop" do
    for status <- [:quarantined, :ready] do
      server = start_supervised!({Agent, fn -> [status] end}, id: status)

      assert_raise CaseClauseError, fn ->
        EmbeddedBranches.await_stopped(
          ShutdownPeer,
          server,
          System.monotonic_time(:millisecond) + 1000
        )
      end
    end

    server = start_supervised!({Agent, fn -> [:unavailable] end}, id: :expired)

    assert_raise MatchError, fn ->
      EmbeddedBranches.await_stopped(
        ShutdownPeer,
        server,
        System.monotonic_time(:millisecond) - 1
      )
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "branch-control-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for platform <- [:linux, :macos] do
    test "ordinary #{platform} branch plan keeps extra backing charged until separate release" do
      sdk =
        File.read!("native/smolbox-protocol/fixtures/hello-v2-#{unquote(platform)}-branches.json")
        |> Jason.decode!()
        |> get_in(~w(hello sdk))

      target =
        EmbeddedPackage.create(protocol_major: 2, platform: unquote(platform), sdk_identity: sdk)

      on_exit(fn -> File.rm_rf!(target.package_path) end)
      configured = EmbeddedBranches.configure(target)
      assert configured.artifacts == target.artifacts
      assert configured.package_identity == target.package_identity
      assert configured.package_manifest_sha256 == target.package_manifest_sha256
      [profile] = configured.profiles
      [policy] = configured.branch_policies
      assert profile.network == :offline and profile.host_overhead_mb == 128
      assert EmbeddedBranches.expected_usage(profile, policy, 3, 2) == configured.capacity

      assert EmbeddedBranches.expected_usage(profile, policy, 0, 2) == %{
               slots: 2,
               cpus: 2,
               memory_mb: 1280,
               disk_gb: 10
             }

      assert EmbeddedBranches.expected_usage(profile, policy, 0, 1) == policy.resources

      assert EmbeddedBranches.expected_usage(profile, policy, 0, 0) == %{
               slots: 0,
               cpus: 0,
               memory_mb: 0,
               disk_gb: 0
             }

      assert EmbeddedPackage.received(target) == []
    end
  end

  test "capture plan declares bounded private storage without enabling native I/O", %{root: root} do
    sdk =
      File.read!("native/smolbox-protocol/fixtures/hello-v2-macos-branches.json")
      |> Jason.decode!()
      |> get_in(~w(hello sdk))

    target = EmbeddedPackage.create(protocol_major: 2, platform: :macos, sdk_identity: sdk)
    on_exit(fn -> File.rm_rf!(target.package_path) end)

    configured =
      EmbeddedBranches.configure(target,
        capture_root: root,
        checkpoint_seed: %{
          path: Path.join(root, "seed.smolcheckpoint"),
          sha256: String.duplicate("a", 64)
        }
      )

    [policy] = configured.checkpoint_policies
    assert policy.root == root and policy.max_bytes == 536_870_912
    assert policy.resources == %{slots: 1, cpus: 1, memory_mb: 640, disk_gb: 8}
    assert [%SmolBox.Checkpoint{profile: profile}] = configured.checkpoints
    assert profile == hd(configured.profiles)
    assert configured.artifacts == target.artifacts
    assert EmbeddedPackage.received(target) == []
  end

  test "private control requests are consumed before dispatch and duplicate IDs cannot replay", %{
    root: root
  } do
    request = %{"request_id" => "status1", "action" => "status"}
    assert :none = EmbeddedBranchControl.receive_request(root)
    publish(root, request)
    assert {:ok, ^request} = EmbeddedBranchControl.receive_request(root)
    assert :none = EmbeddedBranchControl.receive_request(root)
    publish(root, request)
    assert :rejected = EmbeddedBranchControl.receive_request(root)
    assert File.exists?(Path.join(root, "control-processed-status1.json"))
  end

  test "branch resolution and backing require positive attestations and bounded original handles",
       %{root: root} do
    for {action, field} <- [
          {"retire", "quiesced"},
          {"resolve_ready", "quiesced"},
          {"resolve_deleted", "quiesced"},
          {"collect_partial", "quiesced"},
          {"publish_collected", "quiesced"},
          {"dispose_partial", "quiesced"},
          {"cleanup_partial", "quiesced"},
          {"collect_deletion", "quiesced"},
          {"continue_deletion", "quiesced"},
          {"cleanup_deletion", "quiesced"},
          {"backing", "backing_removed"}
        ] do
      request = %{
        "request_id" => action |> String.replace("_", ""),
        "action" => action,
        "id" => "first",
        "version" => 7,
        field => true
      }

      for invalid <- [
            Map.delete(request, field),
            Map.put(request, field, false),
            Map.put(request, "version", 0),
            Map.put(request, "id", "source"),
            Map.put(request, "id", "foreign"),
            Map.put(request, "path", "/foreign"),
            Map.put(request, "pid", 123),
            Map.put(request, "request_id", "../escape")
          ] do
        publish(root, invalid)
        assert :rejected = EmbeddedBranchControl.receive_request(root)
      end

      publish(root, request)
      assert {:ok, ^request} = EmbeddedBranchControl.receive_request(root)
    end
  end

  test "backing absence checks use the actual pinned SDK platform cache" do
    assert EmbeddedBranches.backing_path("/Users/test", :macos, "abcdef") ==
             "/Users/test/Library/Caches/smolvm/vms/abcdef"

    assert EmbeddedBranches.backing_path("/home/test", :linux, "abcdef") ==
             "/home/test/.cache/smolvm/vms/abcdef"
  end

  test "capture controls bind only the original source and require positive attestations", %{
    root: root
  } do
    for {action, field} <- [
          {"resolve_capture", "quiesced"},
          {"release_capture", "artifacts_removed"}
        ] do
      request = %{
        "request_id" => String.replace(action, "_", ""),
        "action" => action,
        "id" => "source",
        "version" => 9,
        field => true
      }

      for invalid <- [
            Map.delete(request, field),
            Map.put(request, field, false),
            Map.put(request, "id", "first"),
            Map.put(request, "path", "/foreign"),
            Map.put(request, "version", 0)
          ] do
        publish(root, invalid)
        assert :rejected = EmbeddedBranchControl.receive_request(root)
      end

      publish(root, request)
      assert {:ok, ^request} = EmbeddedBranchControl.receive_request(root)
    end
  end

  test "control rejects symlinks oversized public files and termination verbs", %{root: root} do
    path = Path.join(root, "control.json")
    outside = Path.join(root, "original.json")
    File.write!(outside, Jason.encode!(%{"request_id" => "status1", "action" => "status"}))
    File.chmod!(outside, 0o600)
    File.ln_s!(outside, path)
    assert :rejected = EmbeddedBranchControl.receive_request(root)
    File.rm!(path)
    File.write!(path, String.duplicate(" ", 4097))
    File.chmod!(path, 0o600)
    assert :rejected = EmbeddedBranchControl.receive_request(root)

    for action <- ~w(kill signal crash restart adopt replay) do
      publish(root, %{"request_id" => "attempt", "action" => action})
      assert :rejected = EmbeddedBranchControl.receive_request(root)
    end

    publish(root, %{"request_id" => "public1", "action" => "status"})
    File.chmod!(path, 0o644)
    assert :rejected = EmbeddedBranchControl.receive_request(root)
  end

  defp publish(root, request) do
    path = Path.join(root, "control.json")
    File.write!(path, Jason.encode!(request))
    File.chmod!(path, 0o600)
  end
end
