Code.require_file("examples/embedded_port/lib/growth_control.ex")
Code.require_file("examples/embedded_port/lib/growth_demo.ex")

defmodule SmolBox.EmbeddedGrowthExampleTest do
  use ExUnit.Case, async: true
  alias SmolBox.Example.{EmbeddedGrowth, EmbeddedGrowthControl}
  alias SmolBox.Test.EmbeddedPackage

  test "explicit artifact selection retains the existing catalog and single-artifact default" do
    application = %{
      "id" => "application",
      "sha256" => String.duplicate("a", 64),
      "architecture" => "x86_64",
      "path" => "/approved/application.smolmachine",
      "max_bytes" => 1000
    }

    bare = %{application | "id" => "bare", "sha256" => String.duplicate("b", 64)}
    catalog = [application, bare]
    selected = Map.take(bare, ~w(id sha256 architecture))
    assert EmbeddedGrowth.select_artifact(catalog, "bare") == selected
    assert EmbeddedGrowth.select_artifact(Enum.reverse(catalog), "bare") == selected

    assert EmbeddedGrowth.select_artifact([application]) ==
             Map.take(application, ~w(id sha256 architecture))
  end

  test "ambiguous missing and duplicate artifact selection is rejected" do
    application = %{"id" => "application"}
    bare = %{"id" => "bare"}

    for {catalog, id} <- [
          {[], nil},
          {[application, bare], nil},
          {[application, bare], "unapproved"},
          {[application, bare, bare], "bare"},
          {[application], :application}
        ] do
      assert_raise ArgumentError, "select exactly one approved artifact by id", fn ->
        EmbeddedGrowth.select_artifact(catalog, id)
      end
    end
  end

  test "remote source selection preserves the approved identity and never replaces local defaults" do
    {:ok, oci} =
      SmolBox.Source.oci(
        id: "remote",
        reference: "registry.example/app@sha256:" <> String.duplicate("a", 64),
        architecture: "x86_64"
      )

    {:ok, registry} =
      SmolBox.Source.registry(
        id: "pack",
        reference: "registry.example/pack@sha256:" <> String.duplicate("b", 64),
        content_sha256: String.duplicate("c", 64),
        architecture: "x86_64",
        credential_ref: "read"
      )

    artifact = %{
      "id" => "local",
      "sha256" => String.duplicate("d", 64),
      "architecture" => "x86_64"
    }

    target = struct(SmolBox.Embedded.Config, artifacts: [artifact], sources: [oci, registry])
    assert EmbeddedGrowth.select_input(target) == artifact

    assert EmbeddedGrowth.select_input(target, source_id: "remote") ==
             SmolBox.Source.artifact(oci)

    assert EmbeddedGrowth.select_input(target, source_id: "pack", artifact_id: nil) ==
             SmolBox.Source.artifact(registry)

    assert target.sources == [oci, registry] and target.artifacts == [artifact]

    assert_raise ArgumentError, "select either an artifact or a source", fn ->
      EmbeddedGrowth.select_input(target, artifact_id: "local", source_id: "remote")
    end

    for {catalog, id} <- [
          {[oci, registry], "missing"},
          {[oci, oci], "remote"},
          {[oci], :remote},
          {[], "remote"}
        ] do
      assert_raise ArgumentError, "select exactly one approved remote source by id", fn ->
        EmbeddedGrowth.select_source(catalog, id)
      end
    end

    assert_raise ArgumentError, "select exactly one approved artifact by id", fn ->
      EmbeddedGrowth.select_input(%{target | artifacts: []})
    end
  end

  test "network approval stays explicit when configuring a remote growth profile" do
    hello =
      File.read!("native/smolbox-protocol/fixtures/hello-v2-linux-images.json") |> Jason.decode!()

    target =
      EmbeddedPackage.create(
        protocol_major: 2,
        platform: :linux,
        sdk_identity: hello["hello"]["sdk"]
      )

    on_exit(fn -> File.rm_rf!(target.package_path) end)
    assert hd(EmbeddedGrowth.configure(target).profiles).network == :offline

    {:ok, source} =
      SmolBox.Source.oci(
        id: "remote",
        reference: "registry.example/app@sha256:" <> String.duplicate("a", 64),
        architecture: "x86_64"
      )

    offline = EmbeddedGrowth.configure(%{target | sources: [source]})
    output = Path.join(target.package_path, "no-source-launch")
    assert_raise MatchError, fn -> EmbeddedGrowth.run(offline, output, source_id: "remote") end
    refute File.exists?(output)
    {:ok, network} = SmolBox.NetworkPolicy.new(hosts: ["registry.example"])
    configured = EmbeddedGrowth.configure(target, network: network)
    assert hd(configured.profiles).network == network
    assert configured.artifacts == target.artifacts and configured.sources == target.sources
    assert configured.capacity.disk_gb == 8
    assert_raise MatchError, fn -> EmbeddedGrowth.configure(target, unexpected: true) end
    assert_raise MatchError, fn -> EmbeddedGrowth.configure(target, network: true) end
    assert EmbeddedPackage.received(target) == []
  end

  defp source_target do
    hello =
      File.read!("native/smolbox-protocol/fixtures/hello-v2-linux-images.json") |> Jason.decode!()

    target =
      EmbeddedPackage.create(
        protocol_major: 2,
        platform: :linux,
        sdk_identity: hello["hello"]["sdk"]
      )

    on_exit(fn -> File.rm_rf!(target.package_path) end)
    target
  end

  defp source_settings(kind) do
    source = %{
      "kind" => kind,
      "id" => "remote",
      "reference" => "registry.example/app@sha256:" <> String.duplicate("a", 64),
      "architecture" => "x86_64"
    }

    if kind == "oci" do
      %{
        "sources" => [source],
        "source_id" => "remote",
        "network" => %{"hosts" => ["registry.example"], "cidrs" => []}
      }
    else
      %{
        "sources" => [Map.put(source, "content_sha256", String.duplicate("b", 64))],
        "source_id" => "remote",
        "cache_policy" => %{
          "max_download_bytes" => 1_000_000,
          "max_cache_bytes" => 2_000_000,
          "max_cache_files" => 4
        }
      }
    end
  end

  test "growth settings use typed remote approvals while preserving package and artifact catalogs" do
    target = source_target()
    {local, []} = EmbeddedGrowth.configure_settings(target, %{})
    assert local == EmbeddedGrowth.configure(target)

    for kind <- ["oci", "registry"] do
      settings = source_settings(kind)
      {configured, selection} = EmbeddedGrowth.configure_settings(target, settings)
      assert selection == [source_id: "remote"]
      assert configured.artifacts == target.artifacts
      assert configured.package_path == target.package_path
      assert configured.package_manifest_sha256 == target.package_manifest_sha256
      assert configured.domain_generation == target.domain_generation
      assert EmbeddedGrowth.select_input(configured, selection)["kind"] == kind
      assert EmbeddedGrowth.configure_settings(configured, settings) == {configured, selection}

      if kind == "registry" do
        assert hd(configured.profiles).network == :offline
        assert configured.registry_policy.max_download_bytes == 1_000_000
      else
        assert hd(configured.profiles).network.hosts == ["registry.example"]
      end
    end

    assert EmbeddedPackage.received(target) == []
  end

  test "source settings reject broadened identities missing allowances and catalog replacement" do
    target = source_target()
    oci = source_settings("oci")
    registry = source_settings("registry")
    {configured, _} = EmbeddedGrowth.configure_settings(target, registry)

    for settings <- [
          Map.put(oci, "unexpected", true),
          Map.delete(oci, "network"),
          Map.put(oci, "network", true),
          put_in(oci, ["network", "unexpected"], true),
          Map.put(oci, "sources", oci["sources"] ++ oci["sources"]),
          Map.delete(registry, "cache_policy"),
          put_in(registry, ["cache_policy", "max_cache_bytes"], 0),
          put_in(registry, ["cache_policy", "token"], "forbidden")
        ] do
      assert_raise MatchError, fn ->
        EmbeddedGrowth.configure_settings(target, settings)
      end
    end

    assert_raise ArgumentError, fn ->
      EmbeddedGrowth.configure_settings(target, Map.put(oci, "artifact_id", "application"))
    end

    assert_raise ArgumentError, fn ->
      EmbeddedGrowth.configure_settings(target, Map.put(oci, "source_id", "unapproved"))
    end

    assert_raise MatchError, fn ->
      EmbeddedGrowth.configure_settings(
        configured,
        put_in(registry, ["cache_policy", "max_cache_files"], 8)
      )
    end

    assert_raise MatchError, fn ->
      EmbeddedGrowth.configure_settings(configured, oci)
    end

    assert_raise MatchError, fn ->
      EmbeddedGrowth.configure_settings(target, %{
        oci
        | "sources" => [Map.put(hd(oci["sources"]), "token", "forbidden")]
      })
    end

    assert EmbeddedPackage.received(target) == []
  end

  test "registry settings permit safe credential references and exact exchange realms" do
    target = source_target()
    settings = source_settings("registry")

    settings =
      settings
      |> Map.update!("sources", fn [source] -> [Map.put(source, "credential_ref", "read")] end)
      |> put_in(["cache_policy", "token_realms"], %{"read" => "https://auth.example/token"})

    {configured, selection} = EmbeddedGrowth.configure_settings(target, settings)
    assert EmbeddedGrowth.select_input(configured, selection)["credential_ref"] == "read"
    assert configured.registry_policy.token_realms == %{"read" => "https://auth.example/token"}

    assert_raise MatchError, fn ->
      EmbeddedGrowth.configure_settings(
        target,
        update_in(settings, ["cache_policy"], &Map.delete(&1, "token_realms"))
      )
    end
  end

  test "growth settings files are bounded owned regular private JSON maps", %{root: root} do
    path = Path.join(root, "settings.json")
    File.write!(path, Jason.encode!(source_settings("oci")))
    File.chmod!(path, 0o600)
    assert EmbeddedGrowth.read_settings!(path) == source_settings("oci")
    link = Path.join(root, "link.json")
    File.ln_s!(path, link)
    assert_raise MatchError, fn -> EmbeddedGrowth.read_settings!(link) end
    assert_raise MatchError, fn -> EmbeddedGrowth.read_settings!(Path.relative_to_cwd(path)) end
    File.chmod!(path, 0o644)
    assert_raise MatchError, fn -> EmbeddedGrowth.read_settings!(path) end
    File.chmod!(path, 0o600)
    File.write!(path, String.duplicate(" ", 65_537))
    assert_raise MatchError, fn -> EmbeddedGrowth.read_settings!(path) end
    File.write!(path, "[]")
    assert_raise MatchError, fn -> EmbeddedGrowth.read_settings!(path) end
  end

  setup do
    root = Path.expand(".local/growth-example-" <> Base.encode16(:crypto.strong_rand_bytes(8)))
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

  defp admission_record do
    %{
      version: 1,
      generation: 1,
      worker_generation: 1,
      claim_owner: nil,
      claim_until_ms: nil,
      updated_at_ms: 1000,
      next_due_at_ms: 1000,
      state: :stopped,
      machine_name: "original",
      backend_assignment: %{binding: "original-domain"},
      created_machine: %{receipt: "creation"},
      observed_machine: %{receipt: "current"},
      disk_sizes: %{storage_gb: 1, overlay_gb: 1},
      disk_expansions: %{},
      active_expansion: nil,
      reservation: %{slots: 1, disk_gb: 2},
      spec: %{source: "approved"},
      fingerprint: "original",
      last_error: nil
    }
  end

  defp stale_version do
    {:error,
     %SmolBox.Error{
       category: :stale_version,
       operation: :expand_disks,
       evidence: :not_dispatched
     }}
  end

  test "only unchanged lease metadata can refresh a rejected growth version" do
    record = admission_record()

    current = %{
      record
      | version: 2,
        generation: 2,
        worker_generation: 2,
        claim_owner: "owner",
        claim_until_ms: 3000,
        updated_at_ms: 2000,
        next_due_at_ms: 2500
    }

    call = fn value ->
      send(self(), {:attempted_version, value.version})
      if value.version == 1, do: stale_version(), else: {:ok, :accepted}
    end

    assert {:ok, :accepted} = EmbeddedGrowth.retry_version(record, call, fn -> current end)
    assert_received {:attempted_version, 1}
    assert_received {:attempted_version, 2}
    refute_received {:attempted_version, _}
  end

  test "changed authority, state, history or accounting prevents a growth retry" do
    record = admission_record()

    for field <-
          Map.keys(record) --
            [
              :version,
              :generation,
              :worker_generation,
              :claim_owner,
              :claim_until_ms,
              :updated_at_ms,
              :next_due_at_ms
            ] do
      current = record |> Map.put(:version, 2) |> Map.put(field, :changed)

      call = fn value ->
        send(self(), {:attempted_version, value.version})
        stale_version()
      end

      assert EmbeddedGrowth.retry_version(record, call, fn -> current end) == stale_version()
      assert_received {:attempted_version, 1}
      refute_received {:attempted_version, _}
    end
  end

  test "accepted, uncertain and other rejected operations never refresh or resubmit" do
    for result <- [
          {:ok, :accepted},
          {:error,
           %SmolBox.Error{
             operation: :expand_disks,
             category: :unknown,
             evidence: :dispatch_uncertain
           }},
          {:error,
           %SmolBox.Error{
             operation: :expand_disks,
             category: :stale_version,
             evidence: :dispatch_uncertain
           }},
          {:error,
           %SmolBox.Error{
             operation: :expand_disks,
             category: :admission_exhausted,
             evidence: :not_dispatched
           }},
          {:error,
           %SmolBox.Error{
             operation: :expand_disks,
             category: :identity_conflict,
             evidence: :not_dispatched
           }}
        ] do
      assert EmbeddedGrowth.retry_version(admission_record(), fn _ -> result end, fn ->
               flunk("must not refresh entered or non-version outcomes")
             end) == result
    end
  end

  test "growth retries require advancing versions and have a finite attempt limit" do
    record = admission_record()

    for version <- [0, 1] do
      assert EmbeddedGrowth.retry_version(record, fn _ -> stale_version() end, fn ->
               %{record | version: version}
             end) == stale_version()
    end

    Process.put(:growth_version, 1)

    call = fn value ->
      send(self(), {:bounded_attempt, value.version})
      stale_version()
    end

    fetch = fn ->
      next = Process.get(:growth_version) + 1
      Process.put(:growth_version, next)
      %{record | version: next}
    end

    assert EmbeddedGrowth.retry_version(record, call, fetch, 2) == stale_version()
    assert_received {:bounded_attempt, 1}
    assert_received {:bounded_attempt, 2}
    assert_received {:bounded_attempt, 3}
    refute_received {:bounded_attempt, _}
  end

  test "private status requests are consumed once, and duplicate IDs cannot replay", %{root: root} do
    request = %{"request_id" => "status1", "action" => "status"}
    assert :none = EmbeddedGrowthControl.receive_request(root)
    publish(root, request)
    assert {:ok, ^request} = EmbeddedGrowthControl.receive_request(root)
    assert :none = EmbeddedGrowthControl.receive_request(root)
    publish(root, request)
    assert :rejected = EmbeddedGrowthControl.receive_request(root)
    assert :none = EmbeddedGrowthControl.receive_request(root)
  end

  test "machine resolution control requires explicit quiescence and the original versioned handle",
       %{root: root} do
    request = %{
      "request_id" => "resolvemachine1",
      "action" => "resolve_machine",
      "id" => "original",
      "version" => 7,
      "quiesced" => true
    }

    publish(root, request)
    assert {:ok, ^request} = EmbeddedGrowthControl.receive_request(root)
    assert :none = EmbeddedGrowthControl.receive_request(root)

    for change <- [
          %{"quiesced" => false},
          %{"version" => 0},
          %{"version" => "7"},
          %{"id" => "foreign"},
          %{"disposition" => "deleted"}
        ] do
      invalid = request |> Map.merge(change) |> Map.put("request_id", "invalidresolution")
      publish(root, invalid)
      assert :rejected = EmbeddedGrowthControl.receive_request(root)
    end
  end

  test "owned stop control uses the original exact-version handle and consumes it once", %{
    root: root
  } do
    request = %{
      "request_id" => "ownedstop1",
      "action" => "stop_owned_machine",
      "id" => "original",
      "version" => 7
    }

    publish(root, request)
    assert {:ok, ^request} = EmbeddedGrowthControl.receive_request(root)
    publish(root, request)
    assert :rejected = EmbeddedGrowthControl.receive_request(root)

    for {change, index} <-
          Enum.with_index([
            %{"version" => 0},
            %{"version" => "7"},
            %{"id" => "warm"},
            %{"pid" => 1234},
            %{"quiesced" => true},
            %{"expansion" => "first"}
          ]) do
      invalid = request |> Map.merge(change) |> Map.put("request_id", "invalidstop#{index}")
      publish(root, invalid)
      assert :rejected = EmbeddedGrowthControl.receive_request(root)
    end
  end

  test "growth resolution requires explicit quiescence, a known intent and exact version", %{
    root: root
  } do
    request = %{
      "request_id" => "resolve1",
      "action" => "resolve_growth",
      "id" => "original",
      "expansion" => "first",
      "version" => 7,
      "quiesced" => true
    }

    publish(root, request)
    assert {:ok, ^request} = EmbeddedGrowthControl.receive_request(root)

    for {altered, index} <-
          Enum.with_index([
            Map.put(request, "version", 0),
            Map.put(request, "id", "foreign"),
            Map.put(request, "expansion", "other"),
            Map.put(request, "quiesced", false),
            Map.delete(request, "quiesced"),
            Map.put(request, "disposition", "deleted"),
            Map.put(request, "request_id", "../outside")
          ]) do
      altered =
        if altered["request_id"] == "../outside",
          do: altered,
          else: Map.put(altered, "request_id", "invalid#{index}")

      publish(root, altered)
      assert :rejected = EmbeddedGrowthControl.receive_request(root)
    end
  end

  test "control refuses redirected, public or oversized requests", %{root: root} do
    publish(root, %{"request_id" => "public", "action" => "close"}, 0o644)
    assert :rejected = EmbeddedGrowthControl.receive_request(root)
    outside = Path.join(root, "outside.json")
    File.write!(outside, Jason.encode!(%{"request_id" => "link", "action" => "close"}))
    File.chmod!(outside, 0o600)
    File.ln_s!(outside, Path.join(root, "control.json"))
    assert :rejected = EmbeddedGrowthControl.receive_request(root)
    assert File.exists?(outside)
    File.write!(Path.join(root, "control.json"), String.duplicate(" ", 4097))
    File.chmod!(Path.join(root, "control.json"), 0o600)
    assert :rejected = EmbeddedGrowthControl.receive_request(root)
  end

  test "a consumed dangling-link ID is still a replay fence", %{root: root} do
    File.ln_s!(Path.join(root, "absent"), Path.join(root, "control-processed-same.json"))
    publish(root, %{"request_id" => "same", "action" => "close"})
    assert :rejected = EmbeddedGrowthControl.receive_request(root)
  end

  test "close invokes the original cleanup predicate and exits normally only on success", %{
    root: root
  } do
    publish(root, %{"request_id" => "close1", "action" => "close"})
    parent = self()
    context = %{root: root, scope: "test"}

    assert :ok =
             EmbeddedGrowthControl.wait(context, fn ^context ->
               send(parent, :verified)
               :ok
             end)

    assert_received :verified
    result = Path.join(root, "control-result-close1.json") |> File.read!() |> Jason.decode!()
    assert result == %{"status" => "closed"}
  end

  defp workspace_tools(root) do
    bin = Path.join(root, "bin")
    File.mkdir!(bin)

    File.write!(Path.join(bin, "df"), """
    #!/bin/sh
    test "$*" = '-Pk /workspace' || exit 2
    count=$(cat "$DF_COUNT")
    printf '%s\\n' "$((count + 1))" > "$DF_COUNT"
    printf '%s\\n' "$DF_OUTPUT"
    exit "$DF_STATUS"
    """)

    File.write!(Path.join(bin, "sleep"), "#!/bin/sh\ntest \"$*\" = 1\n")
    for name <- ~w(df sleep), do: File.chmod!(Path.join(bin, name), 0o700)
    bin
  end

  defp workspace_probe(root, bin, row, status \\ 0) do
    count = Path.join(root, "measurements")
    File.write!(count, "0\n")
    %{argv: ["/bin/sh", "-c", script]} = EmbeddedGrowth.workspace_command(10_240, 20_480)

    result =
      System.cmd("/bin/sh", ["-c", script],
        env: [
          {"PATH", bin <> ":/usr/bin:/bin"},
          {"DF_COUNT", count},
          {"DF_OUTPUT", "Filesystem 1024-blocks Used Available Capacity Mounted on\n" <> row},
          {"DF_STATUS", to_string(status)}
        ],
        stderr_to_stdout: true
      )

    {result, count |> File.read!() |> String.trim() |> String.to_integer()}
  end

  test "portable workspace probe measures KiB accurately and has a finite wait", %{root: root} do
    bin = workspace_tools(root)

    for {blocks, expected, attempts} <- [{9, 1, 11}, {10, 0, 1}, {20, 0, 1}, {21, 1, 1}] do
      {{output, code}, measured} =
        workspace_probe(root, bin, "fixture #{blocks} 0 0 0% /workspace")

      assert code == expected
      assert measured == attempts
      if code == 0, do: assert(output == "workspace_bytes=#{blocks * 1024}\n")
    end
  end

  test "portable workspace probe rejects failed, missing, malformed or ambiguous measurements", %{
    root: root
  } do
    bin = workspace_tools(root)

    for row <- [
          "fixture NaN 0 0 0% /workspace",
          "fixture -10 0 0 0% /workspace",
          "fixture 99999999999999999999 0 0 0% /workspace",
          "fixture 10",
          "",
          "fixture 10 0 0 0% /workspace\nother 10 0 0 0% /workspace"
        ] do
      assert {{_output, 1}, 1} = workspace_probe(root, bin, row)
    end

    assert {{_output, 1}, 1} = workspace_probe(root, bin, "fixture 10 0 0 0% /workspace", 1)
  end

  test "invalid durable phase and checkpoint fail before owner launch", %{root: root} do
    hello =
      File.read!("native/smolbox-protocol/fixtures/hello-v2-linux-current.json")
      |> Jason.decode!()

    target =
      EmbeddedPackage.create(
        protocol_major: 2,
        platform: :linux,
        sdk_identity: hello["hello"]["sdk"]
      )

    on_exit(fn -> File.rm_rf!(target.package_path) end)
    target = EmbeddedGrowth.configure(target)
    output = Path.join(root, "not-created")
    assert_raise MatchError, fn -> EmbeddedGrowth.run(target, output, phase: :prepare) end

    assert_raise File.Error, fn ->
      EmbeddedGrowth.run(target, output,
        phase: :resume,
        mode: :durable,
        store: {SmolBox.Store.Memory, :absent},
        fingerprint_key: String.duplicate("k", 32),
        expected_records: Path.join(root, "absent")
      )
    end

    assert EmbeddedPackage.received(target) == []
    refute File.exists?(output)
  end
end
