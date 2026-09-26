defmodule SmolBox.RegistryCredentialsTest do
  use ExUnit.Case, async: true
  alias SmolBox.RegistryCredentials
  alias SmolBox.Store.SourceContract

  defmodule Resolver do
    @behaviour RegistryCredentials
    @impl true
    def fetch(:raise, _reference), do: raise("private-secret")
    def fetch(:exit, _reference), do: exit("private-secret")
    def fetch(:throw, _reference), do: throw("private-secret")
    def fetch(context, "registry-reader"), do: context
  end

  test "resolver failures and malformed credentials are redacted" do
    for context <- [
          :raise,
          :exit,
          :throw,
          {:error, "private-secret"},
          {:ok, "bad\nsecret"},
          {:ok, nil},
          :unexpected
        ] do
      assert {:error, %{category: :authentication, evidence: :not_dispatched} = error} =
               RegistryCredentials.resolve({Resolver, context}, SourceContract.source())

      refute inspect(error) =~ "private-secret"
      refute Exception.message(error) =~ "private-secret"
    end
  end

  test "rotation resolves fresh values without changing durable source identity" do
    source = SourceContract.source()

    assert {:ok, [identity_token: "first"]} =
             RegistryCredentials.resolve({Resolver, {:ok, "first"}}, source)

    assert {:ok, [identity_token: "rotated"]} =
             RegistryCredentials.resolve({Resolver, {:ok, "rotated"}}, source)

    assert {:error, %{category: :authentication}} = RegistryCredentials.resolve(nil, source)
    assert {:ok, []} = RegistryCredentials.resolve(nil, %{source | credential_ref: nil})
    assert RegistryCredentials.valid?({Resolver, :private_context})
    refute RegistryCredentials.valid?({String, :context})
    refute RegistryCredentials.valid?(:invalid)
  end
end
