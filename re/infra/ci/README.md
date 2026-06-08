# CI/CD Skeleton

## Pipeline Overview

```text
Developer pushes to main
         │
         ├── frontend/** changed
         │         │
         │         ▼
         │   GitHub Actions: frontend.yml
         │   ├── npm ci
         │   ├── npm run build
         │   └── npm test
         │         │
         │         ▼
         │   Cloudflare Git Integration (auto-deploy)
         │   Workers Static Assets ← preview/prod URL
         │
         └── backend/** changed
                   │
                   ▼
             GitHub Actions: backend.yml
             ├── mix deps.get
             ├── mix compile
             ├── mix test
             ├── docker build
             └── docker push → ghcr.io/<org>/immo-backend
                       │
                       ▼
                 [PLACEHOLDER] Hetzner VPS deploy
                 SSH → docker pull → restart container
```

## GitHub Actions Secrets

Backend container registry access does not require extra secrets when pushing from the same repository, but Hetzner deployment will need the following once the server is provisioned:

- `HETZNER_HOST` — server IP or hostname
- `HETZNER_USER` — SSH user (e.g., `root`)
- `HETZNER_SSH_KEY` — private SSH key
- `HETZNER_PORT` — SSH port
- `DATABASE_URL` — Postgres connection string
- `SECRET_KEY_BASE` — Phoenix secret key base

Frontend deployment uses Cloudflare Git Integration and does not require GitHub secrets for deployment.

## Cloudflare Git Integration (Frontend)

1. In Cloudflare Dashboard → Workers & Pages → select the frontend project.
2. Connect the GitHub repository and branch (`main`).
3. Set the build output directory to `frontend/dist` (adjust if Astro outputs elsewhere).
4. Configure environment variables in the Cloudflare project settings if needed.

Cloudflare builds and deploys automatically on every push to `main`. Preview URLs are available through Cloudflare Deployments.
