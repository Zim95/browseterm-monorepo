# Save Container Flow - Architecture Overview

## High-Level Change: From Privileged Sidecar to Kubernetes Job

### Old Architecture (Deprecated)
- **Location**: Snapshot sidecar running inside the SSH container pod (privileged mode)
- **Process**: All image building, pushing happened in-pod via `kubectl exec` commands
- **Problem**: Requires privileged access in user pods; security risk; tightly coupled to SSH container

### New Architecture (Current)
- **Location**: Isolated Kubernetes Job (privileged only for that job)
- **Process**: Tar file created in pod → Job created to build/push → Job terminates
- **Benefit**: Isolated from user workloads; privileged access only where needed; cleaner separation

---

## Complete Save Container Flow

### **Step 1: User Initiates Save** (browseterm-server)
- User clicks "Save Container" button in the UI
- Frontend calls API endpoint: `POST /save-container`
- browseterm-server receives request with `container_id` and `network_name`

### **Step 2: gRPC Call to container-maker**
```python
# browseterm-server calls container-maker's saveContainer RPC
SaveContainerRequest(
    container_id="<db_container_id>",
    network_name="<kubernetes_namespace>",
    # Database credentials for job
    db_host="...",
    db_port=5432,
    db_username="...",
    db_password="...",
    db_database="..."
)
```

### **Step 3: Container-maker Creates Tar on Shared PVC** (container-maker/src/resources/pod_manager.py)

**SaveUtility.build_tar()** - Runs in the main user pod:
```bash
tar --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/mnt/snapshot \
    -czvf /mnt/snapshot/full_fs_snapshot.tar.gz /
```
- Creates compressed tar of entire filesystem
- Excludes system directories and snapshot mount point
- **Writes tar to a shared PersistentVolumeClaim** mounted at `/mnt/snapshot`
    - PVC must support **ReadWriteMany (RWX)** so both the pod and the job can access it
    - Path: `/mnt/snapshot/{namespace}/{container_id}/full_fs_snapshot.tar.gz`
- Optional cleanup can be delayed until after the job completes

### **Step 4: Create Kubernetes Job** (container-maker/src/resources/job_manager.py)

**JobManager.create_snapshot_job()** creates:
- **Job Name**: `{pod_name}-snapshot-job`
- **Image**: `snapshot_job` Docker image (from browseterm-dockerfiles)
- **Privileges**: `privileged=True` (isolated job, not user pod)
- **Volume**: Same shared PVC mounted at `/mnt/snapshot` (read/write)
- **Environment Variables**:
  - `CONTAINER_ID`: Database ID
  - `POD_NAME`: Pod being snapshotted
  - `NAMESPACE_NAME`: Kubernetes namespace
  - `REPO_NAME`: Docker registry
  - `REPO_PASSWORD`: Registry password
    - **SNAPSHOT_PVC_NAME**: Name of the shared PVC
    - **SNAPSHOT_DIR**: Mount path (default: `/mnt/snapshot`)
  - `DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`, `DB_DATABASE`: Database credentials

**RBAC Setup** (per namespace):
- ServiceAccount: `snapshot-job-sa`
- Role: read pods and pod logs
- RoleBinding: connects SA to Role

### **Step 5: Job Executes** (browseterm-dockerfiles/snapshot_job/main.py)

The job runs these steps sequentially:

#### **5.1 Locate Tar on Shared PVC**
```bash
# Tar already exists on the shared PVC
ls -l /mnt/snapshot/{namespace}/{container_id}/full_fs_snapshot.tar.gz
```

#### **5.2 Unpack Tar**
```bash
mkdir -p /mnt/snapshot/rootfs
tar -xzf /mnt/snapshot/full_fs_snapshot.tar.gz -C /mnt/snapshot/rootfs
```

#### **5.2 Create Dockerfile**
```dockerfile
FROM scratch
COPY . /
ENTRYPOINT ["/entrypoint.sh"]
```

#### **5.3 Build Image**
```bash
docker image build -t {pod_name}-image:latest \
    -f /mnt/snapshot/rootfs/Dockerfile \
    /mnt/snapshot/rootfs
```
- Retry logic: 3 attempts with exponential backoff
- Timeout: 25 minutes

