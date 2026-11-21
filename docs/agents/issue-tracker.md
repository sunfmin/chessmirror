# Issue tracker: factorium

Issues for this repo live in factorium's local tracker, not GitHub. `<checkout>` is this repo's
name in `factorium checkout list`: `chessmirror`.

- **Create an issue**: `factorium issue add chessmirror "<title>" --body-file - [--blocked-by <n> …]`,
  the body on stdin. Give its dependencies when it is filed: an issue is picked up as soon as it is
  ready.
- **Read an issue**: `factorium issue show chessmirror <n>`.
- **List issues**: `factorium issue list chessmirror`.
- **Comment on an issue**: `factorium issue comment chessmirror <n> "<text>"`.
- **Blocking**: `factorium issue block chessmirror <n> --by <m>`; an issue of another checkout is
  `<checkout>#<n>`.

There are no labels.

## When a skill says "publish to the issue tracker"

File a factorium issue.

## When a skill says "fetch the relevant ticket"

Run `factorium issue show chessmirror <n>`.
