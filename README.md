# ExitCheck

Menu bar app for macOS. It looks up this Mac's public exit and reports whether that exit is in the US.

Cloudflare (`1.1.1.1/cdn-cgi/trace`) and [ipinfo](https://ipinfo.io) both have to answer. The shield is green when they agree on a US exit, yellow when only one source answered or the address is not the pinned one, and red when the exit is not in the US or the two sources disagree.

The check follows the system proxy and VPN, so on a global tunnel it is the same exit other apps use. A proxy applied to one app only is a different path. ExitCheck reports its own exit.

## Requirements

macOS 14 or later. Xcode command-line tools provide `swiftc` and `iconutil`.

## Build

```sh
./build.sh
open dist/ExitCheck.app
```

`build.sh` compiles the app, draws `AppIcon.icns`, and ad-hoc signs the bundle. `build/` and `dist/` are generated and are not in git.

Copy `dist/ExitCheck.app` to `/Applications` if you want it beside your other apps.

## Menu

- **Check Now** runs both lookups immediately.
- **Pin Current IP** stores the address just seen. The item then reads **Unpin**. A different address while still in the US turns the shield yellow.
- **Check Every 5 Minutes** repeats the lookup.
- **Notify When Exit Is Not US** posts a notification when the result changes to a failure.
- **Copy Diagnostics** puts the latest result on the clipboard.

Hold Command and drag the menu bar item to move it. The first launch tries to place it beside Wi-Fi.

## License

[MIT](LICENSE)
