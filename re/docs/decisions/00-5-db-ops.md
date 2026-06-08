# 0.5 — Database Operations: Self-Hosted Postgres on Hetzner vs Managed (Neon / Supabase)

- **Status:** Accepted
- **Date:** 2026-06-08
- **Decision owner:** planning-agent (`planning-agent-08d7cf`)
- **Bead:** `super-14w` (E0 Discovery — Open Decisions → `super-0r0`)
- **Affects:** E15 Deploy (`super-neps`, esp. `super-rivd` 15.3 Production Postgres, `super-nwko` 15.2 orchestration) · E14 Security/Observability/Backup-DR (`super-kh58`, esp. `super-y3a5` 14.3 backups + restore drills) · E2 Phoenix Core (`super-ieg` 2.1 Ecto+Postgres, `super-3vv` 2.4 Oban) · E6 Media (`super-8mu` 6.4 Hetzner Object Storage for backups)
- **Spec:** §11 (Deployment); bead also cites §16 — see *Notes* (the current 14-section build spec has no §16)

---

## Context

This is the greenfield real-estate platform **newprojects.ma** (Morocco market, new-build /
off-plan developments). Hosting is **already decided: Hetzner** (EU datacenters —
Nuremberg / Falkenstein in Germany, Helsinki in Finland). **Hetzner offers no managed
Postgres**, so we must choose the database *operations model*:

- **Self-host Postgres** on Hetzner (Docker or direct install), with our own backups /
  WAL archiving to object storage; or
- **Managed Postgres** from an external provider — **Neon** (serverless) or **Supabase**.

### Constraints that frame the choice

- **Solo developer, no hard deadline** — there is time to set self-hosting up properly,
  but the steady-state must be sustainable for *one* person.
- **Cost-sensitive startup** — recurring fees and traffic-scaled usage billing matter.
- **Morocco → EU latency** — the relevant hop for the DB is **app ↔ database**, not
  end-user ↔ database (see below). Hetzner's German DCs are the closest to Morocco.
- **Operationally sustainable for one person** — the decisive constraint. The real risk
  for a solo operator is not the monthly bill; it is the *2 a.m. failure mode* (disk full,
  botched major-version upgrade, an untested/corrupt backup, a security misconfiguration).

### What actually talks to the database (this de-risks the whole decision)

The public site is an **Astro 6 `output:'static'` build served from Cloudflare's edge**
(decision 0.4), with media and map tiles on R2. **Public read traffic does not hit
Postgres** — it hits the CDN. The database serves only:

- the **authenticated developer/admin panel** (Phoenix LiveView / SSR — low traffic,
  latency-tolerant from the *user's* perspective, but chatty in *queries-per-page*);
- **Oban** background queues (`super-3vv`), which **poll Postgres frequently** and benefit
  from a low-latency connection;
- the **read API → rebuild pipeline** (E5/E9) and **search** (Postgres FTS first, per 0.4) —
  batch-ish, latency-tolerant.

Two consequences fall out of this profile:

1. **A brief DB outage does not take the public site down** — the static catalog keeps
   serving from the CDN. The DB's availability is decoupled from the public SEO surface.
2. **The DB is small, low-QPS, and not on the public hot path**, which makes self-hosting
   *low-risk* and makes the managed providers' premium features (autoscaling, serverless
   compute) largely unnecessary.

### The roadmap already leans self-host

The supporting work is already planned as first-class tasks, which removes the scariest
part of self-hosting from the "unknown" column:

- `super-rivd` (15.3): *"Production Postgres (**self-host + backups**, or managed per E0)."*
- `super-y3a5` (14.3): *"Postgres backups (**pgBackRest/WAL-G → object storage**) + **restore
  drills (RTO/RPO)**."*
- `super-8mu` (6.4): *"**Hetzner Object Storage for backups**."*

This ADR exists to **rigorously validate that lean, quantify the trade-offs, and define an
explicit escape hatch to managed** so we are not betting the data layer on perfect ops.

---

## Options Considered

### Option A — Self-host Postgres on Hetzner, co-located with the app ✅ chosen

Run PostgreSQL on Hetzner in the **same region / private network as the Phoenix app**.

- **Topology (staged):** *launch* — co-located on the application VPS (one box, fewest
  moving parts, €0 extra compute). *Growth* — split Postgres onto its **own Hetzner
  instance on the private network** (vSwitch) for resource isolation, still sub-millisecond.
