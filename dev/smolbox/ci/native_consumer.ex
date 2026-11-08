defmodule SmolBox.CI.NativeConsumer do
  @moduledoc false
  alias SmolBox.CI.{Child, Util}

  @root Path.expand("../../..", __DIR__)
  @native_options ~w(native_package native_fixture native_sha256 native_domain_json native_output)a

  def validate_options!(options) do
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

    files = proof_files(consumer, tooling, options[:native_public])

    hashes =
      Map.new(files, fn {source, destination} ->
        source = Path.join(@root, source)
        File.cp!(source, destination)
        {Path.basename(destination), Util.digest(destination)}
      end)

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
    arguments = if options[:native_ordinary], do: arguments ++ ["--ordinary"], else: arguments
    File.mkdir_p!(Path.dirname(log_path))

    {log, result} =
      Child.execute(arguments,
        cd: consumer,
        env: environment,
        timeout: 600_000,
        termination: :retain
      )

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

    %{
      scope: scope(options),
      exercised: true,
      proof_tool_sha256: hashes,
      evidence: evidence
    }
  end

  defp preserve_retained(%{retained: true} = result, log_path) do
    path = log_path <> ".retained.json"
    File.write!(path, JSON.encode!(Map.put(result, :deletion_authority, false)), [:exclusive])
    File.chmod!(path, 0o600)
  end

  defp preserve_retained(_result, _log_path), do: :ok

  defp proof_files(consumer, tooling, public) do
    script = if public, do: "embedded-runtime-proof.exs", else: "embedded-port-proof.exs"

    files = [
      {"scripts/#{script}", Path.join(consumer, "native-proof.exs")},
      {"native/smolbox-port/tests/native_proof.py", Path.join(tooling, "native_proof.py")}
    ]

    if public do
      files ++
        [
          {"examples/embedded_port/lib/demo.ex", Path.join(tooling, "demo.ex")},
          {"examples/embedded_port/config.example.exs", Path.join(tooling, "config.example.exs")}
        ]
    else
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
