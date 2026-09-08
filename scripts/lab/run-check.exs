# Preserve bounded private diagnostics as well as the machine-readable summary.
assert_linux = fn ->
  {:unix, :linux} = :os.type()
  {"smolbox-nested\n", 0} = System.cmd("hostname", [])
end

assert_linux.()
Code.require_file("../../dev/smolbox/ci/child.ex", __DIR__)
Code.require_file("../../dev/smolbox/ci/util.ex", __DIR__)
Code.require_file("../../dev/smolbox/ci/bounded.ex", __DIR__)
[label, expected | command] = System.argv()
true = Regex.match?(~r/\A[a-z0-9_-]{1,60}\z/, label)
path = "/home/lab/qualification/#{label}"
false = File.exists?(path <> ".json")
{output, report} = SmolBox.CI.Child.execute(command, timeout: 1_200_000, output_limit: 262_144)
File.write!(path <> ".log", output)
File.chmod!(path <> ".log", 0o600)

report =
  if report.status == "passed" and expected != "0" do
    Map.put(report, :tests, SmolBox.CI.Bounded.summary!(output, String.to_integer(expected)))
  else
    report
  end

File.write!(path <> ".json", JSON.encode!(report))
IO.puts(JSON.encode!(report))
if report.status != "passed", do: System.halt(1)