- **Install:** managed by the chosen deploy orchestrator (`super-nwko` — Coolify can run a
  Postgres service with scheduled backups; Kamal via an accessory) **or** a direct PGDG
  apt install under systemd. *Principle:* the data directory lives on **durable host
  storage (a Hetzner Volume)**, never an ephemeral container layer; the major version is
  **pinned**.
- **Backups / DR:** **pgBackRest or WAL-G → Hetzner Object Storage (EU)** for continuous
  WAL archiving (RPO ≈ seconds–minutes) + a **nightly `pg_dump`** as a portable,
  restore-tested second layer (worst-case loss < 24 h, restorable *anywhere* — including
  into a managed provider, which preserves the escape hatch). Hetzner server/volume
  snapshots are a convenient *secondary* layer, not the primary.
- **Pooling:** Ecto holds a **fixed connection pool per BEAM node** — Elixir does *not*
  open a connection per request, so the serverless connection-exhaustion problem does not
  apply. A direct connection to co-located Postgres is the simplest, best fit; PgBouncer
  (transaction mode) is added only if/when multiple app nodes appear.
- **➕** Cheapest at scale; **sub-millisecond app↔DB latency**; no vendor lock-in (vanilla
  Postgres, trivially portable); no pooler/prepared-statement gotcha; consistent with the
  platform's self-host / own-your-data philosophy (Nominatim, PMTiles-on-R2, Oban).
- **➖** We own patching, **major-version upgrades**, monitoring, and — above all — the
  **backup/restore discipline**. Single-box launch topology shares fate/resources between
  app and DB until split.

### Option B — Neon (managed serverless Postgres, Frankfurt) — the escape hatch

Serverless Postgres on AWS `eu-central-1` (Frankfurt); compute/storage separated; instant
branching and built-in PITR.

- **➕** Zero OS/patching/upgrade burden; backups, **PITR and branching included**;
  generous dev free tier; "just Postgres" — the cleanest managed fit for a Phoenix app
  (no redundant app layer). Frankfurt keeps app↔DB latency acceptable (~3–15 ms).
- **➖** ~$19/mo floor (Launch) once you **disable autosuspend** to avoid cold-start
  latency, + usage that grows with traffic; a **cross-provider/network hop** (Hetzner →
  AWS) multiplied by queries-per-request; reintroduces a vendor and recurring fee the
  Hetzner choice was partly meant to avoid. (Use Neon's **direct/unpooled** endpoint with
  Ecto, since Ecto already pools — which negates much of the serverless-pooler value-add.)

### Option C — Supabase (managed Postgres platform, Frankfurt) ❌ not chosen

Postgres + Auth + Storage + Realtime + auto REST/GraphQL on `eu-central-1`.

- **➖** Its platform value-add (Auth, Storage, Realtime, PostgREST, client SDKs) is
  **redundant with what Phoenix already provides** — we'd pay for a platform and use ~20%
  of it. **Free tier pauses after ~1 week of inactivity** (unsuitable for production); Pro
  is ~$25/mo and **PITR is a steep paid add-on (~$100/mo)** — poor fit for DR-on-a-budget.
- If managed is ever chosen, **Neon (Option B) is the better managed fit** for this stack.

> **Honorable mentions (set aside):** *Crunchy Bridge*, *Aiven*, and *DigitalOcean Managed
> Postgres* all offer vanilla managed Postgres in Frankfurt and are arguably better "pure
> managed Postgres" than Supabase for a Phoenix app. They are viable alternatives **within
> the managed category** if the escape hatch is ever taken; Neon is named as the default
> fallback for its branching + generous free tier.

---

## Cost Comparison (order-of-magnitude; **verify current pricing before launch**)

> ⚠️ Provider pricing changes. Figures are approximate (≈ mid-2026) and meant to show
> *structure*, not to be quoted. The DB here is **small and low-QPS** (the public site is
> static/CDN), so we live at the bottom of every pricing curve.