#### **5.4 Tag Image**
```bash
docker image tag {pod_name}-image:latest {REPO_NAME}/{pod_name}-image:latest
```

#### **5.5 Login to Registry**
```bash
docker login -u {REPO_NAME} -p {REPO_PASSWORD}
```
- Retry logic: 3 attempts
- Uses environment variables (non-interactive)

#### **5.6 Push Image**
```bash
docker image push {REPO_NAME}/{pod_name}-image:latest
```
- Timeout: 25 minutes

#### **5.7 Cleanup Local Images**
```bash
docker rmi {pod_name}-image:latest {REPO_NAME}/{pod_name}-image:latest
```
- Frees up space in the job

#### **5.8 Update Database** ⭐ **CRITICAL**
```python
# SnapshotBuilder calls update_saved_image() from browseterm_db
await update_saved_image(
    db_config=DBConfig(...),
    container_id=CONTAINER_ID,
    saved_image="{pod_name}-image:latest"
)
```
- **Connects to PostgreSQL directly** using environment variables
- **Updates `containers.saved_image` field** with the image name
- Uses `browseterm_db.operations.ContainerOps`
- If update fails → job exits with error (but image is already pushed)
- This is how the job communicates the built image back to the database

#### **5.9 Cleanup** (Optional)
```bash
# Delete tar and working directory after successful push
rm -rf /mnt/snapshot/{namespace}/{container_id}/full_fs_snapshot.tar.gz /mnt/snapshot/rootfs
```
- Cleanup can be delayed if you want to keep snapshots for recovery

### **Step 6: Wait for Job Completion** (container-maker/src/resources/job_manager.py)

**JobManager.wait_for_job_completion()**:
- Polls Kubernetes Job status every 5 seconds
- Checks: `job.status.succeeded` or `job.status.failed`
- Timeout: `SNAPSHOT_JOB_TIMEOUT_SECONDS` (configurable, default 1 hour)
- Once succeeded: returns to caller
- If failed: raises exception
- **Job Auto-cleanup**: `ttl_seconds_after_finished=3600` (1 hour)

### **Step 7: Return to Client**

```python
# SaveContainerResponse contains the saved image info
SavedPodResponse(
    pod_name=pod_name,
    namespace_name=namespace_name,
    image_name="{pod_name}-image:latest"
)
```

---

## Data Flow Diagram

```
┌──────────────────────────────────────────────────────────────┐
│ browseterm-server (HTTP)                                     │
│ User clicks "Save Container"                                 │
└─────────────────────────┬──────────────────────────────────┘
                          │ gRPC saveContainer
                          ↓
┌──────────────────────────────────────────────────────────────┐
│ container-maker (gRPC Servicer)                              │
│ saveContainer(container_id, network_name, db_credentials)   │
└─────────────────────────┬──────────────────────────────────┘
                          │
                    ┌─────┴─────┐
                    ↓           ↓
          ┌─────────────────┐  ┌──────────────────────┐
                    │ User Pod        │  │ Kubernetes Job       │
                    │ build_tar()     │  │ (snapshot-builder)   │
                    │ write to PVC    │  │                      │
                    │                 │  │ 1. Read from PVC     │
                    │ Creates:        │  │ 2. Unpack tar        │
                    │ tar.gz          │  │ 3. Create Dockerfile │
                    │                 │  │ 4. docker build      │
                    │                 │  │ 5. docker tag        │
                    │                 │  │ 6. docker login      │
                    │                 │  │ 7. docker push       │
                    │                 │  │ 8. UPDATE DB ⭐      │
                    │                 │  │ 9. Cleanup           │
                    └────────┬────────┘  └──────────┬───────────┘
                                     │                       │
                                     │ Shared PVC (RWX)      │
                                     ↓                       ↓
                ┌──────────────────────┐  ┌──────────────────┐
                │ Snapshot PVC         │  │ Docker Registry  │
                │                      │  │                  │
                │ Persistent Tar       │  │ Built Image      │
                │ Snapshots            │  │ {pod}-image:tag  │
                │                      │  │                  │
                │ Path:                │  └──────────────────┘
                │ /mnt/snapshot/{ns}/  │
                │ {cid}/tar.gz         │
                └──────────┬───────────┘
                                     │
                                     ↓
                ┌──────────────────────┐
                │ PostgreSQL           │
                │                      │
                │ containers           │
                │ .saved_image =       │
                │ "{pod}-image:latest" │
                │                      │
                │ .snapshot_path =     │
                │ "/mnt/snapshot/..."  │
                └──────────────────────┘
```

