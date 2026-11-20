# Contributing

1. Fork the repo and create a branch from `main`.
2. Build and run self-tests: `./build.sh` (macOS 13+, Xcode command line tools).
3. Open a pull request. All changes go through PRs; CI (build + CodeQL) must pass.

PR titles must follow [Conventional Commits](https://www.conventionalcommits.org/)
(`feat: …`, `fix: …`, `docs: …`, `ci: …`, `feat!: …` for breaking changes). PRs are
squash-merged and the title becomes the commit on `main`. Versions and the changelog
are generated from these titles by release-please.

Keep PRs focused. For larger changes, open an issue first.
Security issues: see [SECURITY.md](SECURITY.md).
