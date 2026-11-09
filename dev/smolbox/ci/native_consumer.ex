defmodule SmolBox.CI.NativeConsumer do
  @moduledoc false
  alias SmolBox.CI.{Child, Util}

  @root Path.expand("../../..", __DIR__)
  @native_options ~w(native_package native_fixture native_sha256 native_domain_json native_output)a

  def validate_options!(options) do
    validate_checkpoints!(options)
    validate_branches!(options)
    validate_images!(options)
    validate_growth!(options)
    validate_volume!(options)
    validate_terminal!(options)
    validate_workload!(options)
    validate_network!(options)

    Util.ensure!(
      !(options[:native_ordinary] || options[:native_public]) or options[:native_package] != nil,
      "native lifecycle modes require native consumer options"
    )

    Util.ensure!(
      !(options[:native_ordinary] && options[:native_public]),
      "--native-ordinary and --native-public are mutually exclusive"
    )

    Util.ensure!(
      !Enum.any?(@native_options, &Keyword.has_key?(options, &1)) or
        options[:native_ordinary] == true or options[:native_public] == true,
      "native consumer requires explicit --native-ordinary or --native-public; crash validation is deferred"
    )

    if options[:without_rust] do
      Util.ensure!(
        System.find_executable("rustc") == nil and System.find_executable("cargo") == nil,
        "--without-rust requires a PATH without rustc or cargo"
      )
    end

    if Enum.any?(@native_options, &Keyword.has_key?(options, &1)) do
      Enum.each(@native_options, &Util.ensure!(Keyword.has_key?(options, &1), "missing --#{&1}"))
      Util.ensure!(options[:without_rust] == true, "native consumer requires --without-rust")
      Util.ensure!(!File.exists?(options[:native_output]), "native output already exists")
      Util.ensure!(!File.exists?(options[:native_output] <> ".log"), "native log already exists")

      Util.ensure!(
        !File.exists?(options[:native_output] <> ".log.retained.json"),
        "unresolved native runner evidence already exists"
      )
    end
  end

  def run(consumer, environment, options) do
    if options[:native_package] do
      execute(consumer, environment, options)
    else
      %{scope: "not-requested", exercised: false}
    end
  end

  defp execute(consumer, environment, options) do
    tooling = Path.join(consumer, "proof-tooling")
    File.mkdir!(tooling)

    files = proof_files(consumer, tooling, options)

    hashes =
      Map.new(files, fn {source, destination} ->
        source = Path.join(@root, source)
        File.cp!(source, destination)
        {Path.basename(destination), Util.digest(destination)}
      end)

    {options, hashes} = copy_settings(tooling, options, hashes)

    arguments = [
      "mix",
      "run",
      "--no-compile",
      "native-proof.exs",
      "--without-rust",
      "--package",
      Path.expand(options[:native_package]),
      "--fixture",
      Path.expand(options[:native_fixture]),
      "--sha256",
      options[:native_sha256],
      "--domain-json",
      Path.expand(options[:native_domain_json]),
      "--inventory-helper",
      tooling,
      "--output",
      Path.expand(options[:native_output])
    ]

    log_path = Path.expand(options[:native_output]) <> ".log"
    arguments = arguments ++ mode_arguments(options)
    File.mkdir_p!(Path.dirname(log_path))

    {log, result} =
      Child.execute(arguments,
        cd: consumer,
        env: environment,
        timeout: 600_000,
        termination: :retain
      )

    retain_source(consumer, result)
    File.write!(log_path, log, [:exclusive])
    File.chmod!(log_path, 0o600)

    preserve_retained(result, log_path)

    Util.ensure!(result.status == "passed", "native consumer failed; inspect its private log")
    evidence = Util.json!(Path.join(options[:native_output], "evidence.json"))

    Util.ensure!(
      evidence["without_rust"] == true and evidence["owned_deleted"] == true and
        evidence["inventory_before"] == evidence["inventory_after"],
      "native consumer did not verify cleanup or no-Rust consumption"
    )

    ordinary = options[:native_ordinary] || options[:native_public] || false

    Util.ensure!(
      evidence["deliberate_process_interruption"] == !ordinary and
        evidence["crash_handling_qualified"] == false,
      "native consumer evidence does not match the requested interruption scope"
    )

    if options[:native_public] do
      Util.ensure!(
        evidence["public_native_admission_enabled"] == true and
          evidence["scope"] == "public-port-package-consumer",
        "native consumer did not exercise the public Runtime"
      )
    end

    verify_growth(evidence, options)
    verify_volume(evidence, options)
    verify_terminal(evidence, options)
    verify_network(evidence, options)
    verify_workload(evidence, options)
    verify_images(evidence, options)
    verify_branches(evidence, options)
    verify_checkpoints(evidence, options)

    %{
      scope: scope(options),
      exercised: true,
      proof_tool_sha256: hashes,
      evidence: evidence
    }
  end

  defp validate_checkpoints!(options) do
    if options[:native_checkpoints] do
      Util.ensure!(
        options[:native_public] == true,
        "--native-checkpoints requires explicit --native-public"
      )

      Util.ensure!(
        !Enum.any?(
          ~w(native_branches native_images native_growth native_volume native_terminal native_network native_workload)a,
          &options[&1]
        ),
        "native checkpoint and other campaigns must run separately"
      )

      Util.ensure!(
        is_binary(options[:native_checkpoint_seed]) and
          File.regular?(options[:native_checkpoint_seed]) and
          is_binary(options[:native_checkpoint_seed_sha256]) and
          Regex.match?(~r/\A[0-9a-f]{64}\z/, options[:native_checkpoint_seed_sha256]),
        "native checkpoints require an approved seed path and SHA-256"
      )
    end
  end

  defp verify_checkpoints(evidence, options) do
    if options[:native_checkpoints] do
      expected = %{
        "campaign" => "ordinary-public-native-checkpoints",
        "store_mode" => "ephemeral",
        "capture_source_continues" => true,
        "duplicate_capture_retained" => true,
        "stopped_runtime_replacement" => true,
        "ram_and_disk_restored" => true,
        "independent_restores" => 2,
        "cold_restart_does_not_restore_ram" => true,
        "captured_bytes_unchanged" => true,
        "capture_artifact_removed" => true,
        "native_capture_cleanup" => true,
        "codec_roundtrips" => true,
        "final_reserved_slots" => 0,
        "final_reserved_disk_gb" => 0
      }

      Util.ensure!(
        Enum.all?(expected, fn {key, value} -> evidence[key] == value end),
        "native consumer did not qualify the requested public checkpoint lifecycle"
      )
    end
  end

  defp validate_branches!(options) do
    if options[:native_branches] do
      Util.ensure!(
        options[:native_public] == true,
        "--native-branches requires explicit --native-public"
      )

      Util.ensure!(
        !Enum.any?(
          ~w(native_checkpoints native_images native_growth native_volume native_terminal native_network native_workload)a,
          &options[&1]
        ),
        "native branch and other campaigns must run separately"
      )
    end
  end

  defp verify_branches(evidence, options) do
    if options[:native_branches] do
      expected = %{
        "campaign" => "ordinary-public-native-branches",
        "store_mode" => "ephemeral",
        "source_and_two_children_independent" => true,
        "held_release" => true,
        "duplicate_release_retained" => true,
        "cold_restart_does_not_restore_ram" => true,
        "source_dependencies_retired" => 2,
        "native_backing_acknowledgements" => 2,
        "branch_budget_rejected_before_dispatch" => true,
        "drain_rejected_new_branch" => true,
        "codec_roundtrips" => true,
        "final_reserved_slots" => 0,
        "final_reserved_disk_gb" => 0
      }

      Util.ensure!(
        Enum.all?(expected, fn {key, value} -> evidence[key] == value end),
        "native consumer did not qualify the requested public branch lifecycle and backing accounting"
      )
    end
  end

  @doc false
  def retain_source(consumer, %{retained: true} = result) do
    # Set the in-process guard before diagnostic I/O: even a full disk must not
    # make the caller remove code still used by the retained qualification owner.
    Process.put({__MODULE__, :retained_source, consumer}, true)

    marker = %{
      scope: "retained-native-consumer-source",
      child: Map.take(result, [:running, :diagnostic_os_pid]),
      cleanup_authority: false
    }

    path = Path.join(consumer, ".native-consumer-retained.json")
    File.write!(path, JSON.encode!(marker), [:exclusive])
    File.chmod!(path, 0o600)
    :ok
  rescue
    _ -> :diagnostic_unavailable
  end

  def retain_source(_consumer, _result), do: :ok

  @doc false
  def retained_source?(consumer),
    do:
      Process.get({__MODULE__, :retained_source, consumer}, false) or
        File.lstat(Path.join(consumer, ".native-consumer-retained.json")) != {:error, :enoent}

  defp validate_volume!(options) do
    Util.ensure!(
      !options[:native_volume] or options[:native_public] == true,
      "--native-volume requires explicit --native-public"
    )

    Util.ensure!(
      !options[:native_volume] or
        !(options[:native_terminal] || options[:native_network] || options[:native_workload]),
      "native volume, terminal, workload and network campaigns must run separately"
    )

    if options[:native_volume] do
      root = options[:native_volume_root]

      Util.ensure!(
        is_binary(root) and Path.type(root) == :absolute,
        "--native-volume requires an explicit absolute --native-volume-root"
      )
    else
      Util.ensure!(
        !Keyword.has_key?(options, :native_volume_root),
        "native volume root requires --native-volume"
      )
    end
  end

  defp validate_images!(options) do
    Util.ensure!(
      !options[:native_images] or options[:native_public] == true,
      "--native-images requires explicit --native-public"
    )

    if options[:native_images] do
      Util.ensure!(
        !Enum.any?(
          ~w(native_growth native_volume native_terminal native_network native_workload)a,
          &options[&1]
        ),
        "native image and other campaigns must run separately"
      )

      file = options[:native_images_settings]

      Util.ensure!(
        is_binary(file) and Path.type(file) == :absolute,
        "--native-images requires explicit absolute --native-images-settings"
      )

      Util.private_file!(file, 65_536)
    else
      Util.ensure!(
        !Keyword.has_key?(options, :native_images_settings),
        "native image settings require --native-images"
      )
    end
  end

  defp verify_images(evidence, options) do
    if options[:native_images] do
      Util.ensure!(
        evidence["campaign"] == "ordinary-public-native-images" and
          evidence["store_mode"] == "ephemeral" and evidence["final_reserved_slots"] == 0 and
          evidence["retained_binary_bytes"] == 65_537 and
          evidence["stopped_runtime_replacement"] == true and
          evidence["immutable_creation_retained"] == true,
        "native consumer did not qualify public source lifecycle"
      )

      verify_image_source(evidence["source_kind"], evidence)
    end
  end

  defp verify_image_source("oci", evidence) do
    Util.ensure!(
      get_in(evidence, ["image_operations", "approved_pull_observed"]) == true and
        get_in(evidence, ["image_operations", "duplicate_pull_reused"]) == true and
        get_in(evidence, ["image_operations", "creation_source_unchanged"]) == true,
      "native consumer did not qualify approved OCI image operations"
    )

    Util.ensure!(
      !evidence["configured_startup"] or evidence["startup_counts"] == [1, 2],
      "native consumer did not qualify configured OCI startup"
    )
  end

  defp verify_image_source("registry", evidence) do
    Util.ensure!(
      evidence["cold_warm_registry"] == true and
        get_in(evidence, ["image_operations", "imported_pull_rejected"]) == true,
      "native consumer did not qualify cold/warm registry preparation"
    )
  end

  defp verify_image_source(_, _),
    do: raise(ArgumentError, "native source consumer reported an unsupported source")

  defp validate_growth!(options) do
    Util.ensure!(
      !options[:native_growth] or options[:native_public] == true,
      "--native-growth requires explicit --native-public"
    )

    Util.ensure!(
      !options[:native_growth] or
        !(options[:native_volume] || options[:native_terminal] ||
            options[:native_network] || options[:native_workload]),
      "native growth, volume, terminal, workload and network campaigns must run separately"
    )

    if Keyword.has_key?(options, :native_growth_settings) do
      Util.ensure!(
        options[:native_growth] == true,
        "native growth settings require --native-growth"
      )

      file = options[:native_growth_settings]

      Util.ensure!(
        is_binary(file) and Path.type(file) == :absolute,
        "native growth settings require an explicit absolute path"
      )

      Util.private_file!(file, 65_536)
    end
  end

  defp copy_settings(tooling, options, hashes) do
    Enum.reduce(
      [
        {:native_images_settings, "images-settings.json"},
        {:native_growth_settings, "growth-settings.json"}
      ],
      {options, hashes},
      fn {key, name}, {options, hashes} ->
        if file = options[key] do
          path = Path.join(tooling, name)
          File.write!(path, Util.private_file!(file, 65_536), [:exclusive])
          File.chmod!(path, 0o600)
          {Keyword.put(options, key, path), Map.put(hashes, name, Util.digest(path))}
        else
          {options, hashes}
        end
      end
    )
  end

  defp verify_growth(evidence, options) do
    if options[:native_growth] do
      expected = %{
        "campaign" => "ordinary-public-native-growth",
        "phase" => "single",
        "store_mode" => "ephemeral",
        "growth_history_retained" => true,
        "immutable_creation_retained" => true,
        "growth_budget_rejected_before_dispatch" => true,
        "running_growth_rejected" => true,
        "drain_retained" => true,
        "duplicate_growth_retained" => true,
        "conflicting_growth_rejected" => true,
        "storage_filesystem_growth" => true,
        "overlay_geometry_verified" => true,
        "omitted_target_retained" => true,
        "material_chain_retained" => true,
        "stopped_runtime_replacement" => true,
        "final_reserved_slots" => 0,
        "final_reserved_disk_gb" => 0
      }

      Util.ensure!(
        Enum.all?(expected, fn {key, value} -> evidence[key] == value end),
        "native consumer did not qualify the requested public stopped-growth workflow"
      )
    end
  end

  defp verify_volume(evidence, options) do
    if options[:native_volume] do
      expected = %{
        "campaign" => "ordinary-public-native-volumes",
        "phase" => "single",
        "store_mode" => "ephemeral",
        "competing_attachment_rejected" => true,
        "volume_budget_rejected_before_dispatch" => true,
        "readonly_reattachment" => true,
        "stopped_runtime_replacement" => true,
        "proof_retained" => true,
        "running_sibling_preserved" => true,
        "final_reserved_slots" => 0,
        "final_reserved_disk_gb" => 0
      }

      Util.ensure!(
        Enum.all?(expected, fn {key, value} -> evidence[key] == value end),
        "native consumer did not qualify the requested public mounted-volume workflow"
      )
    end
  end

  defp validate_terminal!(options),
    do:
      Util.ensure!(
        !options[:native_terminal] or options[:native_public] == true,
        "--native-terminal requires explicit --native-public"
      )

  defp mode_arguments(options) do
    ordinary =
      if Enum.any?(
           ~w(native_ordinary native_growth native_branches native_checkpoints)a,
           &options[&1]
         ),
         do: ["--ordinary"],
         else: []

    ordinary =
      ordinary ++
        if(options[:native_checkpoints],
          do: [
            "--checkpoints",
            "--checkpoint-seed",
            Path.expand(options[:native_checkpoint_seed]),
            "--checkpoint-seed-sha256",
            options[:native_checkpoint_seed_sha256]
          ],
          else: []
        )

    terminal = if options[:native_terminal], do: ["--terminal"], else: []

    network =
      if options[:native_network] do
        [
          "--host-port",
          Integer.to_string(options[:native_host_port]),
          "--namespace-identity",
          options[:namespace_identity],
          "--manifest-sha256",
          Util.digest(Path.join(options[:native_package], "package.json"))
        ]
      else
        []
      end

    workload =
      if options[:native_workload] do
        [
          "--startup-workloads",
          "--namespace-identity",
          options[:namespace_identity],
          "--manifest-sha256",
          Util.digest(Path.join(options[:native_package], "package.json"))
        ]
      else
        []
      end

    volume =
      if options[:native_volume], do: ["--volume-root", options[:native_volume_root]], else: []

    images =
      if options[:native_images],
        do: ["--ordinary", "--settings", options[:native_images_settings]],
        else: []

    growth =
      if file = options[:native_growth_settings], do: ["--settings", file], else: []

    ordinary ++ terminal ++ network ++ workload ++ volume ++ images ++ growth
  end

  defp validate_network!(options) do
    Util.ensure!(
      !options[:native_network] or options[:native_public] == true,
      "--native-network requires explicit --native-public"
    )

    Util.ensure!(
      !(options[:native_network] && options[:native_terminal]),
      "native network and terminal campaigns must run separately"
    )

    if options[:native_network] do
      Util.ensure!(
        is_integer(options[:native_host_port]) and options[:native_host_port] in 1024..65_535,
        "--native-network requires an explicit --native-host-port from 1024 to 65535"
      )

      Util.ensure!(
        is_binary(options[:namespace_identity]) and
          Regex.match?(~r/\Anet:\[[0-9]+\]\z/, options[:namespace_identity]),
        "--native-network requires the verified namespace identity from network_fixture.py"
      )
    else
      Util.ensure!(
        !Keyword.has_key?(options, :native_host_port) and
          (options[:native_workload] == true or !Keyword.has_key?(options, :namespace_identity)),
        "native network fixture options require --native-network"
      )
    end
  end

  defp validate_workload!(options) do
    Util.ensure!(
      !options[:native_workload] or options[:native_public] == true,
      "--native-workload requires explicit --native-public"
    )

    Util.ensure!(
      !(options[:native_workload] && (options[:native_terminal] || options[:native_network])),
      "native workload, network and terminal campaigns must run separately"
    )

    if options[:native_workload] do
      Util.ensure!(
        is_binary(options[:namespace_identity]) and
          Regex.match?(~r/\Anet:\[[0-9]+\]\z/, options[:namespace_identity]),
        "--native-workload requires the verified namespace identity from network_fixture.py"
      )
    end
  end

  defp verify_workload(evidence, options) do
    if options[:native_workload] do
      cases = evidence["cases"] || []

      Util.ensure!(
        evidence["campaign"] == "ordinary-public-native-workloads" and
          evidence["workload_startup_qualified"] == true and
          Enum.map(cases, & &1["kind"]) == ["neutral", "inherited", "override", "missing"] and
          Enum.all?(
            cases,
            &(&1["owned_deleted"] == true and
                &1["changed_workload_rejected_before_dispatch"] == true and
                &1["retained_across_stopped_runtime_replacement"] == true)
          ),
        "native consumer did not qualify ordinary public startup workload behavior"
      )
    end
  end

  defp verify_network(evidence, options) do
    if options[:native_network] do
      cases = evidence["cases"] || []

      Util.ensure!(
        evidence["campaign"] == "ordinary-public-native-network-mappings" and
          evidence["public_memory_port_reservations_qualified"] == true and match?([_, _], cases) and
          Enum.all?(
            cases,
            &(&1["owned_deleted"] == true and
                &1["conflict_rolls_back_before_dispatch"] == true and
                &1["reservation_survives_stop_and_runtime_replacement"] == true)
          ),
        "native consumer did not qualify ordinary public network/port reservation behavior"
      )
    end
  end

  defp verify_terminal(evidence, options) do
    if options[:native_terminal] do
      Util.ensure!(
        get_in(evidence, ["terminal", "exercised"]) == true and
          get_in(evidence, ["terminal", "observed_exit"]) == 7 and
          get_in(evidence, ["terminal", "slot_released"]) == true,
        "native consumer did not qualify the requested ordinary terminal"
      )
    end
  end

  defp preserve_retained(%{retained: true} = result, log_path) do
    path = log_path <> ".retained.json"
    File.write!(path, JSON.encode!(Map.put(result, :deletion_authority, false)), [:exclusive])
    File.chmod!(path, 0o600)
  end

  defp preserve_retained(_result, _log_path), do: :ok

  defp proof_files(consumer, tooling, options) do
    script = proof_script(options)

    files = [
      {"scripts/#{script}", Path.join(consumer, "native-proof.exs")},
      {"native/smolbox-port/tests/native_proof.py", Path.join(tooling, "native_proof.py")}
    ]

    support = "embedded-runtime-proof-support.exs"

    files =
      if script in ~w(embedded-runtime-proof.exs embedded-growth-runtime-proof.exs embedded-images-runtime-proof.exs embedded-volume-runtime-proof.exs),
        do: [{"scripts/#{support}", Path.join(consumer, support)} | files],
        else: files

    proof_support(files, tooling, options)
  end

  defp proof_script(options) do
    cond do
      options[:native_branches] || options[:native_checkpoints] ->
        "embedded-branches-runtime-proof.exs"

      options[:native_images] ->
        "embedded-images-runtime-proof.exs"

      options[:native_growth] ->
        "embedded-growth-runtime-proof.exs"

      options[:native_volume] ->
        "embedded-volume-runtime-proof.exs"

      options[:native_network] || options[:native_workload] ->
        "embedded-network-proof.exs"

      options[:native_public] ->
        "embedded-runtime-proof.exs"

      true ->
        "embedded-port-proof.exs"
    end
  end

  defp proof_support(files, tooling, options) do
    cond do
      options[:native_branches] || options[:native_checkpoints] ->
        files ++
          Enum.map(~w(branch_demo.ex branch_control.ex), fn name ->
            {"examples/embedded_port/lib/#{name}", Path.join(tooling, name)}
          end) ++
          [
            {"examples/embedded_port/config.example.exs",
             Path.join(tooling, "config.example.exs")}
          ]

      options[:native_images] ->
        files ++
          Enum.map(~w(images_demo.ex images_control.ex owned_control.ex), fn name ->
            {"examples/embedded_port/lib/#{name}", Path.join(tooling, name)}
          end) ++
          [
            {"examples/embedded_port/config.example.exs",
             Path.join(tooling, "config.example.exs")}
          ]

      options[:native_growth] ->
        files ++
          Enum.map(~w(growth_demo.ex growth_control.ex owned_control.ex), fn name ->
            {"examples/embedded_port/lib/#{name}", Path.join(tooling, name)}
          end) ++
          [
            {"examples/embedded_port/config.example.exs",
             Path.join(tooling, "config.example.exs")}
          ]

      options[:native_volume] ->
        files ++
          Enum.map(~w(volume_demo.ex volume_control.ex), fn name ->
            {"examples/embedded_port/lib/#{name}", Path.join(tooling, name)}
          end) ++
          [
            {"examples/embedded_port/config.example.exs",
             Path.join(tooling, "config.example.exs")}
          ]

      options[:native_network] || options[:native_workload] ->
        files ++
          Enum.map(~w(ordinary_proof network_fixture network_proof), fn name ->
            {"native/smolbox-port/tests/#{name}.py", Path.join(tooling, "#{name}.py")}
          end)

      options[:native_public] ->
        files ++
          [
            {"examples/embedded_port/lib/demo.ex", Path.join(tooling, "demo.ex")},
            {"examples/embedded_port/config.example.exs",
             Path.join(tooling, "config.example.exs")}
          ]

      true ->
        files
    end
  end

  defp scope(options) do
    cond do
      options[:native_public] -> "public-port-package-consumer"
      options[:native_ordinary] -> "internal-port-ordinary-package-consumer"
      true -> "internal-port-package-consumer"
    end
  end
end