---

## Key Files and Their Roles

### **browseterm-dockerfiles** (snapshot_job)
| File | Purpose |
|------|---------|
| `snapshot_job/main.py` | Entry point; orchestrates all 8 steps |
| `snapshot_job/src/snapshot_builder.py` | Executes tar unpack, build, tag, login, push, cleanup |
| `snapshot_job/src/config.py` | Loads env vars (DB, registry, snapshot paths) |
| `snapshot_job/src/db_ops.py` | **Updates database with saved_image using browseterm_db** |
| `snapshot_job/Dockerfile.snapshot.job` | Docker image for the job |
| `snapshot_job/pyproject.toml` | Dependencies (asyncio, browseterm_db) |

### **container-maker**
| File | Purpose |
|------|---------|
| `src/resources/pod_manager.py` | **SaveUtility.build_tar()** - creates tar in user pod |
| `src/resources/pod_manager.py` | **PodManager.save()** - orchestrates full flow (Step 3→4→6) |
| `src/resources/job_manager.py` | **JobManager** - creates and monitors Kubernetes Job |
| `src/containers/containers.py` | **KubernetesContainerManager.save()** - entry point |
| `src/grpc/servicer.py` | **saveContainer() RPC handler** |
| `src/grpc/data_transformer/save_container_transformer.py` | Transforms gRPC request to dataclass |

### **browseterm-server**
| File | Purpose |
|------|---------|
| `src/api_handlers.py` | HTTP endpoint handlers |
| `src/containers/containers_service.py` | Calls container-maker gRPC with DB credentials |

---

## Database Update Details ⭐

### **In Snapshot Job** (browseterm-dockerfiles/snapshot_job)
The job receives DB credentials as environment variables:
```python
# From config.py
DB_CONFIG = DBConfig(
    host=os.getenv("DB_HOST"),
    port=int(os.getenv("DB_PORT", "5432")),
    username=os.getenv("DB_USERNAME"),
    password=os.getenv("DB_PASSWORD"),
    database=os.getenv("DB_DATABASE")
)
```

After pushing the image, the job updates the container record:
```python
# From main.py - Step 8
result = await update_saved_image(
    db_config=DB_CONFIG,
    container_id=CONTAINER_ID,
    saved_image=image_name
)

if not result.success:
    print(f"ERROR: Failed to update database: {result.error}")
    sys.exit(1)
```

### **Database Schema**
```sql
-- containers table
CREATE TABLE containers (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    image_id UUID,
    name VARCHAR(255),
    saved_image VARCHAR(255),  -- ⭐ Updated by snapshot job
    kubernetes_id VARCHAR(255),
    status ENUM('PENDING', 'RUNNING', 'STOPPED', 'ERROR'),
    ...
);
```

### **Job Success Criteria**
1. ✅ Tar unpacked
2. ✅ Image built
3. ✅ Image pushed to registry
4. ✅ **Database updated** (saved_image field populated)

If step 4 fails → entire job fails, and the image won't be tracked in the database.

---

## Configuration & Constants

### **Resource Config** (container-maker/src/resources/resource_config.py)
```python
SNAPSHOT_JOB_IMAGE_NAME = "snapshot_job:latest"
SNAPSHOT_JOB_TIMEOUT_SECONDS = 3600  # 1 hour
SNAPSHOT_JOB_SERVICE_ACCOUNT = "snapshot-job-sa"
SNAPSHOT_JOB_ROLE_NAME = "snapshot-job-role"
SNAPSHOT_JOB_ROLE_BINDING_NAME = "snapshot-job-rolebinding"
SNAPSHOT_DIR = "/mnt/snapshot"
```

### **Snapshot Builder Config** (snapshot_job/src/snapshot_builder.py)
```python
DOCKER_BUILD_MAX_RETRIES = 3
DOCKER_BUILD_RETRY_DELAY_SECONDS = 5.0
DOCKER_LOGIN_MAX_RETRIES = 3
DOCKER_LOGIN_RETRY_DELAY_SECONDS = 2.0
IMAGE_BUILD_TIMEOUT_MINUTES = 25
```

