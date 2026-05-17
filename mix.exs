defmodule HoltWorks.MixProject do
  use Mix.Project

  def project do
    [
      app: :holtworks,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      tinfoil: tinfoil()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {HoltWorks.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:burrito, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:tinfoil, "~> 0.2", runtime: false}
    ]
  end

  defp releases do
    [
      holtworks: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos: [os: :darwin, cpu: :x86_64],
            macos_silicon: [os: :darwin, cpu: :aarch64],
            linux: [os: :linux, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            windows: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp tinfoil do
    [
      targets: [:darwin_arm64, :darwin_x86_64, :linux_x86_64, :linux_arm64, :windows_x86_64],
      github: [
        repo: "holtworks/holtworks"
      ],
      installer: [
        enabled: true,
        install_dir: "~/.local/bin"
      ],
      checksums: :sha256,
      attestations: false,
      ci: [
        provider: :github_actions,
        elixir_version: "1.19",
        otp_version: "28"
      ]
    ]
  end
end
