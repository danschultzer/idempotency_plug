defmodule IdempotencyPlug.MixProject do
  use Mix.Project

  @source_url "https://github.com/danschultzer/idempotency_plug"
  @version "0.2.1"

  def project do
    [
      app: :idempotency_plug,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Hex
      description: "Plug that makes POST and PATCH requests idempotent",
      package: package(),

      # Docs
      name: "IdempotencyPlug",
      docs: docs(),

      # Dialyzer
      dialyzer: [
        plt_add_apps: [:mix]
      ]
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
      {:plug, "~> 1.14"},
      {:jason, "~> 1.2"},
      {:telemetry, "~> 1.0"},
      {:ecto, "~> 3.9", optional: true},
      {:ecto_sql, "~> 3.9", optional: true},

      # Development and test
      {:postgrex, ">= 0.0.0", only: [:test]},
      {:credo, ">= 0.0.0", only: [:dev, :test]},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Dan Schultzer"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Sponsor" => "https://github.com/sponsors/danschultzer"
      },
      files: ~w(lib LICENSE mix.exs README.md)
    ]
  end

  defp docs do
    [
      source_ref: "v#{@version}",
      main: "README",
      canonical: "http://hexdocs.pm/idempotency_plug",
      source_url: @source_url,
      extras: [
        "README.md": [filename: "README"],
        "CHANGELOG.md": [filename: "CHANGELOG"]
      ],
      skip_undefined_reference_warnings_on: [
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        "Cache Store": [
          IdempotencyPlug.EctoStore,
          IdempotencyPlug.ETSStore,
          IdempotencyPlug.Store
        ]
      ]
    ]
  end
end
