defmodule SftpdIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  @port 1337

  @client_opts [
    silently_accept_hosts: true,
    user: ~c"user",
    password: ~c"password"
  ]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:hackney)

    system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

    local_path =
      Path.join([
        File.cwd!(),
        "test/fixtures/1mb.txt"
      ])

    file = ExAws.S3.Upload.stream_file(local_path)
    bucket = Application.get_env(:sftpd, :bucket)

    ExAws.S3.put_bucket(bucket, "us-west-2") |> ExAws.request()

    ExAws.S3.upload(file, bucket, "foldertest/9/assets.csv") |> ExAws.request!()
    ExAws.S3.upload(file, bucket, "foldertest/10/assets.csv") |> ExAws.request!()
    ExAws.S3.upload(file, bucket, "foldertest/11/assets.csv") |> ExAws.request!()

    ExAws.S3.upload(file, bucket, "foldertest/11/assets2.csv")
    |> ExAws.request!()

    %{
      bucket: bucket,
      path: "foldertest/9/assets.csv",
      local_path: local_path,
      system_dir: system_dir
    }
  end

  describe "SFTP Server - Read Operations" do
    test "happy path for read", %{path: path, local_path: local_path, system_dir: system_dir} do
      assert {:ok, _ref} = start_ssh_server(system_dir)
      %{channel_ref: channel_ref} = start_ssh_client()

      assert {:ok, listing} = :ssh_sftp.list_dir(channel_ref, ~c"/")

      # Verify expected entries are present
      assert ~c"." in listing
      assert ~c".." in listing
      assert ~c"foldertest" in listing

      assert {:ok,
              {:file_info, _size, :directory, :read_write, time, time, time, _, _, _, _, _, _, _}} =
               :ssh_sftp.read_file_info(channel_ref, ~c"/foldertest")

      assert {:ok,
              {:file_info, size, :regular, :read_write, _time, _time2, _time3, _, _, _, _, _, _,
               _}} =
               :ssh_sftp.read_file_info(channel_ref, path |> to_charlist())

      assert {:ok, "0"} = :ssh_sftp.open(channel_ref, path |> to_charlist(), [:read])

      assert {:ok, data} = :ssh_sftp.read(channel_ref, "0", size)

      assert File.read!(local_path) == data |> Enum.into(<<>>, fn byte -> <<byte::8>> end)

      assert :ok = :ssh_sftp.close(channel_ref, "0")
    end

    test "list_dir returns . and .. entries", %{system_dir: system_dir} do
      assert {:ok, _ref} = start_ssh_server(system_dir)
      %{channel_ref: channel_ref} = start_ssh_client()

      {:ok, listing} = :ssh_sftp.list_dir(channel_ref, ~c"/")

      assert ~c"." in listing
      assert ~c".." in listing
    end

    test "list_dir in subdirectory returns . and .. entries", %{system_dir: system_dir} do
      assert {:ok, _ref} = start_ssh_server(system_dir)
      %{channel_ref: channel_ref} = start_ssh_client()

      {:ok, listing} = :ssh_sftp.list_dir(channel_ref, ~c"/foldertest")

      assert ~c"." in listing
      assert ~c".." in listing
    end

    test "read_file_info returns error for non-existent file", %{system_dir: system_dir} do
      assert {:ok, _ref} = start_ssh_server(system_dir)
      %{channel_ref: channel_ref} = start_ssh_client()

      assert {:error, :no_such_file} =
               :ssh_sftp.read_file_info(channel_ref, ~c"/nonexistent.txt")
    end
  end

  describe "SFTP Server - Directory Operations" do
    test "happy path for make and delete directory", %{system_dir: system_dir} do
      assert {:ok, _ref} = start_ssh_server(system_dir)
      %{channel_ref: channel_ref} = start_ssh_client()

      assert {:ok, listing} = :ssh_sftp.list_dir(channel_ref, ~c"/")

      assert ~c"." in listing
      assert ~c".." in listing
      assert ~c"foldertest" in listing

      assert {:ok, "0"} = :ssh_sftp.opendir(channel_ref, ~c"/foldertest")

      assert :ok = :ssh_sftp.make_dir(channel_ref, ~c"/foldertest/15")

      {:ok, foldertest_listing} = :ssh_sftp.list_dir(channel_ref, ~c"/foldertest")
      assert ~c"." in foldertest_listing
      assert ~c".." in foldertest_listing
      assert ~c"15" in foldertest_listing
      assert ~c"9" in foldertest_listing

      assert :ok = :ssh_sftp.del_dir(channel_ref, ~c"/foldertest/15")
    end

    test "create nested directories", %{system_dir: system_dir} do
      assert {:ok, _ref} = start_ssh_server(system_dir)
      %{channel_ref: channel_ref} = start_ssh_client()

      assert :ok = :ssh_sftp.make_dir(channel_ref, ~c"/nested_test")
      assert :ok = :ssh_sftp.make_dir(channel_ref, ~c"/nested_test/level1")
      assert :ok = :ssh_sftp.make_dir(channel_ref, ~c"/nested_test/level1/level2")

      {:ok, listing} = :ssh_sftp.list_dir(channel_ref, ~c"/nested_test/level1")
      assert ~c"level2" in listing

      # Cleanup
      :ssh_sftp.del_dir(channel_ref, ~c"/nested_test/level1/level2")
      :ssh_sftp.del_dir(channel_ref, ~c"/nested_test/level1")
      :ssh_sftp.del_dir(channel_ref, ~c"/nested_test")
    end
  end

  describe "SFTP Server - Write Operations" do
    test "happy path for upload without cd", %{system_dir: system_dir} do
      assert {:ok, _ref} = start_ssh_server(system_dir)
      %{channel_ref: channel_ref} = start_ssh_client()

      assert {:ok, listing} = :ssh_sftp.list_dir(channel_ref, ~c"/")

      assert ~c"." in listing
      assert ~c".." in listing
      assert ~c"foldertest" in listing

      # Create the directory first
      assert :ok = :ssh_sftp.make_dir(channel_ref, ~c"/foldertest/15")

      # Now open a file for writing
      assert {:ok, handle} = :ssh_sftp.open(channel_ref, ~c"/foldertest/15/assets.csv", [:write])

      # Write some data
      assert :ok = :ssh_sftp.write(channel_ref, handle, "hello world")

      # Close the file
      assert :ok = :ssh_sftp.close(channel_ref, handle)

      # Verify the file was created and can be read back
      assert {:ok, handle2} = :ssh_sftp.open(channel_ref, ~c"/foldertest/15/assets.csv", [:read])
      assert {:ok, ~c"hello world"} = :ssh_sftp.read(channel_ref, handle2, 11)
      assert :ok = :ssh_sftp.close(channel_ref, handle2)
    end

    test "upload and download preserves content", %{system_dir: system_dir} do
      assert {:ok, _ref} = start_ssh_server(system_dir)
      %{channel_ref: channel_ref} = start_ssh_client()

      test_content = "Test content with special chars: @#$%^&*()_+ and unicode: "

      # Create directory and upload file
      :ssh_sftp.make_dir(channel_ref, ~c"/upload_test")
      {:ok, write_handle} = :ssh_sftp.open(channel_ref, ~c"/upload_test/test.txt", [:write])
      :ok = :ssh_sftp.write(channel_ref, write_handle, test_content)
      :ok = :ssh_sftp.close(channel_ref, write_handle)

      # Download and verify
      {:ok, read_handle} = :ssh_sftp.open(channel_ref, ~c"/upload_test/test.txt", [:read])
      {:ok, downloaded} = :ssh_sftp.read(channel_ref, read_handle, 10000)
      :ok = :ssh_sftp.close(channel_ref, read_handle)

      assert to_string(downloaded) == test_content

      # Cleanup
      :ssh_sftp.delete(channel_ref, ~c"/upload_test/test.txt")
      :ssh_sftp.del_dir(channel_ref, ~c"/upload_test")
    end

    # NOTE: S3 multipart upload requires minimum 5MB per part, so we can't test
    # multiple small chunks. The single write test covers basic functionality.

    test "overwrite existing file", %{system_dir: system_dir} do
      assert {:ok, _ref} = start_ssh_server(system_dir)
      %{channel_ref: channel_ref} = start_ssh_client()

      :ssh_sftp.make_dir(channel_ref, ~c"/overwrite_test")

      # Create initial file
      {:ok, h1} = :ssh_sftp.open(channel_ref, ~c"/overwrite_test/file.txt", [:write])
      :ok = :ssh_sftp.write(channel_ref, h1, "original content")
      :ok = :ssh_sftp.close(channel_ref, h1)

      # Overwrite the file
      {:ok, h2} = :ssh_sftp.open(channel_ref, ~c"/overwrite_test/file.txt", [:write])
      :ok = :ssh_sftp.write(channel_ref, h2, "new content")
      :ok = :ssh_sftp.close(channel_ref, h2)

      # Verify new content
      {:ok, read_handle} = :ssh_sftp.open(channel_ref, ~c"/overwrite_test/file.txt", [:read])
      {:ok, content} = :ssh_sftp.read(channel_ref, read_handle, 100)
      :ok = :ssh_sftp.close(channel_ref, read_handle)

      assert to_string(content) == "new content"

      # Cleanup
      :ssh_sftp.delete(channel_ref, ~c"/overwrite_test/file.txt")
      :ssh_sftp.del_dir(channel_ref, ~c"/overwrite_test")
    end
  end

  describe "SFTP Server - Delete Operations" do
    test "delete file", %{system_dir: system_dir} do
      assert {:ok, _ref} = start_ssh_server(system_dir)
      %{channel_ref: channel_ref} = start_ssh_client()

      :ssh_sftp.make_dir(channel_ref, ~c"/delete_test")
      {:ok, handle} = :ssh_sftp.open(channel_ref, ~c"/delete_test/to_delete.txt", [:write])
      :ok = :ssh_sftp.write(channel_ref, handle, "content")
      :ok = :ssh_sftp.close(channel_ref, handle)

      # Verify file exists
      {:ok, listing} = :ssh_sftp.list_dir(channel_ref, ~c"/delete_test")
      assert ~c"to_delete.txt" in listing

      # Delete the file
      assert :ok = :ssh_sftp.delete(channel_ref, ~c"/delete_test/to_delete.txt")

      # Verify file is gone
      {:ok, listing2} = :ssh_sftp.list_dir(channel_ref, ~c"/delete_test")
      refute ~c"to_delete.txt" in listing2

      # Cleanup
      :ssh_sftp.del_dir(channel_ref, ~c"/delete_test")
    end
  end

  describe "SFTP Server - Rename Operations" do
    test "rename file", %{system_dir: system_dir} do
      assert {:ok, _ref} = start_ssh_server(system_dir)
      %{channel_ref: channel_ref} = start_ssh_client()

      :ssh_sftp.make_dir(channel_ref, ~c"/rename_test")
      {:ok, handle} = :ssh_sftp.open(channel_ref, ~c"/rename_test/original.txt", [:write])
      :ok = :ssh_sftp.write(channel_ref, handle, "rename test content")
      :ok = :ssh_sftp.close(channel_ref, handle)

      # Rename the file
      assert :ok =
               :ssh_sftp.rename(
                 channel_ref,
                 ~c"/rename_test/original.txt",
                 ~c"/rename_test/renamed.txt"
               )

      # Verify old name is gone
      {:ok, listing} = :ssh_sftp.list_dir(channel_ref, ~c"/rename_test")
      refute ~c"original.txt" in listing
      assert ~c"renamed.txt" in listing

      # Verify content is preserved
      {:ok, read_handle} = :ssh_sftp.open(channel_ref, ~c"/rename_test/renamed.txt", [:read])
      {:ok, content} = :ssh_sftp.read(channel_ref, read_handle, 100)
      :ok = :ssh_sftp.close(channel_ref, read_handle)

      assert to_string(content) == "rename test content"

      # Cleanup
      :ssh_sftp.delete(channel_ref, ~c"/rename_test/renamed.txt")
      :ssh_sftp.del_dir(channel_ref, ~c"/rename_test")
    end
  end

  describe "SFTP Server - Edge Cases" do
    test "read more bytes than file contains", %{system_dir: system_dir} do
      assert {:ok, _ref} = start_ssh_server(system_dir)
      %{channel_ref: channel_ref} = start_ssh_client()

      :ssh_sftp.make_dir(channel_ref, ~c"/edge_test")
      {:ok, handle} = :ssh_sftp.open(channel_ref, ~c"/edge_test/small.txt", [:write])
      :ok = :ssh_sftp.write(channel_ref, handle, "tiny")
      :ok = :ssh_sftp.close(channel_ref, handle)

      # Try to read more than file size
      {:ok, read_handle} = :ssh_sftp.open(channel_ref, ~c"/edge_test/small.txt", [:read])
      {:ok, content} = :ssh_sftp.read(channel_ref, read_handle, 10000)
      :ok = :ssh_sftp.close(channel_ref, read_handle)

      # Should return only what's available
      assert to_string(content) == "tiny"

      # Cleanup
      :ssh_sftp.delete(channel_ref, ~c"/edge_test/small.txt")
      :ssh_sftp.del_dir(channel_ref, ~c"/edge_test")
    end

    test "file with spaces in name", %{system_dir: system_dir} do
      assert {:ok, _ref} = start_ssh_server(system_dir)
      %{channel_ref: channel_ref} = start_ssh_client()

      :ssh_sftp.make_dir(channel_ref, ~c"/space_test")
      {:ok, handle} = :ssh_sftp.open(channel_ref, ~c"/space_test/file with spaces.txt", [:write])
      :ok = :ssh_sftp.write(channel_ref, handle, "content")
      :ok = :ssh_sftp.close(channel_ref, handle)

      {:ok, listing} = :ssh_sftp.list_dir(channel_ref, ~c"/space_test")
      assert ~c"file with spaces.txt" in listing

      # Cleanup
      :ssh_sftp.delete(channel_ref, ~c"/space_test/file with spaces.txt")
      :ssh_sftp.del_dir(channel_ref, ~c"/space_test")
    end

    test "multiple file handles simultaneously", %{system_dir: system_dir} do
      assert {:ok, _ref} = start_ssh_server(system_dir)
      %{channel_ref: channel_ref} = start_ssh_client()

      :ssh_sftp.make_dir(channel_ref, ~c"/multi_handle")

      # Open multiple files for writing
      {:ok, h1} = :ssh_sftp.open(channel_ref, ~c"/multi_handle/file1.txt", [:write])
      {:ok, h2} = :ssh_sftp.open(channel_ref, ~c"/multi_handle/file2.txt", [:write])

      # Write to both
      :ok = :ssh_sftp.write(channel_ref, h1, "content1")
      :ok = :ssh_sftp.write(channel_ref, h2, "content2")

      # Close both
      :ok = :ssh_sftp.close(channel_ref, h1)
      :ok = :ssh_sftp.close(channel_ref, h2)

      # Verify both files
      {:ok, r1} = :ssh_sftp.open(channel_ref, ~c"/multi_handle/file1.txt", [:read])
      {:ok, c1} = :ssh_sftp.read(channel_ref, r1, 100)
      :ok = :ssh_sftp.close(channel_ref, r1)

      {:ok, r2} = :ssh_sftp.open(channel_ref, ~c"/multi_handle/file2.txt", [:read])
      {:ok, c2} = :ssh_sftp.read(channel_ref, r2, 100)
      :ok = :ssh_sftp.close(channel_ref, r2)

      assert to_string(c1) == "content1"
      assert to_string(c2) == "content2"

      # Cleanup
      :ssh_sftp.delete(channel_ref, ~c"/multi_handle/file1.txt")
      :ssh_sftp.delete(channel_ref, ~c"/multi_handle/file2.txt")
      :ssh_sftp.del_dir(channel_ref, ~c"/multi_handle")
    end
  end

  describe "SFTP Server - Public Key Auth" do
    test "sftp -i can upload list and download with memory backend", %{system_dir: system_dir} do
      sftp = System.find_executable("sftp") || flunk("sftp executable not found")

      ssh_keygen =
        System.find_executable("ssh-keygen") || flunk("ssh-keygen executable not found")

      tmp_dir = Path.join(System.tmp_dir!(), "sftpd_pubkey_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      key_path = Path.join(tmp_dir, "id_ed25519")
      batch_path = Path.join(tmp_dir, "batch")
      upload_path = Path.join(tmp_dir, "upload.txt")
      download_path = Path.join(tmp_dir, "download.txt")

      assert {"", 0} =
               System.cmd(ssh_keygen, [
                 "-q",
                 "-t",
                 "ed25519",
                 "-f",
                 key_path,
                 "-N",
                 ""
               ])

      {:ok, public_key} =
        key_path
        |> then(&File.read!(&1 <> ".pub"))
        |> Sftpd.Auth.decode_authorized_key()

      fingerprint = Sftpd.Auth.fingerprint(public_key)
      File.write!(upload_path, "public key upload")

      File.write!(batch_path, """
      put #{upload_path} uploaded.txt
      ls
      get uploaded.txt #{download_path}
      rm uploaded.txt
      """)

      {:ok, ref} =
        Sftpd.start_server(
          port: @port,
          backend: Sftpd.Backends.Memory,
          backend_opts: [],
          auth: {SftpdIntegrationTest.PublicKeyAuth, [fingerprint: fingerprint]},
          system_dir: system_dir
        )

      on_exit(fn ->
        Sftpd.stop_server(ref)
        File.rm_rf(tmp_dir)
      end)

      {output, status} =
        System.cmd(sftp, [
          "-b",
          batch_path,
          "-i",
          key_path,
          "-P",
          Integer.to_string(@port),
          "-o",
          "StrictHostKeyChecking=no",
          "-o",
          "UserKnownHostsFile=/dev/null",
          "key-user@127.0.0.1"
        ])

      assert status == 0, output
      assert output =~ "uploaded.txt"
      assert File.read!(download_path) == "public key upload"
    end
  end

  defmodule PublicKeyAuth do
    @behaviour Sftpd.Auth

    @impl true
    def authenticate_password(_username, _password, _peer, _opts), do: :error

    @impl true
    def authorize_public_key("key-user", public_key, opts) do
      if Sftpd.Auth.fingerprint(public_key) == Keyword.fetch!(opts, :fingerprint) do
        {:ok, %{username: "key-user"}}
      else
        :error
      end
    end

    def authorize_public_key(_username, _public_key, _opts), do: :error
  end

  defp start_ssh_client do
    # connect client
    assert {:ok, client_connection_ref} = :ssh.connect(:localhost, @port, @client_opts)

    assert {:ok, channel_ref} = :ssh_sftp.start_channel(client_connection_ref)

    on_exit(fn -> :ssh.close(client_connection_ref) end)

    %{client_connection_ref: client_connection_ref, channel_ref: channel_ref}
  end

  defp start_ssh_server(system_dir) do
    case Sftpd.start_server(
           port: @port,
           backend: Sftpd.Backends.S3,
           backend_opts: [bucket: Application.fetch_env!(:sftpd, :bucket)],
           auth: {:passwords, [{"user", "password"}]},
           system_dir: system_dir
         ) do
      {:ok, ref} ->
        on_exit(fn ->
          Sftpd.stop_server(ref)
        end)

        {:ok, ref}

      {:error, :eaddrinuse} ->
        flunk("Port #{@port} already in use - cannot start SSH server")
    end
  end
end
