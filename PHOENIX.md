# Phoenix Setup

This guide shows the intended Phoenix integration path: supervise `Sftpd`,
authenticate through your app, and use the auth session map to scope backend
storage.

## Supervision

Add `Sftpd` to your application supervisor:

```elixir
children = [
  {Sftpd,
   port: Application.fetch_env!(:my_app, :sftp_port),
   system_dir: Application.fetch_env!(:my_app, :sftp_system_dir),
   auth: {MyApp.SftpAuth, []},
   backend: Sftpd.Backends.S3,
   backend_opts: [
     bucket: Application.fetch_env!(:my_app, :sftp_bucket),
     prefix: {:session, :sftp_prefix}
   ]}
]
```

`Sftpd.child_spec/1` owns the SSH daemon lifecycle and stops it when your
supervisor stops.

## Runtime Config

Use runtime config for deploy-specific values:

```elixir
# config/runtime.exs
config :my_app,
  sftp_port: String.to_integer(System.get_env("SFTP_PORT", "2222")),
  sftp_system_dir: System.fetch_env!("SFTP_SYSTEM_DIR"),
  sftp_bucket: System.fetch_env!("SFTP_BUCKET")
```

`system_dir` must point at persistent SSH host keys. Do not generate new host
keys on every deploy unless clients are prepared for host-key rotation.

## Local Static Auth

For local development without app auth:

```elixir
{Sftpd,
 port: 2222,
 system_dir: "priv/sftp_host_keys",
 auth: {:passwords, [{"dev", "dev"}]},
 backend: Sftpd.Backends.Memory,
 backend_opts: []}
```

## Password Auth

Implement `Sftpd.Auth` in your app. The returned session map is opaque to
`Sftpd` except where built-in backends document specific keys.

```elixir
defmodule MyApp.SftpAuth do
  @behaviour Sftpd.Auth

  alias MyApp.Accounts

  @impl true
  def authenticate_password(username, password, _peer, _opts) do
    with {:ok, user} <- Accounts.authenticate_sftp_user(username, password) do
      {:ok,
       %{
         user_id: user.id,
         tenant_id: user.tenant_id,
         sftp_prefix: "tenants/#{user.tenant_id}/"
       }}
    else
      _ -> :error
    end
  end

  @impl true
  def authorize_public_key(username, public_key, _opts) do
    fingerprint = Sftpd.Auth.fingerprint(public_key)

    with {:ok, user} <- Accounts.get_sftp_user_by_key(username, fingerprint) do
      {:ok,
       %{
         user_id: user.id,
         tenant_id: user.tenant_id,
         sftp_prefix: "tenants/#{user.tenant_id}/"
       }}
    else
      _ -> :error
    end
  end
end
```

## Public Keys

Store public-key fingerprints in your database:

```elixir
{:ok, public_key} = Sftpd.Auth.decode_authorized_key(authorized_key_line)
fingerprint = Sftpd.Auth.fingerprint(public_key)
```

The fingerprint is suitable for lookup during `authorize_public_key/3`.

## Tenant-Scoped S3

Use `prefix: {:session, :sftp_prefix}` to scope every S3 object key by the
authenticated session:

```elixir
backend_opts: [
  bucket: "uploads",
  prefix: {:session, :sftp_prefix}
]
```

If auth returns `%{sftp_prefix: "tenants/123/"}`, an upload to `/invoice.pdf`
is stored as `tenants/123/invoice.pdf`.

## Deployment Notes

Expose the configured TCP port through your load balancer or host firewall.
Persist the SSH host key directory across deploys. Keep application passwords,
public-key fingerprints, S3 bucket names, and endpoint credentials in your
normal runtime secret/config path.
