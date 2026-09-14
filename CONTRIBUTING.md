# Contributing

Thanks for taking a look.

## Reporting a problem

[Open an issue](https://github.com/mervin008/soundcorebridge/issues/new/choose).
Anyone can — you don't need write access to the repo.

If it's about a device, please include the output of:

```sh
soundcorectl status
soundcorectl sdp
```

## Adding support for another Soundcore model

Most of the work is confirming what the device actually does, not writing code.
The frame format is the same across the range, so a new model is a
`DeviceProfile` in `Sources/soundcorectl/DeviceProfile.swift` — field offsets,
which value means which sound mode, and how many EQ bands there are.

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
