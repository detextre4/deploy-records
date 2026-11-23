# Security policy

## Reporting a vulnerability

Please don't open a public issue. Report it privately through
[GitHub's private vulnerability reporting](https://github.com/detextre4/deploy-records/security/advisories/new)
(Security → Report a vulnerability).

## Using this action safely

This action runs in your deploy job, usually next to signing keys and store
tokens, and with a token that can push tags. Pin it to a full commit SHA, not
to `@v1`:

```yaml
- uses: detextre4/deploy-records@<40-char commit sha> # v1.6.0
```

A tag can be moved; a commit SHA can't. Get the SHA of a release with
`gh api repos/detextre4/deploy-records/commits/v1.6.0 -q .sha`, and let
Dependabot (`package-ecosystem: github-actions`) keep it up to date.

Give the job only what the records you enable need: `contents: write` for
`tag`, `release` or `branch`; nothing beyond `contents: read` for a
summary-only run (`tag: none`).
