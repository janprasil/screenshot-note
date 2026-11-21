# Contributing

1. Fork the repo and create a branch from `main`.
2. Build and run self-tests: `./build.sh` (macOS 13+, Xcode command line tools; Swift Package Manager builds the app and a separate test host).
3. Open a pull request. All changes go through PRs; CI (build + CodeQL) must pass.

PR titles must follow [Conventional Commits](https://www.conventionalcommits.org/)
(`feat: …`, `fix: …`, `docs: …`, `ci: …`, `feat!: …` for breaking changes). PRs are
squash-merged and the title becomes the commit on `main`. Versions and release notes
are generated from these titles: a release candidate (`vX.Y.Z-rc.N`) is published nightly
when `main` has new `feat`/`fix`/`perf` changes, and every Monday the newest RC that is at
least 7 days old is promoted to the stable `vX.Y.Z` release with the same binaries.

Keep PRs focused. For larger changes, open an issue first.
Security issues: see [SECURITY.md](SECURITY.md).