---

## Error Handling & Resilience

### **Retry Logic**
- **Docker Login**: 3 attempts, 2-30 second delays (exponential backoff)
- **Docker Build**: 3 attempts, 5-40 second delays (exponential backoff)
- **Docker Push**: Single attempt (built into docker push), 25-minute timeout

### **Timeout Handling**
- **tar unpack**: No explicit timeout (should be fast)
- **docker build**: 25 minutes
- **docker login**: 30 seconds
- **docker push**: 25 minutes
- **Job overall**: Configurable (default 1 hour)

### **Failure Paths**
1. If any step fails → job pod terminates with error
2. Job's `backoff_limit=2` → Kubernetes retries failed jobs
3. Failed job pods auto-cleanup after 1 hour (`ttl_seconds_after_finished`)
4. Database `saved_image` field remains null/unchanged on failure
5. **Critical**: If DB update fails, job exits with error code 1

---

## Security Considerations

### **Privilege Isolation**
- Old: Privileged sidecar in user pod
- New: Privileged only in isolated job pod
- **Result**: User pods remain unprivileged; cleaner security boundary

### **Credentials Management**
- Docker registry password passed via environment variable
- Database credentials passed via environment variable
- **Future**: Consider using Kubernetes Secrets for sensitive data

### **Volume Access**
- Snapshot job accesses only the snapshot volume
- Cannot access other pod volumes
- Cannot access user pod's home directory or other secrets

---

## Communication Flow Summary

1. **browseterm-server** → container-maker (gRPC with DB credentials)
2. **container-maker** → User Pod (build tar)
3. **container-maker** → Kubernetes API (create job)
4. **Snapshot Job** → Docker Registry (push image)
5. **Snapshot Job** → PostgreSQL (update database) ⭐ **Key step**

The job is the only entity that updates the database, ensuring the image record is tied to successful completion.

---

## Container Recovery Mechanism ⭐ **Future Enhancement**

### Problem
If a container dies unexpectedly without user knowing, we lose the current state. However, if we have a saved checkpoint (saved_image), we should be able to resume from that point.

### Solution: Database Trigger Event (similar to status_sidecar)

When a container status changes to `TERMINATED` or `ERROR`:
1. Check if a `saved_image` exists in the database
2. If yes, trigger a recovery event
3. browseterm-server or a recovery service listens for this event
4. Automatically recreate the container from `saved_image`

### Implementation Pattern (using status_sidecar as template)

**In status_sidecar** (browseterm-dockerfiles/status_sidecar):
- Already watches pod status changes
- Sends status updates to database
- Can also check if `saved_image` exists when status changes to TERMINATED
- Emit a recovery event/trigger

**Database Schema Addition**:
```sql
-- Table to track recovery events
CREATE TABLE container_recovery_events (
    id UUID PRIMARY KEY,
    container_id UUID REFERENCES containers(id),
    event_type VARCHAR(255),  -- "AUTO_RECOVER", "MANUAL_RECOVER"
    saved_image VARCHAR(255),  -- Image to restore from
    status VARCHAR(255),       -- "PENDING", "IN_PROGRESS", "SUCCESS", "FAILED"
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    error_message TEXT
);

-- Or: Use existing database trigger pattern from status_sidecar
-- Add trigger on containers table when status changes
CREATE TRIGGER container_status_change_trigger
AFTER UPDATE ON containers
FOR EACH ROW
WHEN (NEW.status = 'TERMINATED' AND NEW.saved_image IS NOT NULL)
  BEGIN
    -- Insert recovery event
    INSERT INTO container_recovery_events (...)
    VALUES (...);
  END;
```

### Recovery Flow

```
┌────────────────────────────────────────┐
│ Container Pod Dies (OOM, Crash, etc.)  │
└─────────────┬──────────────────────────┘
              │
              ↓
┌────────────────────────────────────────┐
│ Kubernetes detects pod termination     │
│ status_sidecar watches and detects     │
└─────────────┬──────────────────────────┘
              │
              ↓
┌────────────────────────────────────────┐
│ status_sidecar updates DB:             │
│ containers.status = 'TERMINATED'       │
└─────────────┬──────────────────────────┘
              │
              ↓
┌────────────────────────────────────────┐
│ Database trigger fires                 │
│ (if saved_image NOT NULL)              │
│ Creates recovery_event                 │
└─────────────┬──────────────────────────┘
              │
              ↓
┌────────────────────────────────────────┐
│ Recovery Service/browseterm-server     │
│ Listens to recovery events             │
│ Triggers: createContainer(saved_image) │
└─────────────┬──────────────────────────┘
              │
              ↓
┌────────────────────────────────────────┐
│ New Pod Created from saved_image       │
│ Container restored to previous state    │
└────────────────────────────────────────┘
```