| Stage | Self-host on Hetzner (chosen) | Neon (Frankfurt) | Supabase (Frankfurt) |
|---|---|---|---|
| **Launch** (small DB, low QPS) | **~€6/mo** — co-located on the app VPS (≈ €0 extra compute) + backups to Hetzner Object Storage (~€6/mo, 1 TB bucket) | Free tier = dev only (scale-to-zero cold starts); **~$19/mo** (Launch) for always-warm prod + usage | Free tier **pauses** (unsuitable) → **~$25/mo** (Pro) + usage |
| **Growth** (dedicated DB box) | **~€15–25/mo** all-in — CX32/CCX (~€7–14) + Volume (~€4) + backups (~€6) | ~$19–69/mo + compute-hours + storage; PITR/branching included | ~$25/mo + usage; **PITR add-on ~$100/mo** |
| **Scale** | Vertical scale on Hetzner's cheap €/vCPU·€/GB curve; **flat-ish, predictable** | **Usage-based — grows with success** (compute-hours + storage) | Usage-based + stacked add-ons |

**Structural takeaway:** the launch-day *dollar* delta is modest (~€6/mo vs ~$19–25/mo) —
so cost alone is **not** the decisive factor. The decision rests more on **latency
(co-location), platform-philosophy consistency, Ecto fit, and avoiding lock-in / usage-
billing that grows precisely when the product succeeds.** Self-host's cost advantage
widens at scale; managed's advantage is *ops offload*, not price.

---

## Decision

**Self-host PostgreSQL on Hetzner**, co-located in the same region / private network as the
Phoenix application (Option A) — **conditional on the non-negotiable backup/DR guardrails
below**. Start **co-located on the app VPS** at launch; **split to a dedicated Hetzner DB
instance** on the private network when load or operational isolation warrants. Back up via
**pgBackRest/WAL-G → Hetzner Object Storage** (continuous WAL) **plus a nightly `pg_dump`**,
with **restore drills** against documented **RTO/RPO** targets (`super-y3a5`).

### Mandatory guardrails (the decision is conditional on these)

1. **Automated, monitored backups** — continuous WAL archiving **and** nightly logical
   dumps to Hetzner Object Storage (EU); alert if a backup does not complete.
2. **Tested restores** — a **documented restore runbook** and a **quarterly restore drill**
   that verifies RTO/RPO. *An untested backup is not a backup.* (Tracked by `super-y3a5`.)
3. **No public exposure** — Postgres bound to the private network only; firewalled; TLS;
   strong auth. The API subdomain stays behind the Cloudflare proxy (`super-v7c`/`super-e41o`).
4. **Pinned major version + planned upgrade procedure** — no deadline pressure means
   upgrades are scheduled, rehearsed (restore-from-backup as the rollback), and low-risk.
5. **Disk + DB monitoring** — disk-space, replication/WAL, and connection metrics wired
   into E14 observability (Phoenix LiveDashboard + exporter/alerts) from day one.

### Escape hatch (explicit, pre-approved) → managed Neon (Frankfurt)

Because backups include **portable logical dumps**, migrating to managed is a
`pg_dump`/`pg_restore` away — no rewrite. **Switch to Neon (Frankfurt; Supabase only if its
extras are wanted)** if **any** of these hold:

1. The **backup/restore discipline cannot be sustained** (drills slip, alerts ignored) —
   then *buying* DR is the right call;
2. **HA / automatic failover** becomes a hard requirement (managed handles it);
3. The DB **outgrows comfortable single-operator ops** (size, QPS, or tuning burden);
4. The solo developer's time is **better spent on product** than on part-time DBA work.

If self-hosting were *not* viable for any reason at launch, **Neon is the chosen
fallback** — not Supabase.

---

## Rationale

- **Latency favors co-location, where it matters.** The public site is static (CDN), so DB
  latency never touches public UX. But the **admin/LiveView panel, Oban polling, and the
  rebuild/search path** issue many small queries; co-located Postgres answers in **< 1 ms**
  vs **~3–15 ms** to managed-in-Frankfurt — and that hop is paid *per query, per request*.
- **Ecto/Phoenix is the ideal self-host client.** A fixed BEAM connection pool sidesteps
  the serverless connection-exhaustion problem and the PgBouncer/Supavisor
  prepared-statement gotcha that bites managed Postgrex users. Managed pooling buys us
  little here.
- **The scariest risk is already a planned, owned task.** DR is not hypothetical — it is
  `super-y3a5` (pgBackRest/WAL-G + restore drills + RTO/RPO) with a backup target already
  provisioned (`super-8mu`). The guardrails above make the conditional explicit.
- **Cost is predictable and flat;** managed usage billing grows with success. The launch
  delta is small, but the *shape* of the curve favors self-host as the catalog and traffic
  grow.
