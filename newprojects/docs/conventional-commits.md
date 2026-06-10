# Conventional Commits

This monorepo follows [Conventional Commits](https://www.conventionalcommits.org/).

## Format

```
type(scope): short description

[optional body]

[optional footer(s)]
```

## Types

- `feat` — new feature
- `fix` — bug fix
- `docs` — documentation only
- `chore` — tooling, deps, CI
- `refactor` — code change without behavior change
- `test` — tests only
- `perf` — performance improvement

## Scopes (examples)

`backend`, `frontend`, `infra`, `docs`, `ci`

## Examples

- `feat(backend): add Catalog context schema`
- `fix(frontend): correct hreflang on listing pages`
- `chore(ci): wire Dialyzer cache`
