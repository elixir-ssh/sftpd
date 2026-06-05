defmodule Sftpd.IODevice.StoreTest do
  use ExUnit.Case, async: true

  alias Sftpd.IODevice.Store

  test "stores state by opaque IODevice handle" do
    handle = {:sftpd_io, make_ref()}
    other = {:sftpd_io, make_ref()}

    assert Store.get(handle) == nil

    Store.put(handle, %{position: 12})

    assert Store.get(handle) == %{position: 12}
    assert Store.get(other) == nil
    assert Store.delete(handle) == %{position: 12}
    assert Store.get(handle) == nil
  end
end
