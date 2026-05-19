defmodule Sftpd.DocTest do
  use ExUnit.Case, async: true

  doctest Sftpd.Backend
  doctest Sftpd.Backends.Memory
  doctest Sftpd.Backends.S3, only: [parse_http_date: 1]
end
