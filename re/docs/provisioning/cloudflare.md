# Cloudflare Provisioning Guide

> **Bead:** `super-qjo` (1.1 — Provision Cloudflare: Workers Static Assets, R2, DNS, Turnstile)
> **Audience:** the solo developer, working by hand in the Cloudflare dashboard.
> **Scope:** this is a manual, click-through runbook. It deliberately does **not**
> automate anything with the Cloudflare API — do each step in the dashboard and
> record the resulting IDs/keys in your secrets manager (see [Secrets](#7-secrets--where-each-value-goes)).

This platform is a greenfield real-estate listing site targeting **Morocco**.
Cloudflare provides four things for us:

1. **Workers Static Assets** — hosts the Astro static frontend (auto-deploy from GitHub).
2. **R2** — object storage for listing **media** and for map **PMTiles** (ADR `00-6`).
3. **DNS** — authoritative zone for the launch domain, with proxy/SSL.
4. **Turnstile** — privacy-friendly anti-bot for inquiry forms (ADR `00-2`: no public
   visitor accounts at launch, so the inquiry form is the main abuse surface).

Relevant E0 decisions:

- **ADR 00-6 (Map tiles):** PMTiles served from R2 behind a Cloudflare-cached custom
  domain, rendered by MapLibre GL JS. Needs CORS + HTTP range + Cache Rules.
- **ADR 00-2 (Visitor accounts):** no public accounts at launch → Turnstile guards the
  inquiry form and any unauthenticated POST endpoints.
- **ADR 00-3 (Locales):** FR + EN at launch (RTL-ready). Relevant mainly to the basemap
  label language, not to provisioning itself.

> **Placeholders used in this guide.** Replace consistently:
> - `newprojects.ma` → the real launch domain (apex).
> - `immo-media` / `immo-tiles` → R2 bucket names (keep or rename, but be consistent).
> - `<ACCOUNT_ID>` → your Cloudflare account ID (Dashboard → right sidebar).

---

## 0. Prerequisites

- A Cloudflare account (free plan is sufficient to start; R2 requires adding a payment
  method even though usage starts near $0).
- Owner/admin access to the domain registrar for `newprojects.ma` (to change
  nameservers, or to delegate DNS).
- The GitHub repo for the Astro frontend, with a working `npm run build` that emits to
  `dist/`.
- A secrets manager / `.env` strategy already chosen (see bead `super-pv4`,
  "Secrets & env management").

Record your **Account ID** now: Dashboard → any zone → right sidebar → **Account ID**.

---

## 1. Workers Static Assets project (frontend host)

> **Why Workers Static Assets and not Pages?** Cloudflare **Pages is in maintenance
> mode**; new static-hosting projects should use **Workers Static Assets**, which is the
> forward-looking host and shares the Workers platform (bindings, routing, future SSR if
> ever needed). Our frontend is Astro static output, so we use the assets-only mode.

### 1.1 Create the Worker from the GitHub repo

1. Dashboard → **Workers & Pages** → **Create** → **Workers** → **Import a repository**
   (or **Connect to Git**).
2. Authorize the Cloudflare GitHub App and select the frontend repository.
3. Choose the production branch: **`main`**.

### 1.2 Build settings

| Setting | Value |
|---|---|
| **Build command** | `npm run build` |
| **Deploy / output directory** | `dist/` |
| **Root directory** | repo root (or the Astro subdir if it's a monorepo — e.g. `apps/web`) |
| **Node version** | pin via `.nvmrc` or `NODE_VERSION` build var (e.g. `20`) |

For assets-only hosting, the project's `wrangler.toml` (committed to the repo) should
declare the assets directory, e.g.:

```toml
name = "immo-web"
compatibility_date = "2025-01-01"

[assets]
directory = "./dist"
# SPA/MPA fallback: Astro is multi-page, so prefer 404-style handling.
not_found_handling = "404-page"
```

> Astro emits per-route HTML, so use `404-page` (serve `dist/404.html`) rather than
> `single-page-application`. If you later add Astro SSR, switch this Worker to a
> `main` entrypoint with the assets binding instead of assets-only.

### 1.3 Auto-deploy

Once connected to Git, Cloudflare builds and deploys on every push to `main`, and
creates **preview deployments** for pull requests. Verify the first deploy succeeds and
note the generated `*.workers.dev` URL.

> This overlaps with bead `super-ivn` (1.5 CI/CD skeleton). Cloudflare's Git integration
> handles the deploy; GitHub Actions handles tests/linting/PMTiles generation. Keep the
> two concerns separate.

### 1.4 Custom domain

1. Workers & Pages → your Worker → **Settings → Domains & Routes** → **Add → Custom domain**.
2. Add the apex `newprojects.ma` and/or `www.newprojects.ma`.
3. Cloudflare auto-creates the proxied DNS records and issues the edge certificate when
   the zone (Section 3) is active.

Decide the canonical host (apex vs `www`) and 301-redirect the other (a Cloudflare
**Redirect Rule**: `www.newprojects.ma/*` → `https://newprojects.ma/$1`, or vice versa).

---

## 2. R2 buckets (media + tiles)

> **Why R2:** $0 egress and an S3-compatible API. Media is uploaded by the Phoenix
> backend; tiles are a single near-static PMTiles archive (ADR 00-6).

R2 needs a payment method on file. Enable R2: Dashboard → **R2** → follow the prompts.

### 2.1 Create the buckets

Dashboard → **R2** → **Create bucket** (do this twice):

| Bucket | Purpose | Location hint |
|---|---|---|
| `immo-media` | Listing photos & uploads (written by Phoenix backend) | EU (e.g. `EEUR`) — close to Hetzner/Morocco |
| `immo-tiles` | `morocco.pmtiles` basemap + future tile assets (ADR 00-6) | EU (`EEUR`) |

> Keeping media and tiles in **separate buckets** lets you give the backend a token
> scoped to media only, and expose tiles publicly/cached without touching media.

### 2.2 R2 API token for the Phoenix backend (media upload)

1. R2 → **Manage R2 API Tokens** → **Create API Token**.
2. Permissions: **Object Read & Write**.
3. Scope: **Apply to specific buckets only → `immo-media`** (least privilege — do **not**
   grant account-wide R2 access).
4. TTL: as long-lived as your rotation policy allows; record an expiry/rotation reminder.
5. Save the generated **Access Key ID**, **Secret Access Key**, and the
   **S3 endpoint** `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.

These go into the **Phoenix backend env** (see Section 7).

### 2.3 CORS for direct upload from the admin UI

If the admin UI uploads directly to R2 via presigned URLs (recommended — keeps large
uploads off the Phoenix server), `immo-media` needs a CORS policy.

R2 → `immo-media` → **Settings → CORS Policy** → add:

```json
[
  {
    "AllowedOrigins": [
      "https://admin.newprojects.ma",
      "https://newprojects.ma"
    ],
    "AllowedMethods": ["PUT", "POST", "GET", "HEAD"],
    "AllowedHeaders": ["content-type", "content-length", "x-amz-*"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3600
  }
]
```

> **Restrict `AllowedOrigins` to your real admin/site origins.** Never ship `"*"` to
> production — it lets any site initiate cross-origin uploads against presigned URLs.
> For local dev, add `http://localhost:4321` (Astro) / `http://localhost:4000`
> (Phoenix) in a **dev-only** policy, not in production.

### 2.4 Public access for tiles (`immo-tiles`)

The PMTiles basemap is shared, non-sensitive, and benefits hugely from edge caching.
Expose it through a **custom domain** (not the `r2.dev` dev URL, which is rate-limited
and not for production):

1. R2 → `immo-tiles` → **Settings → Public access → Custom Domains** → **Connect Domain**
   → `tiles.newprojects.ma`. This creates a proxied CNAME in the zone and serves the
   bucket through Cloudflare's cache.
2. **CORS on `immo-tiles`** (MapLibre fetches tiles cross-origin from the site):

```json
[
  {
    "AllowedOrigins": [
      "https://newprojects.ma",
      "https://www.newprojects.ma"
    ],
    "AllowedMethods": ["GET", "HEAD"],
    "AllowedHeaders": ["range", "if-match", "content-type"],
    "ExposeHeaders": ["content-length", "content-range", "etag", "accept-ranges"],
    "MaxAgeSeconds": 86400
  }
]
```

3. **HTTP Range requests** must work — PMTiles relies on them. R2 supports `Range`
   natively; just ensure your CORS exposes `content-range`/`accept-ranges` (above) and
   that no Transform Rule strips the `Range` header.

4. **Cache Rules** (Dashboard → zone → **Caching → Cache Rules**) for the tiles host so
   repeat range reads are edge-served:
   - **When:** `Hostname equals tiles.newprojects.ma`
   - **Then:** *Eligible for cache* + **Edge TTL** ~ 1 month (basemaps are near-static)
     + **Respect range requests / cache by range** enabled.

The final tile-source URL the frontend uses is:
`pmtiles://https://tiles.newprojects.ma/morocco.pmtiles`
— kept behind **one config/env value** so the source can be swapped per ADR 00-6's
escape hatch.

> **Media public delivery (optional, parallel concern):** if listing photos are served
> publicly, give `immo-media` its own custom domain (e.g. `media.newprojects.ma`) with
> its own Cache Rules. Keep write tokens private regardless. This may be handled under
> E6 (`super-w7z`); cross-link rather than duplicate.

---

## 3. DNS zone

### 3.1 Add the domain

1. Dashboard → **Add a site** → enter `newprojects.ma` → choose a plan (Free is fine).
2. Cloudflare scans existing records; review the import.
3. At the registrar, replace the nameservers with the two Cloudflare nameservers shown.
   Wait for the zone status to flip to **Active** (minutes to ~24h).

### 3.2 Records

Once the Worker custom domain (1.4) and R2 custom domains (2.4) are attached, Cloudflare
manages most records automatically. The baseline set:

| Type | Name | Content | Proxy |
|---|---|---|---|
| A | `@` (apex) | `192.0.2.1` placeholder — auto-managed by the Worker custom domain | 🟠 Proxied |
| AAAA | `@` | `100::` placeholder — auto-managed by the Worker custom domain | 🟠 Proxied |
| CNAME | `www` | `newprojects.ma` (or the Worker) | 🟠 Proxied |
| CNAME | `tiles` | auto-created by R2 custom domain | 🟠 Proxied |
| CNAME | `media` | auto-created by R2 custom domain (if used) | 🟠 Proxied |
| CNAME / A | `admin` | Phoenix backend host (Hetzner) | 🟠 Proxied |
| MX / TXT | as needed | email provider, SPF/DKIM/DMARC | ⚪ DNS-only |

> When you attach a Worker or R2 bucket to a custom domain, Cloudflare inserts the
> correct apex/CNAME records for you — you rarely hand-edit the A/AAAA for the Worker.
> **Email (MX) and verification (TXT) records must be DNS-only (grey cloud).**

### 3.3 Proxy status

- **Orange cloud (Proxied)** for all web/HTTP hosts (apex, www, tiles, media, admin) —
  this is what gives DDoS protection, the edge cache, WAF, and hides origin IPs.
- **Grey cloud (DNS-only)** for non-HTTP records (MX, mail, verification TXT).

### 3.4 SSL/TLS

1. Zone → **SSL/TLS → Overview** → set encryption mode to **Full (strict)**.
   - **Full (strict)** requires a valid cert on the origin. The Hetzner Phoenix origin
     should present a real cert (Let's Encrypt) or a Cloudflare **Origin Certificate**.
   - If the origin isn't ready for a trusted cert on day one, **Full** is the temporary
     floor — **never use Flexible** (it leaves origin↔Cloudflare unencrypted).
2. **Edge Certificates:** enable **Always Use HTTPS** and **Automatic HTTPS Rewrites**;
   set **Minimum TLS Version 1.2**; enable **HSTS** once you're confident (it's sticky).

---

## 4. Turnstile (anti-bot for inquiry forms)

Per ADR 00-2 there are no public visitor accounts at launch, so the **inquiry form** (and
any unauthenticated POST) is the main spam/abuse surface. Turnstile protects it without
the privacy/UX cost of reCAPTCHA.

### 4.1 Create a Turnstile site

1. Dashboard → **Turnstile** → **Add site**.
2. **Site name:** `immo-inquiry` (or similar).
3. **Domains:** `newprojects.ma`, `www.newprojects.ma` (add `localhost` only for a
   dev-scoped widget — see note below).
4. **Widget mode:** **Managed** is the safe default; choose **Invisible** if you want zero
   user interaction (it still challenges suspicious traffic). Pick one and keep it
   consistent in the frontend.
5. Save. You now have a **Site Key** (public) and a **Secret Key** (private).

> Consider a **separate Turnstile site for local development** (with `localhost` in its
> domain list) so you never put `localhost` on the production widget. Cloudflare also
> publishes well-known **test keys** for automated tests.

### 4.2 Where the keys go

| Key | Visibility | Destination | Used for |
|---|---|---|---|
| **Site Key** | public (ships in HTML/JS) | **Astro frontend env** (`PUBLIC_TURNSTILE_SITE_KEY`) | renders the widget on the inquiry form |
| **Secret Key** | secret (never in frontend) | **Phoenix backend env** (`TURNSTILE_SECRET_KEY`) | server-side `siteverify` of the submitted token |

Flow: the Astro form renders the widget with the site key → user submits → the token is
sent to Phoenix → Phoenix POSTs token + secret to
`https://challenges.cloudflare.com/turnstile/v0/siteverify` → accept the inquiry only on
`success: true`. **Never** verify on the client.

### 4.3 Domain restrictions

The widget only solves on the domains listed in 4.1.3, and `siteverify` is bound to your
secret — so a leaked site key can't be reused on another domain. Keep the production
widget's domain list tight (no `localhost`, no wildcards).

---

## 5. Security checklist

Run through this before go-live and at each rotation.

### 5.1 API token permissions (least privilege)

- [ ] R2 backend token is **Object Read & Write**, scoped to **`immo-media` only** — not
      account-wide, not including `immo-tiles`.
- [ ] No single token has both R2 admin and zone-edit rights. Separate tokens per concern.
- [ ] Cloudflare API tokens (if any, e.g. for CI cache purge) use **scoped templates**,
      not the Global API Key. Set expirations and rotation reminders.
- [ ] All keys (R2 access/secret, Turnstile secret, API tokens) live in the secrets
      manager (`super-pv4`), never committed to git.

### 5.2 R2 bucket CORS

- [ ] `immo-media` CORS `AllowedOrigins` lists **only** the admin/site origins (no `"*"`).
- [ ] `immo-tiles` CORS `AllowedOrigins` lists **only** the public site origins; methods
      limited to `GET`/`HEAD`.
- [ ] Dev origins (`localhost:*`) appear only in dev-scoped policies, never production.
- [ ] Media write path uses **presigned URLs** with short expiry, not a public-writable
      bucket.

### 5.3 Turnstile domain restrictions

- [ ] Production widget's domain list excludes `localhost` and wildcards.
- [ ] Secret key is **only** in the Phoenix env; site key is the only key in the frontend.
- [ ] Server **always** calls `siteverify`; submissions without a valid token are rejected.

### 5.4 WAF & rate limiting

Zone → **Security → WAF**:

- [ ] **Managed Ruleset** enabled (Cloudflare's OWASP-style core rules).
- [ ] **Rate Limiting Rule** on the inquiry/API endpoints, e.g.
      *When* `http.request.uri.path contains "/api/inquiries"` and method `POST`
      → *limit* ~5 requests / 60s per IP → **Block** (or Managed Challenge).
- [ ] Rate-limit any other unauthenticated POST (search-heavy endpoints, auth, etc.).
- [ ] **Bot Fight Mode** (free) or Bot Management enabled at the zone level.
- [ ] Consider a **Country/ASN rule** if abuse clusters from unexpected origins (tune
      carefully — the audience is in Morocco and the diaspora).
- [ ] **Always Use HTTPS**, **Min TLS 1.2**, **SSL Full (strict)** confirmed (Section 3.4).
- [ ] Origin (Hetzner) firewall accepts traffic **only** from Cloudflare IP ranges, so the
      proxy can't be bypassed by hitting the origin IP directly.

---

## 6. Verification (smoke test the provisioning)

- [ ] `https://newprojects.ma` serves the Astro build; pushing to `main` redeploys.
- [ ] A PR creates a working preview deployment.
- [ ] `https://tiles.newprojects.ma/morocco.pmtiles` returns `200`, honors a `Range`
      request (`curl -I -H "Range: bytes=0-99"` → `206 Partial Content`), and shows a
      Cloudflare cache `HIT` on the second request.
- [ ] The Phoenix backend can PUT an object to `immo-media` with its scoped token.
- [ ] A browser cross-origin `fetch` of a tile from `newprojects.ma` succeeds (CORS OK).
- [ ] The inquiry form renders the Turnstile widget; a real submit passes `siteverify`;
      a forged/missing token is rejected by Phoenix.
- [ ] SSL Labs / `curl -vI` shows Full (strict), TLS ≥ 1.2, HTTPS forced.

---

## 7. Secrets — where each value goes

Record every value below in the secrets manager (`super-pv4`). **Nothing here goes in git.**

| Value | Source | Destination env |
|---|---|---|
| `CLOUDFLARE_ACCOUNT_ID` | Dashboard sidebar | CI / both apps as needed |
| R2 Access Key ID | R2 API token (media) | Phoenix backend |
| R2 Secret Access Key | R2 API token (media) | Phoenix backend |
| R2 S3 endpoint | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` | Phoenix backend |
| `R2_MEDIA_BUCKET` | `immo-media` | Phoenix backend |
| Tiles base URL | `https://tiles.newprojects.ma` | Astro frontend (one config value) |
| `PUBLIC_TURNSTILE_SITE_KEY` | Turnstile site | Astro frontend (public) |
| `TURNSTILE_SECRET_KEY` | Turnstile site | Phoenix backend (secret) |

---

## References

- ADR `00-6` — Map tiles (PMTiles on R2): `docs/decisions/00-6-map-tiles.md`
- ADR `00-2` — Visitor accounts (no public accounts → Turnstile on inquiry):
  `docs/decisions/00-2-visitor-accounts.md`
- ADR `00-3` — Locales/RTL (FR+EN at launch): `docs/decisions/00-3-locales-rtl.md`
- Beads: `super-qjo` (this task), `super-pv4` (secrets), `super-ivn` (CI/CD),
  `super-lth` (Hetzner), `super-w7z` (E6 R2/media).
- Cloudflare docs: Workers Static Assets, R2 (CORS, custom domains, presigned URLs),
  DNS/SSL-TLS, Turnstile, WAF & Rate Limiting. **Verify exact dashboard labels at
  provisioning time — Cloudflare's UI changes frequently.**
