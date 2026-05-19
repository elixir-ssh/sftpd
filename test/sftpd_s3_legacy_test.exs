defmodule SftpdS3LegacyTest do
  use ExUnit.Case, async: false

  describe "start_server/1" do
    test "raises KeyError when system_dir is missing" do
      port = 14_000 + :rand.uniform(1000)

      assert_raise KeyError, fn ->
        SftpdS3.start_server(port)
      end
    end
  end

  describe "start_server/2 and stop_server/1" do
    test "starts and stops with explicit port and options" do
      port = 14_000 + :rand.uniform(1000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               SftpdS3.start_server(port,
                 system_dir: system_dir,
                 bucket: "test-bucket"
               )

      assert :ok = SftpdS3.stop_server(ref)
    end

    test "accepts username and password options" do
      port = 14_000 + :rand.uniform(1000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               SftpdS3.start_server(port,
                 system_dir: system_dir,
                 bucket: "test-bucket",
                 username: "myuser",
                 password: "mypass"
               )

      assert :ok = SftpdS3.stop_server(ref)
    end

    test "accepts optional S3 backend passthrough options" do
      port = 14_000 + :rand.uniform(1000)
      system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

      assert {:ok, ref} =
               SftpdS3.start_server(port,
                 system_dir: system_dir,
                 bucket: "test-bucket",
                 prefix: "tenant-a/",
                 aws_client: ExAws
               )

      assert :ok = SftpdS3.stop_server(ref)
    end
  end
end
