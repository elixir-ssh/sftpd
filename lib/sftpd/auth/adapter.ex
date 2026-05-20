defmodule Sftpd.Auth.Adapter do
  @moduledoc false

  alias Sftpd.Auth.Registry

  @type auth_config :: {:passwords, [{String.t(), String.t()}]} | {module(), term()}

  @spec valid_config?(term()) :: boolean()
  def valid_config?({:passwords, passwords}) when is_list(passwords) do
    Enum.all?(passwords, &password_entry?/1)
  end

  def valid_config?({module, _opts}) when is_atom(module) do
    exports?(module, :authenticate_password, 4)
  end

  def valid_config?(_auth), do: false

  @spec password_fun(auth_config()) :: function()
  def password_fun(auth_config) do
    fn username, password, peer, _state ->
      case authenticate_password(auth_config, username, password, peer) do
        {:ok, session} when is_map(session) ->
          Registry.put(self(), session)
          {true, session}

        :disconnect ->
          :disconnect

        _error ->
          false
      end
    end
  end

  @spec authenticate_password(auth_config(), term(), term(), term()) ::
          {:ok, map()} | :error | {:error, term()} | :disconnect
  def authenticate_password({:passwords, passwords}, username, password, _peer) do
    username = to_string(username)
    password = to_string(password)

    if Enum.any?(passwords, &password_matches?(&1, username, password)) do
      {:ok, %{username: username}}
    else
      :error
    end
  end

  def authenticate_password({module, opts}, username, password, peer) do
    module.authenticate_password(to_string(username), to_string(password), peer, opts)
  end

  @spec authorize_public_key(auth_config(), term(), term()) ::
          {:ok, map()} | :error | {:error, term()}
  def authorize_public_key({:passwords, _passwords}, _username, _public_key), do: :error

  def authorize_public_key({module, opts}, username, public_key) do
    if exports?(module, :authorize_public_key, 3) do
      module.authorize_public_key(to_string(username), public_key, opts)
    else
      :error
    end
  end

  defp password_entry?({_user, _pass}), do: true
  defp password_entry?(_entry), do: false

  defp password_matches?({user, pass}, username, password) do
    to_string(user) == username and to_string(pass) == password
  end

  defp password_matches?(_entry, _username, _password), do: false

  defp exports?(module, function, arity) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> function_exported?(module, function, arity)
      {:error, _reason} -> false
    end
  end
end
