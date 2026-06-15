defmodule Sftpd.SSH.SendRoutingTest do
  use ExUnit.Case, async: true

  alias Sftpd.SSH.Server

  test "encrypted send mode uses the small path only for small iodata" do
    assert :small = Server.__test_encrypted_send_mode__(<<0::size(8 * 4096)>>)
    assert :large = Server.__test_encrypted_send_mode__(<<0::size(8 * 4096 + 8)>>)
    assert :small = Server.__test_encrypted_send_mode__(["abc", "def"])
  end
end
