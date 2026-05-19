defmodule Sftpd.Backends.S3Test do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Mox

  alias Sftpd.Backends.S3
  alias Sftpd.Test.MockExAws

  @multipart_part_size 5 * 1024 * 1024

  setup :verify_on_exit!

  describe "parse_http_date/1" do
    test "parses valid RFC 1123 date" do
      assert {{1994, 11, 6}, {8, 49, 37}} = S3.parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT")
    end

    test "parses date with different day of week" do
      assert {{2024, 1, 15}, {12, 30, 45}} = S3.parse_http_date("Mon, 15 Jan 2024 12:30:45 GMT")
    end

    test "parses all months correctly" do
      months = [
        {"Jan", 1},
        {"Feb", 2},
        {"Mar", 3},
        {"Apr", 4},
        {"May", 5},
        {"Jun", 6},
        {"Jul", 7},
        {"Aug", 8},
        {"Sep", 9},
        {"Oct", 10},
        {"Nov", 11},
        {"Dec", 12}
      ]

      for {month, num} <- months do
        date_string = "Sun, 01 #{month} 2024 00:00:00 GMT"
        assert {{2024, ^num, 1}, {0, 0, 0}} = S3.parse_http_date(date_string)
      end
    end

    test "returns current time for invalid format" do
      {date, time} = S3.parse_http_date("not a valid date")
      assert {:ok, _} = NaiveDateTime.from_erl({date, time})
    end
  end

  describe "init/1" do
    test "requires bucket option" do
      assert {:error, :missing_bucket} = S3.init([])
    end

    test "extracts configuration from options" do
      {:ok, state} = S3.init(bucket: "my-bucket", prefix: "tenant/", aws_client: MockExAws)
      assert state.bucket == "my-bucket"
      assert state.prefix == "tenant/"
      assert state.aws_client == MockExAws
    end
  end

  describe "list_dir/2 with mock" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", aws_client: MockExAws)
      %{state: state}
    end

    property "root listings are sorted unique immediate entries across files and prefixes", %{
      state: state
    } do
      check all(
              files <- uniq_list_of(s3_segment(), max_length: 20),
              dirs <- uniq_list_of(s3_segment(), max_length: 20)
            ) do
        expect(MockExAws, :request, fn op ->
          assert op.params["prefix"] == ""
          assert op.params["delimiter"] == "/"

          {:ok,
           %{
             body: %{
               contents: Enum.map(files, &%{key: &1}) ++ [%{key: ".keep"}],
               common_prefixes: Enum.map(dirs, &%{prefix: &1 <> "/"}),
               is_truncated: "false"
             }
           }}
        end)

        expected =
          (files ++ dirs)
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.map(&String.to_charlist/1)

        assert {:ok, [~c".", ~c".." | listing]} = S3.list_dir(~c"/", state)
        assert listing == expected
      end
    end

    test "root path lists top-level entries across pages", %{state: state} do
      expect(MockExAws, :request, fn op ->
        assert op.params["prefix"] == ""
        assert op.params["delimiter"] == "/"
        refute Map.has_key?(op.params, "continuation-token")

        {:ok,
         %{
           body: %{
             contents: [%{key: "file.txt"}],
             common_prefixes: [%{prefix: "dir/"}],
             is_truncated: "true",
             next_continuation_token: "page-2"
           }
         }}
      end)

      expect(MockExAws, :request, fn op ->
        assert op.params["prefix"] == ""
        assert op.params["delimiter"] == "/"
        assert op.params["continuation-token"] == "page-2"

        {:ok,
         %{
           body: %{
             contents: [%{key: ".keep"}, %{key: "z-last.txt"}],
             common_prefixes: [%{prefix: "nested/"}],
             is_truncated: "false"
           }
         }}
      end)

      assert {:ok, listing} = S3.list_dir(~c"/", state)
      assert listing == [~c".", ~c"..", ~c"dir", ~c"file.txt", ~c"nested", ~c"z-last.txt"]
    end

    test "subdirectory lists only immediate children", %{state: state} do
      expect(MockExAws, :request, fn op ->
        assert op.params["prefix"] == "subdir/"
        assert op.params["delimiter"] == "/"

        {:ok,
         %{
           body: %{
             contents: [
               %{key: "subdir/file1.txt"},
               %{key: "subdir/nested/file2.txt"}
             ],
             common_prefixes: [%{prefix: "subdir/nested/"}],
             is_truncated: "false"
           }
         }}
      end)

      assert {:ok, listing} = S3.list_dir(~c"/subdir", state)
      assert listing == [~c".", ~c"..", ~c"file1.txt", ~c"nested"]
    end

    test "list_dir handles S3 errors gracefully", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :timeout} end)
      assert {:ok, [~c".", ~c".."]} = S3.list_dir(~c"/", state)
    end
  end

  describe "file_info/2 with mock" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", aws_client: MockExAws)
      %{state: state}
    end

    test "root path always returns directory info", %{state: state} do
      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               S3.file_info(~c"/", state)
    end

    test "existing file returns file info with size and mtime", %{state: state} do
      expect(MockExAws, :request, fn _op ->
        {:ok,
         %{
           headers: [
             {"Content-Length", "42"},
             {"Last-Modified", "Mon, 15 Jan 2024 12:30:45 GMT"}
           ]
         }}
      end)

      assert {:ok, {:file_info, 42, :regular, :read_write, mtime, _, _, _, _, _, _, _, _, _}} =
               S3.file_info(~c"/file.txt", state)

      assert mtime == {{2024, 1, 15}, {12, 30, 45}}
    end

    test "directory returns directory info via common prefixes", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :not_found} end)

      expect(MockExAws, :request, fn op ->
        assert op.params["prefix"] == "dir/"
        assert op.params["delimiter"] == "/"
        assert op.params["max-keys"] == 1
        {:ok, %{body: %{contents: [], common_prefixes: [%{prefix: "dir/nested/"}]}}}
      end)

      assert {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} =
               S3.file_info(~c"/dir", state)
    end

    test "non-existent path returns enoent", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :not_found} end)

      expect(MockExAws, :request, fn _op ->
        {:ok, %{body: %{contents: [], common_prefixes: []}}}
      end)

      assert {:error, :enoent} = S3.file_info(~c"/missing", state)
    end

    test "forbidden file_info returns eacces", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :forbidden} end)
      assert {:error, :eacces} = S3.file_info(~c"/private.txt", state)
    end
  end

  describe "directory mutation with mock" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", aws_client: MockExAws)
      %{state: state}
    end

    test "make_dir creates the .keep marker", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{}} end)
      assert :ok = S3.make_dir(~c"/newdir", state)
    end

    test "make_dir normalizes forbidden errors", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :forbidden} end)
      assert {:error, :eacces} = S3.make_dir(~c"/newdir", state)
    end

    test "del_dir returns enoent on 404", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, {:http_error, 404, %{}}} end)
      assert {:error, :enoent} = S3.del_dir(~c"/dir", state)
    end

    test "del_dir returns ok on success", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{}} end)
      assert :ok = S3.del_dir(~c"/dir", state)
    end
  end

  describe "file mutation with mock" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", aws_client: MockExAws)
      %{state: state}
    end

    test "delete returns eacces on forbidden errors", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :forbidden} end)
      assert {:error, :eacces} = S3.delete(~c"/file.txt", state)
    end

    test "delete returns ok on success", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{}} end)
      assert :ok = S3.delete(~c"/file.txt", state)
    end

    test "rename returns enoent when copy fails", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :not_found} end)
      assert {:error, :enoent} = S3.rename(~c"/old.txt", ~c"/new.txt", state)
    end

    test "rename returns eio when delete fails after a successful copy", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{}} end)
      expect(MockExAws, :request, fn _op -> {:error, {:http_error, 500, %{}}} end)
      assert {:error, :eio} = S3.rename(~c"/old.txt", ~c"/new.txt", state)
    end

    test "write_file normalizes unknown errors to eio", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :quota_exceeded} end)
      assert {:error, :eio} = S3.write_file(~c"/file.txt", "content", state)
    end

    test "write_file returns ok on success", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{}} end)
      assert :ok = S3.write_file(~c"/file.txt", "content", state)
    end
  end

  describe "read_file/2 and read_file_range/4 with mock" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", aws_client: MockExAws)
      %{state: state}
    end

    test "read_file returns file contents on success", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{body: "hello world"}} end)
      assert {:ok, "hello world"} = S3.read_file(~c"/file.txt", state)
    end

    test "read_file returns enoent on 404", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, {:http_error, 404, %{}}} end)
      assert {:error, :enoent} = S3.read_file(~c"/missing.txt", state)
    end

    property "read_file_range accepts only valid bounded success responses", %{state: state} do
      check all(
              offset <- integer(0..64),
              len <- integer(1..64),
              body <- binary(max_length: 96),
              status <- member_of([200, 206, 301, 500])
            ) do
        expect(MockExAws, :request, fn op ->
          assert op.headers["range"] == "bytes=#{offset}-#{offset + len - 1}"
          {:ok, %{status_code: status, body: body}}
        end)

        expected =
          cond do
            body == "" and status in [200, 206] ->
              :eof

            status == 206 and byte_size(body) <= len ->
              {:ok, body}

            status == 200 and offset == 0 and byte_size(body) <= len ->
              {:ok, body}

            true ->
              {:error, :eio}
          end

        assert S3.read_file_range(~c"/file.txt", offset, len, state) == expected
      end
    end

    test "read_file_range sets the range header and returns data", %{state: state} do
      expect(MockExAws, :request, fn op ->
        assert op.headers["range"] == "bytes=5-8"
        {:ok, %{status_code: 206, body: "6789"}}
      end)

      assert {:ok, "6789"} = S3.read_file_range(~c"/file.txt", 5, 4, state)
    end

    test "read_file_range returns eof on 416", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, {:http_error, 416, %{}}} end)
      assert :eof = S3.read_file_range(~c"/file.txt", 100, 4, state)
    end

    test "read_file_range returns eof for empty successful bodies", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{status_code: 206, body: ""}} end)
      assert :eof = S3.read_file_range(~c"/file.txt", 0, 4, state)
    end

    test "read_file_range accepts a 200 response only for offset zero within len", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{status_code: 200, body: "abc"}} end)
      assert {:ok, "abc"} = S3.read_file_range(~c"/file.txt", 0, 4, state)
    end

    test "read_file_range rejects oversized 200 responses", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{status_code: 200, body: "abcde"}} end)
      assert {:error, :eio} = S3.read_file_range(~c"/file.txt", 0, 4, state)
    end

    test "read_file_range rejects 200 responses for non-zero offsets", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{status_code: 200, body: "full-object"}} end)
      assert {:error, :eio} = S3.read_file_range(~c"/file.txt", 5, 4, state)
    end

    test "read_file_range returns eio for unexpected success statuses", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:ok, %{status_code: 301, body: "redirect"}} end)
      assert {:error, :eio} = S3.read_file_range(~c"/file.txt", 0, 4, state)
    end

    test "read_file_range normalizes generic request errors", %{state: state} do
      expect(MockExAws, :request, fn _op -> {:error, :closed} end)
      assert {:error, :eio} = S3.read_file_range(~c"/file.txt", 0, 4, state)
    end
  end

  describe "streaming write callbacks" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", aws_client: MockExAws)
      %{state: state}
    end

    property "write_chunk uploads complete multipart parts and keeps only the remainder", %{
      state: state
    } do
      check all(
              sizes <-
                list_of(
                  member_of([
                    0,
                    1,
                    @multipart_part_size - 1,
                    @multipart_part_size,
                    @multipart_part_size + 1
                  ]),
                  min_length: 1,
                  max_length: 4
                ),
              max_runs: 15
            ) do
        test_pid = self()

        stub(MockExAws, :request, fn op ->
          case op.http_method do
            :post ->
              {:ok, %{body: %{upload_id: "upload-1"}}}

            :put ->
              part_number = op.params["partNumber"]
              send(test_pid, {:uploaded_part, part_number, byte_size(op.body)})
              {:ok, %{headers: [{"etag", "\"etag-#{part_number}\""}]}}
          end
        end)

        writer = %{
          bucket: "test-bucket",
          key: "large.bin",
          upload_id: nil,
          next_offset: 0,
          next_part_number: 1,
          pending_chunks: :queue.new(),
          pending_size: 0,
          uploaded_parts: []
        }

        {writer, total_size} =
          Enum.reduce(sizes, {writer, 0}, fn size, {writer, offset} ->
            chunk = :binary.copy(<<1>>, size)
            assert {:ok, writer} = S3.write_chunk(writer, offset, chunk, state)
            {writer, offset + size}
          end)

        uploaded_count = div(total_size, @multipart_part_size)
        remainder = rem(total_size, @multipart_part_size)

        assert writer.next_offset == total_size
        assert writer.next_part_number == uploaded_count + 1
        assert writer.pending_size == remainder
        assert pending_size(writer) == remainder

        for part_number <- 1..uploaded_count//1 do
          assert_receive {:uploaded_part, ^part_number, @multipart_part_size}, 1000
        end

        refute_receive {:uploaded_part, _, _}, 100
      end
    end

    test "write_chunk uploads full multipart parts incrementally", %{state: state} do
      assert {:ok, writer} = S3.begin_write(~c"/large.bin", state)
      assert writer.upload_id == nil

      expect(MockExAws, :request, fn op ->
        assert op.http_method == :post
        {:ok, %{body: %{upload_id: "upload-1"}}}
      end)

      expect(MockExAws, :request, fn op ->
        assert op.http_method == :put
        assert op.params["partNumber"] == 1
        assert op.params["uploadId"] == "upload-1"
        {:ok, %{headers: [{"etag", "\"etag-1\""}]}}
      end)

      chunk = :binary.copy(<<1>>, @multipart_part_size + 3)
      assert {:ok, writer} = S3.write_chunk(writer, 0, chunk, state)
      assert writer.upload_id == "upload-1"
      assert writer.next_part_number == 2
      assert writer.pending_size == 3
      assert :queue.to_list(writer.pending_chunks) == [:binary.copy(<<1>>, 3)]
      assert writer.uploaded_parts == [{1, "\"etag-1\""}]
    end

    test "write_chunk keeps small writes in queued buffers", %{state: state} do
      assert {:ok, writer} = S3.begin_write(~c"/large.bin", state)
      assert {:ok, writer} = S3.write_chunk(writer, 0, "abc", state)
      assert {:ok, writer} = S3.write_chunk(writer, 3, ["de", ?f], state)

      assert writer.upload_id == nil
      assert writer.pending_size == 6
      assert :queue.to_list(writer.pending_chunks) == ["abc", "def"]
    end

    test "write_chunk normalizes multipart initiation errors", %{state: state} do
      assert {:ok, writer} = S3.begin_write(~c"/large.bin", state)

      expect(MockExAws, :request, fn _op -> {:error, {:http_error, 403, %{}}} end)

      chunk = :binary.copy(<<1>>, @multipart_part_size)
      assert {:error, :eacces} = S3.write_chunk(writer, 0, chunk, state)
    end

    test "write_chunk aborts multipart uploads when part upload fails", %{state: state} do
      assert {:ok, writer} = S3.begin_write(~c"/large.bin", state)

      expect(MockExAws, :request, fn op ->
        assert op.http_method == :post
        {:ok, %{body: %{upload_id: "upload-1"}}}
      end)

      expect(MockExAws, :request, fn op ->
        assert op.http_method == :put
        assert op.params["uploadId"] == "upload-1"
        {:error, {:http_error, 500, %{}}}
      end)

      expect(MockExAws, :request, fn op ->
        assert op.http_method == :delete
        assert op.params["uploadId"] == "upload-1"
        {:ok, %{}}
      end)

      chunk = :binary.copy(<<1>>, @multipart_part_size)
      assert {:error, :eio} = S3.write_chunk(writer, 0, chunk, state)
    end

    test "write_chunk rejects non-sequential offsets", %{state: state} do
      writer = %{
        bucket: "test-bucket",
        key: "large.bin",
        upload_id: "upload-1",
        next_offset: 5,
        next_part_number: 1,
        pending_chunks: :queue.new(),
        pending_size: 0,
        uploaded_parts: []
      }

      assert {:error, :einval} = S3.write_chunk(writer, 0, "abc", state)
    end

    test "finish_write uses put_object directly for small files", %{state: state} do
      writer = %{
        bucket: "test-bucket",
        key: "small.txt",
        upload_id: nil,
        next_offset: 3,
        next_part_number: 1,
        pending_chunks: :queue.from_list(["abc"]),
        pending_size: 3,
        uploaded_parts: []
      }

      expect(MockExAws, :request, fn op ->
        assert op.http_method == :put
        assert op.body == "abc"
        {:ok, %{}}
      end)

      assert :ok = S3.finish_write(writer, state)
    end

    test "finish_write uploads the final part and completes multipart upload", %{state: state} do
      writer = %{
        bucket: "test-bucket",
        key: "large.bin",
        upload_id: "upload-1",
        next_offset: @multipart_part_size + 4,
        next_part_number: 2,
        pending_chunks: :queue.from_list(["tail"]),
        pending_size: 4,
        uploaded_parts: [{1, "\"etag-1\""}]
      }

      expect(MockExAws, :request, fn op ->
        assert op.http_method == :put
        assert op.params["partNumber"] == 2
        assert op.params["uploadId"] == "upload-1"
        {:ok, %{headers: [{"etag", "\"etag-2\""}]}}
      end)

      expect(MockExAws, :request, fn op ->
        assert op.http_method == :post
        assert op.params["uploadId"] == "upload-1"
        assert op.body =~ "<PartNumber>1</PartNumber>"
        assert op.body =~ "<PartNumber>2</PartNumber>"
        {:ok, %{}}
      end)

      assert :ok = S3.finish_write(writer, state)
    end

    test "finish_write completes multipart uploads without a final buffered part", %{state: state} do
      writer = %{
        bucket: "test-bucket",
        key: "large.bin",
        upload_id: "upload-1",
        next_offset: @multipart_part_size,
        next_part_number: 2,
        pending_chunks: :queue.new(),
        pending_size: 0,
        uploaded_parts: [{1, "\"etag-1\""}]
      }

      expect(MockExAws, :request, fn op ->
        assert op.http_method == :post
        assert op.params["uploadId"] == "upload-1"
        assert op.body =~ "<PartNumber>1</PartNumber>"
        {:ok, %{}}
      end)

      assert :ok = S3.finish_write(writer, state)
    end

    test "finish_write returns eio when upload responses are missing etags", %{state: state} do
      writer = %{
        bucket: "test-bucket",
        key: "large.bin",
        upload_id: "upload-1",
        next_offset: @multipart_part_size + 4,
        next_part_number: 2,
        pending_chunks: :queue.from_list(["tail"]),
        pending_size: 4,
        uploaded_parts: [{1, "\"etag-1\""}]
      }

      expect(MockExAws, :request, fn _op -> {:ok, %{headers: []}} end)
      assert {:error, :eio} = S3.finish_write(writer, state)
    end

    test "abort_write returns ok on successful aborts", %{state: state} do
      writer = %{
        bucket: "test-bucket",
        key: "large.bin",
        upload_id: "upload-1",
        next_offset: 0,
        next_part_number: 1,
        pending_chunks: :queue.new(),
        pending_size: 0,
        uploaded_parts: []
      }

      expect(MockExAws, :request, fn _op -> {:ok, %{}} end)
      assert :ok = S3.abort_write(writer, state)
    end

    test "abort_write swallows backend errors", %{state: state} do
      writer = %{
        bucket: "test-bucket",
        key: "large.bin",
        upload_id: "upload-1",
        next_offset: 0,
        next_part_number: 1,
        pending_chunks: :queue.new(),
        pending_size: 0,
        uploaded_parts: []
      }

      expect(MockExAws, :request, fn _op -> {:error, {:http_error, 500, %{}}} end)
      assert :ok = S3.abort_write(writer, state)
    end
  end

  describe "prefix support" do
    setup do
      {:ok, state} = S3.init(bucket: "test-bucket", prefix: "tenant/", aws_client: MockExAws)
      %{state: state}
    end

    test "list_dir strips the global prefix from results", %{state: state} do
      expect(MockExAws, :request, fn op ->
        assert op.params["prefix"] == "tenant/"
        assert op.params["delimiter"] == "/"

        {:ok,
         %{
           body: %{
             contents: [%{key: "tenant/file.txt"}],
             common_prefixes: [%{prefix: "tenant/dir/"}],
             is_truncated: "false"
           }
         }}
      end)

      assert {:ok, [~c".", ~c"..", ~c"dir", ~c"file.txt"]} = S3.list_dir(~c"/", state)
    end

    test "list_dir strips only one copy of the global prefix", %{state: state} do
      expect(MockExAws, :request, fn op ->
        assert op.params["prefix"] == "tenant/"

        {:ok,
         %{
           body: %{
             contents: [],
             common_prefixes: [%{prefix: "tenant/tenant/"}],
             is_truncated: "false"
           }
         }}
      end)

      assert {:ok, [~c".", ~c"..", ~c"tenant"]} = S3.list_dir(~c"/", state)
    end

    test "file_info uses the prefixed object key", %{state: state} do
      expect(MockExAws, :request, fn op ->
        assert op.path == "tenant/file.txt"
        {:ok, %{headers: [{"Content-Length", "10"}]}}
      end)

      assert {:ok, {:file_info, 10, :regular, _, _, _, _, _, _, _, _, _, _, _}} =
               S3.file_info(~c"/file.txt", state)
    end

    test "list_dir ignores empty stripped entries and keep markers", %{state: state} do
      expect(MockExAws, :request, fn op ->
        assert op.params["prefix"] == "tenant/"

        {:ok,
         %{
           body: %{
             contents: [%{key: "tenant/"}, %{key: "tenant/.keep"}],
             common_prefixes: [%{prefix: "tenant/dir/"}, %{prefix: "tenant/.keep/"}],
             is_truncated: "false"
           }
         }}
      end)

      assert {:ok, [~c".", ~c"..", ~c"dir"]} = S3.list_dir(~c"/", state)
    end
  end

  defp s3_segment do
    string(:alphanumeric, min_length: 1, max_length: 12)
  end

  defp pending_size(writer) do
    writer.pending_chunks
    |> :queue.to_list()
    |> IO.iodata_to_binary()
    |> byte_size()
  end
end
