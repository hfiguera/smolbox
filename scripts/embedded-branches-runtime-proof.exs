defmodule SmolBox.EmbeddedBranchesRuntimeProof do
  @moduledoc false
  alias SmolBox.Example.EmbeddedBranches

  def run(arguments) do
    {options, [], []} =
      OptionParser.parse(arguments,
        strict: [
          package: :string,
          fixture: :string,
          sha256: :string,
          domain_json: :string,
          inventory_helper: :string,
          output: :string,
          without_rust: :boolean,
          ordinary: :boolean,
          checkpoints: :boolean,
          checkpoint_seed: :string,
          checkpoint_seed_sha256: :string
        ]
      )

    true = options[:without_rust] and options[:ordinary]
    nil = System.find_executable("rustc")
    nil = System.find_executable("cargo")
    package = Path.expand(Keyword.fetch!(options, :package))
    manifest = File.read!(Path.join(package, "package.json"))
    digest = Base.encode16(:crypto.hash(:sha256, manifest), case: :lower)

    for {name, value} <- [
          {"SMOLBOX_EMBEDDED_PACKAGE", package},
          {"SMOLBOX_EMBEDDED_MANIFEST_SHA256", digest},
          {"SMOLBOX_EMBEDDED_DOMAIN_JSON", Keyword.fetch!(options, :domain_json)},
          {"SMOLBOX_EMBEDDED_ARTIFACT", Keyword.fetch!(options, :fixture)},
          {"SMOLBOX_EMBEDDED_ARTIFACT_SHA256", Keyword.fetch!(options, :sha256)},
          {"SMOLBOX_EMBEDDED_INITIALIZE", "false"}
        ],
        do: System.put_env(name, value)

    tooling = Keyword.fetch!(options, :inventory_helper)

    {:ok, _modules, %{compile_warnings: [], runtime_warnings: []}} =
      ~w(branch_control.ex branch_demo.ex)
      |> Enum.map(&Path.join(tooling, &1))
      |> Kernel.ParallelCompiler.compile(return_diagnostics: true)

    {target, _binding} = Code.eval_file(Path.join(tooling, "config.example.exs"))

    output = Path.expand(Keyword.fetch!(options, :output))
    campaign = if options[:checkpoints], do: :checkpoints, else: :branches

    configuration =
      if options[:checkpoints] do
        root = output <> "-captures"
        :ok = File.mkdir(root)
        :ok = File.chmod(root, 0o700)

        [
          capture_root: root,
          checkpoint_seed: %{
            path: Keyword.fetch!(options, :checkpoint_seed),
            sha256: Keyword.fetch!(options, :checkpoint_seed_sha256)
          }
        ]
      else
        []
      end

    target = EmbeddedBranches.configure(target, configuration)
    before = inventory(tooling)
    {:ok, evidence} = EmbeddedBranches.run(target, output, campaign: campaign)
    after_run = inventory(tooling)
    true = before == after_run

    evidence =
      evidence
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.merge(%{
        "scope" => "public-port-package-consumer",
        "campaign" => evidence.campaign,
        "public_native_admission_enabled" => true,
        "without_rust" => true,
        "inventory_before" => before,
        "inventory_after" => after_run
      })

    path = Path.join(output, "evidence.json")
    File.write!(path <> ".new", Jason.encode!(evidence), [:exclusive])
    File.chmod!(path <> ".new", 0o600)
    File.rename!(path <> ".new", path)
    IO.puts(Jason.encode!(evidence))
  end

  defp inventory(tooling) do
    {body, 0} =
      System.cmd(System.find_executable("python3"), [
        "-c",
        "import sys,json; sys.path.insert(0,sys.argv[1]); from native_proof import snapshot; print(json.dumps(snapshot()))",
        tooling
      ])

    Jason.decode!(body)
  end
end

SmolBox.EmbeddedBranchesRuntimeProof.run(System.argv())
