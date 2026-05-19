import Config

# S3 backend configuration (default)
config :sftpd,
  backend: Sftpd.Backends.S3,
  backend_opts: [bucket: "sftpd-dev-bucket"]

# ExAws configuration for AWS S3
# config :ex_aws,
#  access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}, :instance_role],
#  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}, :instance_role],
#  region: "us-west-2"

# --- Alternative configurations ---

# MinIO (local S3-compatible storage):
#
# config :sftpd,
#   backend: Sftpd.Backends.S3,
#   backend_opts: [bucket: "my-local-bucket"]
#
# config :ex_aws,
#   access_key_id: "minioadmin",
#   secret_access_key: "minioadmin",
#   region: "us-east-1"
#
# config :ex_aws, :s3,
#   scheme: "http://",
#   host: "localhost",
#   port: 9000

# In-memory backend (no external dependencies):
#
# config :sftpd,
#   backend: Sftpd.Backends.Memory,
#   backend_opts: []
#
# The Memory backend stores files in an Agent process and is useful for:
# - Development without local S3
# - Testing without external dependencies
# - Experimenting with the SFTP server
#
# You can also pre-populate files:
#
# config :sftpd,
#   backend: Sftpd.Backends.Memory,
#   backend_opts: [
#     files: %{
#       "example.txt" => %{content: "Hello!", mtime: ~N[2024-01-01 00:00:00]}
#     }
#   ]