### Key Points

1. **Automatic Detection**: status_sidecar already monitors pod lifecycle
2. **Checkpoint Available**: We have `saved_image` from the save operation
3. **Database Trigger**: Similar pattern to existing status updates
4. **No User Action Required**: Recovery happens automatically if enabled
5. **Audit Trail**: Recovery events logged in database

### Status Field Needs Update

```python
# Current status enum in browseterm_db
class ContainerStatus(Enum):
    PENDING = "PENDING"
    RUNNING = "RUNNING"
    STOPPED = "STOPPED"
    ERROR = "ERROR"

# Possible additions:
# TERMINATED = "TERMINATED"  # Container crashed/died unexpectedly
# RECOVERING = "RECOVERING"  # Auto-recovery in progress
```

---

## Implementation Roadmap

### **Phase 1: Shared Persistent Volume** (Save Snapshots on RWX PVC)

Order of implementation:
1. **Provision a shared RWX PVC**
    - Use an RWX-capable storage class (e.g., NFS, CephFS, EFS)
    - Create a PVC (e.g., `snapshot-pvc`) mounted at `/mnt/snapshot`

2. **Enable saving tar to the shared PVC**
    - `SaveUtility.build_tar()` writes tar directly to `/mnt/snapshot/{namespace}/{container_id}/...`
    - No object storage required

3. **Enable Kubernetes Job to read from the shared PVC**
    - Job mounts the same PVC at `/mnt/snapshot`
    - Reads tar from the shared path

4. **Job creates image and updates database**
    - Steps 5.1-5.8 from main flow (already designed)
    - Reads tar from the shared PVC

**Benefits of this phase**:
- Simple to deploy (no object storage)
- Shared, durable storage across pods
- Works well for single-cluster deployments

---

### **Phase 2: Container Recovery & Resource Management** (Smart Termination + Auto-Recovery)

#### **Challenge**
Containers consume resources (CPU, memory, storage). Long-running unused containers waste cluster resources. However, we want users to resume from saved state if they return.

#### **Solution: Activity-Based Lifecycle Management**

**Rules**:
- If container is **inactive for 7 days** → **Terminate pod** (free resources)
- If container is **terminated** AND user **active within 7 days** → **Auto-recover** (recreate from saved_image)
- If container is **terminated** AND user **inactive for 7+ days** → **Keep terminated** (save resources)

#### **Implementation Order**

1. **Add activity tracking to database**
   ```sql
   ALTER TABLE containers ADD COLUMN (
       last_activity_at TIMESTAMP,  -- Last user interaction
       terminated_at TIMESTAMP,     -- When pod was terminated
       should_auto_recover BOOLEAN DEFAULT FALSE
   );
   ```

2. **Implement inactivity detector** (status_sidecar enhancement)
   - Every hour, check: `NOW() - last_activity_at > 7 days`
   - If true AND pod is running → Trigger termination
   - Delete pod, update status to `TERMINATED`
   - Mark `terminated_at = NOW()`

3. **Detect user activity** (browseterm-server)
   - When user connects to container (SSH) → Update `last_activity_at = NOW()`
   - When user sends any command → Update `last_activity_at = NOW()`
   - This creates a heartbeat of user activity

4. **Implement recovery mechanism**
   - When user tries to access terminated container:
     - Check: `NOW() - last_activity_at < 7 days`
     - Check: `saved_image IS NOT NULL`
     - If both true → Auto-recover (create new pod from saved_image)
     - If both false → Error: "Container too old, cannot recover"

#### **Recovery Flow with Inactivity**

