# Contributing

Thanks for taking a look.

## Reporting a problem

[Open an issue](https://github.com/mervin008/soundcorebridge/issues/new/choose).
Anyone can — you don't need write access to the repo.

If it's about a device, click the clipboard button beside Quit in the menu-bar
app to copy a support report. It excludes Bluetooth names, addresses, raw
packets, and logs. Add your headphone model name and describe the problem.

Or quit the menu-bar app to release its Bluetooth connection, then run:

```sh
soundcorectl support-report --out support-report.txt
```

The command reads device identity without running a control handshake or
changing headphone settings. It creates a new file and refuses to overwrite an
existing one. If connection fails, copy the app report and describe the error;
review any additional terminal output before sharing it.

## Adding support for another Soundcore model

Most of the work is confirming what the device actually does, not writing code.
A new model starts with a `DeviceProfile` in
`Sources/soundcorectl/DeviceProfile.swift`: its reported model code, readable
state fields, verified capabilities, transport, handshake and command format.
Do not assume another model uses the Space 2 transport or packet layouts merely
because its Bluetooth name looks similar.

`docs/DEVELOPMENT.md` explains how to capture that from a phone.

Please don't add a profile from guesswork. Writing wrong offsets to real
headphones is how they end up in odd states, which is why unverified models are
read-only by default.

## Pull requests

1. Branch off `main`
2. Run `swift run soundcorectl selftest` — it runs offline, no headset needed
3. Open a PR; CI runs the build and the self-test

Small PRs are easier to review than large ones. If you're planning something
big, open an issue first so we can talk about it.
