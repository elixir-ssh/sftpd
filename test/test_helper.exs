# Start required applications for tests
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:ssh)

ExUnit.start()
