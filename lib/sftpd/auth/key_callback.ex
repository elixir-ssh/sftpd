defmodule Sftpd.Auth.KeyCallback do
  @moduledoc false

  alias Sftpd.Auth.{Adapter, Registry}

  @behaviour :ssh_server_key_api

  @impl true
  def host_key(algorithm, opts) do
    :ssh_file.host_key(algorithm, opts)
  end

  @impl true
  def is_auth_key(public_key, username, opts) do
    auth_config = opts |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:auth)

    case Adapter.authorize_public_key(auth_config, username, public_key) do
      {:ok, session} when is_map(session) ->
        Registry.put(self(), session)
        true

      _error ->
        false
    end
  end
end
