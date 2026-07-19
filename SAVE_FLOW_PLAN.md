# Save / Snapshot Flow — Implementation Plan

Goal: saving a container tars its filesystem, stores it via **browseterm-storage** (local PVC or MinIO), a **Docker-daemon Job** picks it up, builds + pushes the image, and updates **Postgres**; a **save-status trigger** fires a NOTIFY that **browseterm-server** relays over **SSE** so the frontend stops the save spinner.

## Confirmed decisions
1. **Save state = columns on `containers`** (`save_status`, `save_error`, `last_saved_at`) — not a separate `jobs` table (v1).
2. **Secrets stay out of the gRPC proto.** `SaveContainerRequest` stays `{container_id, network_name}`. container-maker sources **DB creds + MinIO config from its own env/secret** and injects them into the Job.
3. **Reuse `/container-status-stream`** SSE with a typed event for save status (no new endpoint).
4. **Build with a Docker daemon in the Job** (docker CLI: pull/build/push). **Do NOT use kaniko** (tried, didn't work). The Job needs a reachable Docker daemon (host socket / privileged).
5. **browseterm-storage is the single storage abstraction** — remove the Job's duplicate retriever classes.

## Target flow
```
[Save click] → server POST /save-container → gRPC saveContainer(container_id, network_name)
  → container-maker: save_status=PENDING; tar fs → browseterm-storage.write (local|minio); create Docker-daemon Job
      → snapshot_job: save_status=RUNNING → browseterm-storage.read/download tar → docker build + push
           success → saved_image + save_status=SUCCEEDED + last_saved_at
           failure → save_status=FAILED + save_error
  → Postgres trigger on save_status change → NOTIFY 'container_save_status_change'
      → server PGListener → SSE (/container-status-stream, typed event) → frontend stops spinner
```

## Phases
- **A. browseterm-db:** add `SaveStatus` enum + `save_status`/`save_error`/`last_saved_at` columns; migration for columns; migration for `notify_container_save_status_change()` + trigger; `ContainerOps.update_save_status()`.
- **B. snapshot_job:** replace in-job retriever with `browseterm_storage.get_storage(...)`; write RUNNING→SUCCEEDED/FAILED via browseterm-db.
- **C. container-maker:** write tar via browseterm-storage (both backends); inject STORAGE_LAYER+MinIO+DB creds+CONTAINER_ID into the Job; set save_status=PENDING; **fix `PodManager.save()` signature bug**; (sep.) drop pod-level `privileged=True`.
- **D. browseterm-server:** add `POST /save-container` → gRPC saveContainer; PGListener on `container_save_status_change`; relay via SSE; frontend spinner stop.
- **E. MinIO infra (monorepo):** deploy MinIO + bucket + creds secret; `STORAGE_LAYER=minio` + MinIO env for container-maker & snapshot_job.
- **F. verify end-to-end** (PENDING→RUNNING→SUCCEEDED, tar in MinIO, image pushed, spinner stops; test FAILED path).

## Known prerequisite issue
The dev DB was set up via `init.py` (which reset the migration chain); its `alembic_version` may not match the repo chain. Reconcile before/while applying Phase A migrations (either re-migrate the dev DB via the real chain, or apply columns+trigger via SQL to the running DB and fix the chain as part of the init.py cleanup).

## Prod-grade follow-ups (later)
- Docker-daemon access: currently host socket / privileged Job. (No kaniko per decision — revisit a daemon-based builder that isn't the host socket if hardening.)
- Consider a `jobs` table for save history / concurrent saves.
