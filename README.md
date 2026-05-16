# HoltWorks

HoltWorks is an Elixir-based local agent runtime packaged as a single executable with
[Burrito](https://hex.pm/packages/burrito). The release setup is designed for the
OpenClaw-style install flow: users install a native binary with one command and do
not need Elixir or Erlang on their device.

## Install

After the first GitHub release is published, users can install HoltWorks with:

```sh
curl -fsSL https://raw.githubusercontent.com/holtworks/holtworks/main/scripts/install.sh | sh
```

Windows users can install with PowerShell:

```powershell
iwr -useb https://raw.githubusercontent.com/holtworks/holtworks/main/scripts/install.ps1 | iex
```

The generated installer selects the correct asset for the user's OS and CPU,
verifies the SHA-256 checksum, and installs `holtworks` into `~/.local/bin` by
default.

The `holtworks/holtworks` repository is private right now. For a public
OpenClaw-style one-line install, make the repository or release assets public
before publishing the first release. For private corporate distribution, mirror
the generated installer and release assets behind the company's authenticated
download host.

## Development

```sh
mix deps.get
mix test
mix run -e 'HoltWorks.CLI.main(["doctor"])'
```

## Build A Native Binary

Burrito wraps the OTP release into a standalone executable:

```sh
MIX_ENV=prod mix release
```

Per-target binaries are written to `burrito_out/`.

## Release

Tinfoil owns the GitHub release workflow and installer scripts. Regenerate them
after changing the release config:

```sh
mix tinfoil.generate
```

Publish a release by pushing a version tag:

```sh
git tag v0.1.0
git push --tags
```

GitHub Actions will build Burrito artifacts for macOS, Linux, and Windows, upload
checksums, and publish installer scripts for the one-line install flow.
