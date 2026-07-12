import Config

# This package ships no runtime config of its own — config here exists
# only to support the standalone test suite (Test.Repo wiring below).
if config_env() == :test do
  import_config "test.exs"
end
