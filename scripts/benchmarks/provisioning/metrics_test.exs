Code.require_file("metrics.exs", __DIR__)
ExUnit.start()

defmodule SmolBox.ProvisioningMetricsTest do
  use ExUnit.Case, async: true
  alias SmolBox.ProvisioningMetrics

  test "vanishing files retain the sampled total and count incomplete observations" do
    assert ProvisioningMetrics.parse_disk("4096\t/private/worker\n", 0, "/private/worker") ==
             {4096, 0}

    output =
      "du: cannot access '/private/worker/transient': No such file or directory\n8192\t/private/worker\n"

    assert ProvisioningMetrics.parse_disk(output, 1, "/private/worker") == {8192, 1}
  end

  test "permission errors and missing totals cannot turn into plausible disk measurements" do
    assert_raise MatchError, fn ->
      ProvisioningMetrics.parse_disk(
        "du: cannot read directory '/private/worker': Permission denied\n4096\t/private/worker\n",
        1,
        "/private/worker"
      )
    end

    assert_raise MatchError, fn ->
      ProvisioningMetrics.parse_disk("", 1, "/private/worker")
    end
  end
end
