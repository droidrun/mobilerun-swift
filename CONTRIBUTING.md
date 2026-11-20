# Contributing

Use Swift 6.2 and Xcode 26 or newer. Run the interactive example and follow
[TESTING.md](TESTING.md) for setup, local builds, automated checks and the sample checklist.
See [RELEASING.md](RELEASING.md) for the API contract and release process.

## Validation and conformance

Build and test commands are in [TESTING.md](TESTING.md#automated-checks).

macOS tests use fake transports and a virtual clock, without loading WebRTC. They replay the
vendored conformance sequence, initial negotiation and refresh, candidate buffering, timer
spacing, full reconnects, credential rejection, channel guards, and screenshot completion paths.
Fixtures are pinned in [`conformance/VERSION`](conformance/VERSION).

[`Examples/Connection`](Examples/Connection) contains the validation app and runners; see
[`run-input.py --help`](Examples/Connection/tool/run-input.py) for the input scenario contract.
The runners inject `credentials.json` to select the native validation view;
`--default-ui` selects default UI validation. Normal launch opens the tester app.

Maintainers refresh the vendored protocol fixtures from a local fixture checkout:

```sh
tool/sync-conformance.sh "$(cat conformance/VERSION)" /path/to/conformance-clone
python3 tool/generate-constants.py
```

## Pull requests

Use commit messages in the form `type(scope): message`. Open pull requests against
`main` and describe the change and relevant validation.

Report security problems privately as described in [SECURITY.md](SECURITY.md).
