import Config

# Load the environment-specific configuration (e.g. config/test.exs).
# `Code.require_file` evaluates that file in its own scope (it has its own
# `import Config`), avoiding the `import!/1` macro which is unavailable in
# some Elixir versions.
env_config = Path.join(__DIR__, "#{config_env()}.exs")
if File.exists?(env_config), do: Code.require_file(env_config)
