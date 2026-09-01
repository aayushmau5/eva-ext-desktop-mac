defmodule EvaDesktopMac.MixProject do
  use Mix.Project

  def project do
    [
      app: :eva_desktop_mac,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Eva.Extension.DesktopMac.Application, []}
    ]
  end

  defp deps do
    [
      eva_core(),
      {:typedstruct, "~> 0.5"}
    ]
  end

  # The contract this extension is written against. It lives in the `core/` directory of
  # the Eva repo rather than a repo of its own — `:sparse` checks out that directory and
  # nothing else, so depending on it does not mean vendoring the host.
  #
  # Set `EVA_CORE_PATH` to work on the contract and the extension together; without it,
  # a change to core is a push and a `mix deps.update eva_core` away from being testable
  # here.
  #
  #     EVA_CORE_PATH=../eva/core mix test
  defp eva_core do
    case System.get_env("EVA_CORE_PATH") do
      nil -> {:eva_core, git: "https://github.com/aayushmau5/eva.git", sparse: "core"}
      path -> {:eva_core, path: path}
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp aliases do
    [
      precommit: [
        "cmd ./scripts/build_helper",
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test",
        "cmd swift test --package-path native/EvaDesktopHelper"
      ]
    ]
  end
end
