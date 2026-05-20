# Start required applications for tests
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:ssh)
{:ok, _} = Application.ensure_all_started(:mox)

Mox.defmock(Sftpd.Test.MockExAws, for: Sftpd.ExAwsClient)

ExUnit.configure(exclude: [integration: true])
ExUnit.start()
