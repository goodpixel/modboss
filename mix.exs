defmodule ModBoss.MixProject do
  use Mix.Project

  @source_url "https://github.com/goodpixel/modboss"
  @version "0.1.1"

  def project do
    [
      app: :modboss,
      version: @version,
      elixir: "~> 1.16",
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        check_plt: true
      ],
      start_permanent: Mix.env() == :prod,
      description: description(),
      deps: deps(),
      docs: docs(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.0", optional: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true}
    ]
  end

  defp description do
    "Modbus schema mapping with automatic encoding/decoding."
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/boss-t.png",
      extras: ["README.md": [title: "Overview"]],
      assets: %{"assets" => "assets"},
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end

  def package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/goodpixel/modboss"}
    ]
  end
end