- **No lock-in; full portability.** Vanilla Postgres keeps the escape hatch cheap and keeps
  us off a vendor's roadmap/pricing.
- **Consistency with the platform's established philosophy.** Self-host / own-your-data /
  avoid per-request lock-in already governs the other decisions (PMTiles-on-R2 in 0.6,
  self-hosted Nominatim, Phoenix/Oban on Hetzner). Self-hosting Postgres is the coherent
  choice — *provided* we honor the DR discipline that makes it safe for a solo operator.

## Consequences

**Positive**

- Lowest, most predictable cost; **sub-millisecond app↔DB latency** for admin/Oban/rebuild.
- No vendor lock-in; data trivially portable (and the escape hatch stays a `pg_dump` away).
- One fewer external dependency/billing relationship; consistent ops story on Hetzner.
- Public-site availability is **decoupled** from the DB (static CDN survives DB blips).

**Negative / costs we accept**

- We own **patching, monitoring, and major-version upgrades** (plannable; no deadline).
- **Backup/restore discipline is on us** — mitigated by the mandatory guardrails + `super-y3a5`.
- **Launch single-box topology** shares fate/resources between app and DB — mitigated by
  static-site decoupling and the documented split-to-dedicated-box growth step.
- No built-in HA/failover at launch — accepted for a listing platform whose public surface
  is static; revisit via the escape hatch if HA becomes a hard requirement.

**Follow-ups to wire into the roadmap**

- **E15 / `super-rivd` (15.3):** update to read **"self-host Postgres on Hetzner"** (drop
  the "or managed" fork); scope = provision DB (co-located → dedicated), durable Volume,
  TLS/private-network binding, version pinning, upgrade runbook. *(This is the
  "E15 DB tasks updated" half of this bead's acceptance criteria.)*
- **E14 / `super-y3a5` (14.3):** confirm pgBackRest/WAL-G → Hetzner Object Storage + nightly
  `pg_dump`; define RTO/RPO; schedule the **quarterly restore drill**; alert on backup failure.
- **E6 / `super-8mu` (6.4):** ensure the backups bucket (Hetzner Object Storage, EU) is
  provisioned with appropriate retention/lifecycle.
- **E15 / `super-nwko` (15.2):** if Coolify is chosen, use its managed-Postgres service +
  scheduled backups; if Kamal, run Postgres as a long-lived service with data on a durable
  Volume (not an accessory tied to the app's lifecycle).
- **E2 / `super-3vv` (2.4):** Oban runs against the co-located DB; keep the Ecto pool sized
  for web + Oban queues.
- **Config:** keep the DB connection string in one env/secret value (`super-pv4`/`super-k49j`)
  so the escape hatch to Neon is a config change, not a code change.

---

## Notes

- **Spec reference:** bead `super-14w` cites *"§11, §16."* §11 (Deployment) governs this
  decision. As flagged in ADR 0.4, the current 14-section build spec
  (`newprojects.ma-build-spec.md`) appears to have **no §16** — flag for the orchestrator if
  a longer canonical spec exists.
- **Backup target:** Hetzner Object Storage (EU) is the primary per `super-8mu` and ADR 0.6;
  Cloudflare R2 ($0 egress) is a viable alternative/secondary for restore-heavy DR.
- This decision is intentionally **reversible**: the portable nightly dump + vanilla
  Postgres mean the managed escape hatch can be taken at any time with minimal effort.

## References

- Beads: `super-14w` (this decision), `super-0r0` (E0), `super-neps`/`super-rivd`/`super-nwko`
  (E15), `super-kh58`/`super-y3a5` (E14), `super-ieg`/`super-3vv` (E2), `super-8mu` (E6).
- Hetzner: Cloud servers, Volumes, Object Storage (S3-compatible, EU), private networking.
- pgBackRest / WAL-G (continuous WAL archiving to S3-compatible object storage).
- Neon (serverless Postgres, branching, PITR; AWS `eu-central-1`); Supabase (Pro, PITR add-on).
- Ecto/Postgrex connection pooling; PgBouncer/Supavisor transaction-mode prepared-statement caveat.

## Acceptance criteria (bead `super-14w`)

- [x] Decision recorded with **ops/cost trade-off** (this ADR).
- [ ] **E15 DB tasks updated** — `super-rivd` (15.3) to be edited to "self-host" (drop the
  managed fork); see *Follow-ups*. **Recommend completing this edit before closing the bead.**
