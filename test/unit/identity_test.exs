defmodule SmolBox.IdentityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SmolBox.{Identity, MachineSpec}

  property "opaque names stay within the upstream limit without embedding request text" do
    check all(suffix <- string(?a..?z, max_length: 9)) do
      namespace = "s" <> suffix
      assert {:ok, name} = Identity.machine_name(namespace)
      assert Identity.candidate?(namespace, name)
      assert MachineSpec.valid_name?(name)
      refute Identity.candidate?("other", name)
      assert {:ok, different} = Identity.machine_name(namespace)
      refute different == name
    end
  end

  test "invalid namespaces and partial matches cannot select cleanup candidates" do
    for namespace <- [nil, "", "User", "a-b", "0123", "morethan10chars", <<255>>] do
      assert {:error, _} = Identity.machine_name(namespace)
      refute Identity.candidate?(namespace, "anything")
    end

    for name <- [nil, "sbx-foreign", "sbx-" <> String.duplicate("!", 20)] do
      refute Identity.candidate?("sbx", name)
    end
  end
end
