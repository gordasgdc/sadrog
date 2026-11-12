# Contributing to SADROG

Thank you for wanting to help. SADROG is free software (GPL-3.0-or-later), maintained by one person in spare time. Please read this page first; it keeps everyone's effort useful.

## What to expect

- Issues and pull requests are read, but not on a schedule. A reply can take weeks.
- There is no roadmap commitment and no support obligation. Small, focused, tested pull requests are the most likely to be merged.
- For a larger change, open an issue first and describe what you want to do, so you do not spend time on something that cannot be merged.

## Reporting a problem

Open an issue with: the SADROG version and build (menu SADROG → About), the macOS version and Mac model, what you did, what you expected and what happened. The diagnostic log is at `~/Library/Logs/SADROG.log`; it holds no passwords and no file contents, but read it before you attach it.

Do not attach private recordings. If a file is needed to reproduce the problem, attach one you are allowed to publish, or describe how to make it (size, frame rate, sources).

## Pull requests

1. Fork, create a branch, make the change.
2. Run `swift test`. All tests must pass. Add or update tests for what you changed; tests generate their own synthetic media.
3. Keep the change focused. Do not reformat code you are not changing.
4. Describe in the pull request what changes for the user and how you checked it.

Rules that are checked in review:

- **No recordings of real screens or people, no keys, certificates, tokens or personal data** in the repository, in tests or in fixtures.
- **The preview and the exported file must match.** A change in the picture or sound path needs a test that compares them.
- **Nothing is degraded silently.** When an operation cannot be done as asked (copy without re-encoding, a missing source, a full disk), the app refuses and says why.
- **Storage.** Recordings, caches and exports go to the destination chosen by the user, never to the system disk as a fallback.
- **Interface texts.** The source text is Romanian; add the English and Spanish translations in `Localization/catalog.tsv` (`scripts/l10n_check.py` checks coverage). Icon-only controls need a hover explanation and an accessibility label.
- **Project format.** A change in what a project file stores raises the format number, keeps older projects opening unchanged, and comes with a test.
- **Dependencies.** A new dependency needs a licence compatible with GPL-3.0-or-later and a row in `docs/PROVENANCE.md`. Do not copy code whose licence you have not checked.
- **Documentation.** A change in behaviour is described in `CHANGELOG.md`; the manuals and the product page are updated by the maintainer from it.

## Authorship and licence of contributions

- By submitting a contribution you agree that it is licensed under **GPL-3.0-or-later**, the licence of the project, and you confirm that you have the right to submit it.
- Commits must be authored by the person responsible for them, with a real name or a consistent pseudonym and a working e-mail address. `Co-authored-by` trailers are for people who actually co-wrote the change.
- Contributors are credited in [CONTRIBUTORS.md](CONTRIBUTORS.md).

## Build

See [docs/BUILDING.md](docs/BUILDING.md).
