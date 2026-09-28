# Contributing to nits

Thanks for helping. Hardware reports are as valuable as code: nits is verified on one
monitor, and every new panel or cable that works (or doesn't) is worth knowing about.
Open an issue with the output of `make probe`; the template asks for the rest.

## Code changes

1. Read [AGENTS.md](AGENTS.md). Its hard rules exist because each one was learned the
   hard way, and they apply to every change: private symbols only in
   `PrivateAPI.swift`, never poll DDC, never treat a failed read as a value, and so on.
2. `make build && make test` must pass. The tests need no monitor, so there is no
   excuse for new wire-format or controller logic to go untested.
3. If you touched the app, run it (`make run`) and say in the PR what you checked, on
   what hardware.
4. If you learned something about a monitor or cable, add it to
   [docs/hardware.md](docs/hardware.md).

Keep PRs to one change each, and match the style of the surrounding code. Comments
explain *why*, not *what*.

By contributing you agree that your contribution is licensed under the
[MIT licence](LICENSE).
