import Config

# Keep debug logs available - tests can use capture_log to suppress
config :logger, level: :debug

# S3-compatible endpoint for tests. CI uses MinIO via AWS_ENDPOINT_URL; local
# runs default to the LocalStack service from docker-compose.yml.
aws_uri =
  System.get_env("AWS_ENDPOINT_URL", "http://localhost:4566")
  |> URI.parse()

config :ex_aws,
  access_key_id: System.get_env("AWS_ACCESS_KEY_ID", ""),
  secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY", ""),
  region: System.get_env("AWS_REGION", "us-east-1")

config :ex_aws, :s3,
  scheme: aws_uri.scheme <> "://",
  host: aws_uri.host,
  port: aws_uri.port

# S3 backend configuration for tests
config :sftpd,
  bucket: "sftpd-test-bucket"
