defmodule SmolBox.GuestFilesRuntimeTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Client, Command, Files, GuestPaths, Identity, Machine, MachineSpec, Worker}
  @moduletag :runtime
  @moduletag timeout: 240_000

  test "16 MiB transfers preserve bytes; worker read caps and lexical symlink limits remain explicit" do
    {:ok, endpoint} =
      Worker.new(
        "files-live",
        System.fetch_env!("SMOLBOX_RUNTIME_URL"),
        SmolBox.LabCandidate.endpoint_options(
          allow_insecure_loopback: true,
          max_request_bytes: 16_777_216,
          operation_timeout_ms: 90_000,
          receive_timeout_ms: 60_000
        )
      )

    {:ok, paths} =
      GuestPaths.new(upload_roots: ["/app"], download_roots: ["/app"], workdir_roots: ["/app"])

    {:ok, client} = Client.new(endpoint, guest_paths: paths, max_file_bytes: 16_777_216)
    {:ok, name} = Identity.machine_name("filetest")

    {:ok, spec} =
      MachineSpec.new(name, System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT"),
        storage_gb: 2,
        overlay_gb: 2
      )

    {:ok, created} = Client.create(client, spec)

    try do
      bytes = :binary.copy(<<0, 255, 13, 10>>, 4_194_304)
      # Upload itself can boot a created/stopped machine; it is a mutation.
      assert :ok = Client.upload(client, name, "/app/café input.bin", bytes, Files.sha256(bytes))

      assert {:ok, ^bytes} =
               Client.download(client, name, "/app/café input.bin", byte_size(bytes))

      assert {:error, %{category: :output_limit}} =
               Client.download(client, name, "/app/café input.bin", 1024)

      assert {:error, %{category: :validation}} =
               Client.upload(
                 client,
                 name,
                 "/app/over.bin",
                 bytes <> "x",
                 Files.sha256(bytes <> "x")
               )

      {:ok, command} =
        Command.new(
          [
            "python",
            "-c",
            "import pathlib,os; assert os.getcwd() == '/app'; pathlib.Path('over.bin').write_bytes(b'x' * 16777217); pathlib.Path('/tmp/guest-only').write_text('guest-only'); pathlib.Path('link').symlink_to('/tmp/guest-only')"
          ],
          workdir: "/app",
          timeout_secs: 10
        )

      assert {:ok, %{exit_code: 0}} = Client.exec(client, name, command)
      # Requires the separately configured SMOLVM_FILE_TRANSFER_MAX_BYTES=16777216.
      assert {:error, %{category: :protocol}} =
               Client.download(client, name, "/app/over.bin", 16_777_216)

      assert {:error, _} = Client.download(client, name, "/tmp/guest-only", 100)
      assert {:ok, "guest-only"} = Client.download(client, name, "/app/link", 100)

      assert :ok =
               Client.upload(
                 client,
                 name,
                 "/app/link",
                 "replacement",
                 Files.sha256("replacement")
               )

      {:ok, verify} =
        Command.new(
          [
            "python",
            "-c",
            "import pathlib; assert pathlib.Path('/tmp/guest-only').read_text() == 'guest-only'; assert pathlib.Path('link').read_text() == 'replacement'; print('verified')"
          ],
          workdir: "/app"
        )

      assert {:ok, %{exit_code: 0, stdout: "verified\n"}} = Client.exec(client, name, verify)
    after
      {:ok, observed} = Client.inspect_machine(client, name)
      assert Machine.same_incarnation?(created, observed)
      assert :ok = Client.delete(client, name)
      assert {:error, %{category: :not_found}} = Client.inspect_machine(client, name)
    end
  end
end