```
┌─────────────────────────────────┐
│ User logs in (last login 2 days ago)
│ Tries to access container       │
└────────────┬────────────────────┘
             │
             ↓
┌─────────────────────────────────┐
│ browseterm-server checks:       │
│ - saved_image exists? ✓         │
│ - NOW() - last_activity < 7d? ✓ │
└────────────┬────────────────────┘
             │
             ↓
┌─────────────────────────────────┐
│ Auto-recovery triggered:        │
│ createContainer(saved_image)    │
│ Update last_activity_at        │
└────────────┬────────────────────┘
             │
             ↓
┌─────────────────────────────────┐
│ New pod created from snapshot   │
│ Container restored              │
│ User connects successfully      │
└─────────────────────────────────┘
```

#### **Inactivity Termination Flow**

```
┌─────────────────────────────────┐
│ Inactivity Detector runs        │
│ (every hour or on schedule)     │
└────────────┬────────────────────┘
             │
             ↓
┌─────────────────────────────────┐
│ For each running container:     │
│ Check: NOW() - last_activity > 7d?
└────────────┬────────────────────┘
             │
        ┌────┴─────┐
        │           │
       YES          NO
        │           │
        ↓           ↓
   ┌────────────┐  ┌─────────────┐
   │ Terminate  │  │ Keep running│
   │ pod        │  │ (user active)
   │ (save      │  └─────────────┘
   │  resources)│
   └────────────┘
```

#### **Database Schema for Recovery**

```sql
-- Enhanced containers table
ALTER TABLE containers ADD COLUMN (
    last_activity_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    terminated_at TIMESTAMP,
    termination_reason VARCHAR(255),  -- "INACTIVE", "USER_REQUESTED", "ERROR"
    should_auto_recover BOOLEAN DEFAULT TRUE
);

-- Recovery events table
CREATE TABLE container_recovery_events (
    id UUID PRIMARY KEY,
    container_id UUID REFERENCES containers(id),
    event_type VARCHAR(255),        -- "AUTO_RECOVER", "MANUAL_RECOVER"
    recovery_reason VARCHAR(255),   -- "INACTIVITY_RECOVERY", "ERROR_RECOVERY"
    source_image VARCHAR(255),      -- saved_image we're recovering from
    status VARCHAR(255),            -- "PENDING", "IN_PROGRESS", "SUCCESS", "FAILED"
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    error_message TEXT
);

-- Activity log table (optional, for audit trail)
CREATE TABLE container_activity_log (
    id UUID PRIMARY KEY,
    container_id UUID REFERENCES containers(id),
    activity_type VARCHAR(255),    -- "SSH_CONNECT", "COMMAND", "FILE_UPLOAD", etc.
    activity_details TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

#### **Key Components to Build**

| Component | Where | Purpose |
|-----------|-------|---------|
| Activity Tracker | browseterm-server | Update `last_activity_at` on user actions |
| Inactivity Detector | status_sidecar | Monitor and terminate idle containers |
| Recovery Orchestrator | browseterm-server | Detect terminated containers on access, trigger recreation |
| Recovery Event System | browseterm-db | Trigger-based event firing on status changes |
| Dashboard Alert | browseterm-server UI | Warn users before termination (7-day countdown) |

#### **User Experience**

1. **Active Users**: Containers never terminate (activity refreshes every interaction)
2. **Inactive Users**: 
   - Day 0-6: Container runs normally, last_activity tracked
   - Day 7: Inactivity detector runs, pod terminates (status = TERMINATED)
   - User logs back in: Automatic recovery, no data loss (within 7 days)
   - Day 8+: Container cannot recover (too old), user must recreate
3. **Dashboard Notification**: "Your container will auto-terminate in X days due to inactivity"

#### **Resource Savings**

- **Before**: Unused containers consume CPU (0.1-1), Memory (256M-1G) indefinitely
- **After**: Unused containers terminated after 7 days, resume from checkpoint when user returns
- **Savings**: ~90% resource reduction for inactive users after 7 days

---

## Summary of All Three Phases

```
Phase 1: Shared PVC Integration
    ↓
    Snapshots stored persistently on RWX PVC
    Job reads directly from shared volume

Phase 2: Container Recovery
  ↓
  Auto-recover containers when users return
  Users never lose data within 7-day window
  
Phase 3: Resource Management (Inactivity Detection)
  ↓
  Automatically terminate unused containers
  Reduce cluster load
  Recreate on user's return
```
