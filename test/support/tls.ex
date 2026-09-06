defmodule SmolBox.TestTLS do
  @moduledoc false

  def create(dir) do
    config = Path.join(dir, "openssl.cnf")

    File.write!(config, """
    [req]
    distinguished_name=dn
    x509_extensions=root
    prompt=no
    [dn]
    CN=SmolBox disposable test CA
    [root]
    basicConstraints=critical,CA:TRUE
    keyUsage=critical,keyCertSign,cRLSign
    [leaf]
    subjectAltName=DNS:localhost
    basicConstraints=critical,CA:FALSE
    keyUsage=critical,digitalSignature,keyEncipherment
    extendedKeyUsage=serverAuth
    """)

    ca = Path.join(dir, "ca.pem")
    ca_key = Path.join(dir, "ca-key.pem")
    cert = Path.join(dir, "cert.pem")
    key = Path.join(dir, "key.pem")
    csr = Path.join(dir, "request.pem")

    openssl([
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-days",
      "1",
      "-config",
      config,
      "-keyout",
      ca_key,
      "-out",
      ca
    ])

    openssl([
      "req",
      "-new",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-subj",
      "/CN=localhost",
      "-keyout",
      key,
      "-out",
      csr
    ])

    openssl([
      "x509",
      "-req",
      "-in",
      csr,
      "-CA",
      ca,
      "-CAkey",
      ca_key,
      "-set_serial",
      "1",
      "-days",
      "1",
      "-extfile",
      config,
      "-extensions",
      "leaf",
      "-out",
      cert
    ])

    %{cert: cert, key: key, ca: ca}
  end

  defp openssl(args) do
    {_output, 0} = System.cmd("openssl", args, stderr_to_stdout: true)
    :ok
  end
end
