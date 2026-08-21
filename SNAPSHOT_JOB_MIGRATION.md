# Snapshot Job Refactoring - Migration Guide

## Overview
Refactored the container snapshot system from a **privileged snapshot sidecar** running in every pod to an **isolated Kubernetes Job** that runs only when needed.

## What Changed

### 🔒 Security Improvements
- ✅ **User pods no longer run in privileged mode**
- ✅ **Main containers**: `privileged=False`
- ✅ **Status sidecar**: `privileged=False`
- ✅ **Snapshot sidecar**: Removed from pods entirely
- ⚠️ **Snapshot jobs**: Run privileged, but isolated and ephemeral

### 📁 New Files Created

#### browseterm-dockerfiles/snapshot_job/
```
snapshot_job/
├── Dockerfile.snapshot.job      # Job container image
├── build.sh                     # Build script
├── pyproject.toml               # Python dependencies
├── main.py                      # Entry point
├── README.md                    # Documentation
└── src/
    ├── __init__.py
    ├── config.py                # Configuration (like status_sidecar)
    ├── db_ops.py                # Database updates
    └── snapshot_builder.py      # Docker image building logic
```

#### container-maker/src/resources/
- `job_manager.py` - Manages Kubernetes Jobs for snapshots

### 🔄 Modified Files

#### container-maker/src/resources/
- **resource_config.py**: Added job configuration constants
- **pod_manager.py**:
  - Removed snapshot sidecar from container list
  - Changed `privileged=True` → `privileged=False`
  - Updated `SaveUtility.save_image()` to use Jobs
  - Updated `PodManager.save()` signature with `container_id` and `db_credentials`

#### container-maker/src/containers/
- **containers.py**: Pass db_credentials when calling save
- **dataclasses/save_container_dataclass.py**: Added db credential fields

#### browseterm-dockerfiles/
- **Makefile**: Added `build_snapshot_job` target, updated `build_all`

## How It Works Now

### Old Flow (Deprecated)
```
1. Pod created with 3 containers:
   - Main (privileged)
   - Snapshot sidecar (privileged)  ❌
   - Status sidecar (privileged)
2. Save command → kubectl exec into snapshot sidecar
3. Sidecar builds image, pushes to registry
```

### New Flow
```
1. Pod created with 2 containers:
   - Main (unprivileged) ✅
   - Status sidecar (unprivileged) ✅
2. Save command:
   a. Main container creates tar file
   b. Kubernetes Job created (privileged, isolated)
   c. Job builds image, pushes to registry
   d. Job updates database directly
   e. Job terminates automatically
```

## Database Integration

The snapshot job updates the database **directly** (like status_sidecar):
```python
# Job updates saved_image field
await update_saved_image(
    db_config=DB_CONFIG,
    container_id=CONTAINER_ID,
    saved_image=image_name
)
```

## Building & Deploying

### Build the snapshot job image:
```bash
cd browseterm-dockerfiles
make build_snapshot_job
```

### Build all images:
```bash
make build_all  # Now builds snapshot_job instead of snapshot_sidecar
```

### Environment Variables Required
The Job needs these environment variables (passed automatically):
- `CONTAINER_ID` - Database UUID
- `POD_NAME` - Pod being snapshotted
- `NAMESPACE_NAME` - Kubernetes namespace
- `REPO_NAME` - Docker registry repo
- `REPO_PASSWORD` - Docker registry password
- `DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`, `DB_DATABASE` - Database credentials

## Migration Steps

1. **Build new snapshot_job image**:
   ```bash
   cd browseterm-dockerfiles
   make build_snapshot_job
   ```

2. **Deploy updated container-maker**:
   - New pods will be created without snapshot sidecar
   - Pods will run unprivileged

3. **Test save operation**:
   - Save will create a Job
   - Job will complete and update database
   - Job will auto-cleanup after 1 hour

## Backward Compatibility

- Snapshot sidecar code kept in browseterm-dockerfiles/snapshot_sidecar (deprecated)
- `SNAPSHOT_SIDECAR_NAME` constant kept in resource_config.py for compatibility
- Old save tests may need updating

## Benefits

✅ **Security**: User containers no longer run privileged
✅ **Isolation**: Snapshot operations isolated from user workloads
✅ **Resource Efficiency**: No permanent snapshot sidecar consuming resources
✅ **Reliability**: Jobs can retry on failure
✅ **Auto-cleanup**: Jobs terminate and clean up after completion
✅ **Consistency**: Database updates follow status_sidecar pattern

## Testing Checklist

- [ ] Build snapshot_job image
- [ ] Deploy updated container-maker
- [ ] Create a new container (verify 2 containers, not 3)
- [ ] Verify main pod runs unprivileged
- [ ] Save a container (verify Job created)
- [ ] Verify Job completes successfully
- [ ] Verify database updated with saved_image
- [ ] Verify Job auto-deletes after TTL

## Rollback Plan

If issues arise:
1. Revert container-maker/src/resources/pod_manager.py
2. Add snapshot sidecar back to container list
3. Change `privileged=False` → `privileged=True`
4. Revert SaveUtility.save_image() to old implementation

---
**Note**: This is a major security improvement that removes the need for privileged user containers!


