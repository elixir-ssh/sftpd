defmodule Sftpd.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/elixir-ssh/sftpd"

  def project do
    [
      app: :sftpd,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description: "Pluggable SFTP server with support for S3 and custom backends",
      package: package(),

      # Docs
      name: "Sftpd",
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :logger, :ssh]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # S3 backend dependencies (optional for users who only need other backends)
      {:ex_aws, "~> 2.0", optional: true},
      {:ex_aws_s3, "~> 2.0", optional: true},
      {:hackney, "~> 1.9", optional: true},
      {:sweet_xml, "~> 0.7", optional: true},
      {:jason, "~> 1.3", optional: true},
      {:configparser_ex, "~> 4.0", optional: true},
      {:telemetry, ">= 0.4.3 and < 2.0.0", optional: true},

      # Dev/test dependencies
      {:dialyxir, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:mox, "~> 1.0", only: :test},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp aliases do
    [
      # Use --no-start to prevent automatic application startup. Applications are
      # started explicitly in test_helper.exs to control the startup order and
      # avoid issues with SSH daemon initialization during test discovery.
      test: ["test --no-start"]
    ]
  end

  defp package do
    [
      maintainers: ["Michael Christensen"],
      organization: "elixir_ssh",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      },
      files:
        ~w(lib .formatter.exs mix.exs README.md GETTING_STARTED.md BACKENDS.md CUSTOM_BACKENDS.md TELEMETRY.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "Sftpd",
      extras: [
        "README.md",
        "GETTING_STARTED.md",
        "BACKENDS.md",
        "CUSTOM_BACKENDS.md",
        "TELEMETRY.md"
      ],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Core: [Sftpd, Sftpd.Backend, Sftpd.Telemetry],
        Backends: [Sftpd.Backends.S3, Sftpd.Backends.Memory],
        Internal: [Sftpd.FileHandler, Sftpd.IODevice]
      ]
    ]
  end
end
