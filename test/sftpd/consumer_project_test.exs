defmodule Sftpd.ConsumerProjectTest do
  use ExUnit.Case, async: false

  @moduletag :consumer_project

  @repo_root Path.expand("../..", __DIR__)
  @s3_deps """
      {:ex_aws, "~> 2.0"},
      {:ex_aws_s3, "~> 2.0"},
      {:hackney, "~> 1.9"},
      {:sweet_xml, "~> 0.7"},
      {:jason, "~> 1.3"},
      {:configparser_ex, "~> 4.0"}
  """

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "sftpd-consumer-#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  @tag timeout: 180_000
  test "core-only consumers compile without S3 dependencies", %{tmp_dir: tmp_dir} do
    write_mix_project!(tmp_dir, "")

    mix!(["deps.get"], tmp_dir)
    mix!(["compile", "--warnings-as-errors"], tmp_dir)

    mix!(
      [
        "run",
        "-e",
        ~s|unless Sftpd.Backends.S3.init(bucket: "x") == {:error, :missing_s3_dependency}, do: raise("expected missing S3 dependency")|
      ],
      tmp_dir
    )
  end

  @tag timeout: 180_000
  test "S3-enabled consumers compile and initialize the S3 backend", %{tmp_dir: tmp_dir} do
    write_mix_project!(tmp_dir, @s3_deps)

    mix!(["deps.get"], tmp_dir)
    mix!(["compile", "--warnings-as-errors"], tmp_dir)

    mix!(
      [
        "run",
        "-e",
        ~s|case Sftpd.Backends.S3.init(bucket: "x") do {:ok, %{bucket: "x", prefix: "", aws_client: ExAws}} -> :ok; other -> raise("unexpected S3 init result: \#{inspect(other)}") end|
      ],
      tmp_dir
    )
  end

  defp write_mix_project!(dir, extra_deps) do
    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Consumer.MixProject do
      use Mix.Project

      def project do
        [
          app: :consumer,
          version: "0.1.0",
          elixir: "~> 1.14",
          deps: deps()
        ]
      end

      def application, do: [extra_applications: [:logger]]

      defp deps do
        [
          {:sftpd, path: #{inspect(@repo_root)}}#{maybe_extra_deps(extra_deps)}
        ]
      end
    end
    """)
  end

  defp maybe_extra_deps(""), do: ""
  defp maybe_extra_deps(extra_deps), do: ",\n" <> extra_deps

  defp mix!(args, cwd) do
    {output, status} =
      System.cmd("mix", args,
        cd: cwd,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "dev"}]
      )

    assert status == 0, """
    mix #{Enum.join(args, " ")} failed in #{cwd}

    #{output}
    """

    output
  end
end
