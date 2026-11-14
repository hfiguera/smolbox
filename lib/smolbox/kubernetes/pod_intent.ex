defmodule SmolBox.Kubernetes.PodIntent do
  @moduledoc false

  # This is the immutable version-1 creation schema. Future template changes
  # need a new assignment version, preserving validation of historical intents.

  @keeper "import os,time; os.makedirs('/workspace',exist_ok=True); time.sleep(2592000)"

  def manifest(binding, source, profile, name, nonce, fingerprint) do
    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{
        "name" => name,
        "namespace" => binding.namespace,
        "labels" => %{"app.kubernetes.io/managed-by" => "smolbox-kubernetes-preview"},
        "annotations" => %{
          "smolbox.io/creation-nonce" => nonce,
          "smolbox.io/execution" => fingerprint,
          "smolbox.io/domain" => binding.generation
        }
      },
      "spec" => %{
        "runtimeClassName" => binding.runtime_class,
        "restartPolicy" => "Never",
        "automountServiceAccountToken" => false,
        "enableServiceLinks" => false,
        "terminationGracePeriodSeconds" => 10,
        "nodeSelector" => %{
          "kubernetes.io/hostname" => binding.node_name,
          "kubernetes.io/arch" => "amd64"
        },
        "containers" => [
          %{
            "name" => "workload",
            "image" => source["reference"],
            "imagePullPolicy" => "IfNotPresent",
            "command" => ["python3", "-I", "-S", "-c", @keeper],
            "securityContext" => %{
              "allowPrivilegeEscalation" => false,
              "capabilities" => %{"drop" => ["ALL"]},
              "seccompProfile" => %{"type" => "RuntimeDefault"}
            },
            "resources" => %{
              "requests" => resources(profile),
              "limits" => resources(profile)
            }
          }
        ]
      }
    }
  end

  defp resources(profile),
    do: %{"cpu" => Integer.to_string(profile.cpus), "memory" => "#{profile.memory_mb}Mi"}
end
