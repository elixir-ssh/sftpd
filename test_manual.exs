# Manual test script for Sftpd functionality
# Run with: mix run test_manual.exs
# Or use: ./test_sftp.sh (which ensures LocalStack is running)

defmodule SftpdManualTest do
  @port 2223
  @bucket "sftpd-test-bucket"
  @test_content "Hello from SFTP! Test content: #{DateTime.utc_now()}"

  @client_opts [
    silently_accept_hosts: true,
    user: ~c"user",
    password: ~c"password"
  ]

  def run do
    IO.puts("\n=== Sftpd Manual Test ===\n")

    # Ensure S3 bucket exists
    IO.puts("Setting up S3 bucket...")
    ExAws.S3.put_bucket(@bucket, "us-west-2") |> ExAws.request()
    IO.puts("✓ Bucket ready\n")

    # Start SFTP server
    IO.puts("Starting SFTP server on port #{@port}...")
    system_dir = Sftpd.Test.SSHKeys.generate_system_dir()

    {:ok, ref} =
      Sftpd.start_server(
        port: @port,
        backend: Sftpd.Backends.S3,
        backend_opts: [bucket: @bucket],
        users: [{"user", "password"}],
        system_dir: system_dir
      )

    IO.puts("✓ Server started\n")

    # Give server time to initialize
    Process.sleep(500)

    try do
      run_tests()
    after
      IO.puts("\nCleaning up...")
      Sftpd.stop_server(ref)
      IO.puts("✓ Server stopped")
    end
  end

  defp run_tests do
    # Connect client
    IO.puts("Connecting SFTP client...")
    {:ok, conn} = :ssh.connect(:localhost, @port, @client_opts)
    {:ok, channel} = :ssh_sftp.start_channel(conn)
    IO.puts("✓ Client connected\n")

    try do
      # Test 1: List root directory
      IO.puts("Test 1: Listing root directory...")
      {:ok, files} = :ssh_sftp.list_dir(channel, ~c"/")
      IO.puts("  Files: #{inspect(files)}")
      IO.puts("✓ Pass\n")

      # Test 2: Create directory
      IO.puts("Test 2: Creating directory /test_upload...")
      :ok = :ssh_sftp.make_dir(channel, ~c"/test_upload")
      IO.puts("✓ Pass\n")

      # Test 3: Upload file
      IO.puts("Test 3: Uploading file...")
      {:ok, write_handle} = :ssh_sftp.open(channel, ~c"/test_upload/myfile.txt", [:write])
      :ok = :ssh_sftp.write(channel, write_handle, @test_content)
      :ok = :ssh_sftp.close(channel, write_handle)
      IO.puts("  Wrote: #{inspect(@test_content)}")
      IO.puts("✓ Pass\n")

      # Give S3 a moment to complete the multipart upload
      Process.sleep(500)

      # Test 4: Download and verify file
      IO.puts("Test 4: Downloading file...")
      {:ok, read_handle} = :ssh_sftp.open(channel, ~c"/test_upload/myfile.txt", [:read])
      {:ok, content} = :ssh_sftp.read(channel, read_handle, 10000)
      :ok = :ssh_sftp.close(channel, read_handle)
      IO.puts("  Read: #{inspect(content)}")

      # Convert charlist to string for comparison
      content_str = to_string(content)

      if content_str == @test_content do
        IO.puts("✓ Content matches!\n")
      else
        IO.puts("✗ Content mismatch!")
        IO.puts("  Expected: #{inspect(@test_content)}")
        IO.puts("  Got: #{inspect(content_str)}")
        raise "Content verification failed"
      end

      # Test 5: Delete file
      IO.puts("Test 5: Deleting file...")
      :ok = :ssh_sftp.delete(channel, ~c"/test_upload/myfile.txt")
      IO.puts("✓ Pass\n")

      # Test 6: Remove directory
      IO.puts("Test 6: Removing directory...")
      :ok = :ssh_sftp.del_dir(channel, ~c"/test_upload")
      IO.puts("✓ Pass\n")

      IO.puts("=== All tests completed successfully ===")
    after
      :ssh.close(conn)
    end
  end
end

# Run the tests
SftpdManualTest.run()
