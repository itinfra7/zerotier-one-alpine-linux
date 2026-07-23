# ZeroTier One Alpine Linux Updater

This repository provides a script to install and upgrade ZeroTier One from the upstream latest release on Alpine Linux.

## Repository Scope

This repository focuses only on:

- Building and installing the ZeroTier One binary on Alpine Linux
- Checking upstream latest releases and performing update flow
- OpenRC service registration and default runlevel enablement
- Avoiding redundant builds using recorded installed version state

## Source Files

- `zerotier-one-alpine-linux.sh`  
  Single script for release detection, build, installation, service management, and installed version tracking.

## Supported Environment

- OS: Alpine Linux (uses `apk`, OpenRC)
- Architecture: `apk`-based Alpine build environment (for example, amd64)
- Required privileges: root

## Patch Scope / Behavior

- Package installation: required build and runtime packages are installed with `apk` when the script runs.
- Source retrieval: latest tag is resolved from the GitHub API, then tarball is downloaded.
- Build: default build excludes Rust SSO path (`ZT_SSO_SUPPORTED=0`) for standard Alpine builds.
- Install: installation is performed via `make install`.
- Service: creates `/etc/init.d/zerotier-one`, adds it to default runlevel, then starts/restarts the service.
- Version record: stored at `/var/lib/zerotier-one/.zerotierone-installed-version`.

## Installation

```sh
chmod +x zerotier-one-alpine-linux.sh
./zerotier-one-alpine-linux.sh
```

Options:

- `--force`: force rebuild/reinstall even if the installed version matches latest
- `--no-service`: skip service stop/register/start steps
- `--with-rust`: install Rust toolchain and use Rust-capable build path

## Testing

- `./zerotier-one-alpine-linux.sh --help`
- After install/upgrade:
  - `rc-service zerotier-one status`
  - `command -v zerotier-one`
  - `zerotier-one -h`

## Rollback

The script is designed for forward update to the latest release and does not provide automatic rollback to a previous version.

Recommended rollback method (manual):

- Stop service: `rc-service zerotier-one stop`
- Restore a previously backed-up binary/configuration manually
- Remove from default runlevel: `rc-update del zerotier-one default`
- Clean generated service script if needed: `/etc/init.d/zerotier-one`
- Remove version state file if required: `/var/lib/zerotier-one/.zerotierone-installed-version`

## Security Model

- Source and release metadata are fetched over HTTPS from GitHub endpoints.
- This workflow assumes trusted OS package indexes; in restricted networks, add mirror policy and optional hash/signature verification before deployment.
- No additional personal data collection is performed during build execution.

## License

This project is licensed under the MIT License (`LICENSE`).

## Credits

- Upstream project: ZeroTier One (https://github.com/zerotier/ZeroTierOne)
- Author: itinfra7 (GitHub: itinfra7)
