# Save Flows Architecture

## Overview

The save flows architecture manages three distinct scenarios for container lifecycle management:
1. **Active Containers** - Fresh start with original image
2. **Inactive Containers** - Terminated on inactivity, can reload with saved image
3. **Failed/Error Containers** - Crashed pods, can reload with saved image

## Core Principles

1. **Async Save Operations** - Saving doesn't block the UI, runs in background
2. **Event-Driven** - Listen for database changes and job completions
3. **Database as Source of Truth** - Job updates database directly, front end reads from DB
4. **Job Status Tracking** - Separate `jobs` table tracks job status, errors, timestamps
5. **Timestamp Visibility** - Users see latest successful save timestamp to verify progress
6. **Graceful Degradation** - If save fails, pod still works with base image or previous saved image

---

## Async Save Architecture

### The Problem with Blocking Saves

Old approach (blocking):
```
User clicks Save
    ↓
SaveUtility.save() creates job
    ↓
WAIT for job to complete (30 minutes possible!)
    ↓
Front end blocked, loading spinner forever
    ↓
Return image name
```

**Issues:**
- Front end can't do anything while waiting
- Network timeout if job takes too long
- No visibility into job progress
- Users think it's frozen

### New Approach (Async/Event-Driven)

```
User clicks Save
    ↓
SaveUtility.save_async() returns immediately
    ↓
Front end shows loading icon on save button
    ↓
Job runs in background
    ↓
Job completes → Updates database OR jobs table
    ↓
Event listener triggers in browseterm-server
    ↓
Send WebSocket event to front end
    ↓
Front end shows notification (success or failure)
    ↓
Stop loading icon, show timestamp
```

### Key Differences: Blocking vs Async

| Aspect | Blocking (Current) | Async (Proposed) |
|--------|------------------|-----------------|
| SaveUtility returns | After job completes | Immediately |
| Front end waits | 30+ minutes | 1-2 seconds |
| Job status visibility | None while waiting | Visible in jobs table |
| Failure handling | Throws exception | Event notification |
| UI state | Locked during save | Responsive, loading icon |
| Multiple saves | Blocked | Can queue multiple |

### Database Schema for Job Tracking

**New jobs table:**
```sql
CREATE TABLE jobs (
    job_id UUID PRIMARY KEY,
    container_id VARCHAR NOT NULL,
    status VARCHAR NOT NULL,           -- pending, running, succeeded, failed
    created_at TIMESTAMP DEFAULT NOW(),
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    saved_image VARCHAR,               -- populated on success
    error_message TEXT,                -- populated on failure
    error_details TEXT,                -- full traceback on failure
    FOREIGN KEY (container_id) REFERENCES containers(container_id)
);

CREATE INDEX idx_jobs_container ON jobs(container_id);
CREATE INDEX idx_jobs_status ON jobs(status);
```

**Containers table additions:**
```sql
ALTER TABLE containers ADD COLUMN last_saved_timestamp TIMESTAMP;  
ALTER TABLE containers ADD COLUMN last_saved_image VARCHAR;        
```

### Flow Diagram: Complete Async Save

```
Frontend                Container-Maker         Kubernetes Job      browseterm-server       Database
   |                        |                       |                     |                    |
   | User clicks Save       |                       |                     |                    |
   |-------- save() -------->|                       |                     |                    |
   |                        |                       |                     |                    |
   |                        | 1. Create Job entry   |                     |                    |
   |                        |                       |                     | INSERT into jobs   |
   |                        |                       |                     | (status=pending)   |
   |                        |                       |                     |                    |
   |                        | 2. Trigger Job        |                     |                    |
   |                        |------------ job ----->|                     |                    |
   |                        |                       |                     |                    |
   | (Loading icon)         | 3. Return job_id     |                     |                    |
   |<--- return job_id ------|  immediately          |                     |                    |
   |                        |                       |                     |                    |
   | (Front end responsive) |                       |                     |                    |
   |                        |                       |                     |                    |
   |                        |                    (building image)         |                    |
   |                        |                    (pushing image)          |                    |
   |                        |                       |                     |                    |
   |                        |                       | 4. On success        |                    |
   |                        |                       |------ UPDATE saved_image,
   |                        |                       |        jobs.status=succeeded
   |                        |                       |                     |                    |
   |                        |                       |                     | LISTEN for changes |
   |                        |                       |                     |                    |
   |                        |                       |                 Event detected!         |
   |                        |                       |                     |                    |
   | 5. WebSocket event     |                       |                     |                    |
   |<--- save_completed ----|<---- event ----------|<---- notify --------|                    |
   |  {status: success,     |                       |                     |                    |
   |   timestamp: ...}      |                       |                     |                    |
   |                        |                       |                     |                    |
   | Stop loading icon      |                       |                     |                    |
   | Show: "Progress        |                       |                     |                    |
   |  saved ✓ 2:45 PM"      |                       |                     |                    |
```

---

## Implementation Details

### 1. SaveUtility Changes

**Old (blocking):**
```python
def save(data: SavePodDataClass) -> dict:
    # ... create job ...
    JobManager.wait_for_job_completion(...)  # BLOCKS for hours!
    image_name = f'{pod_name}-image:latest'
    return {'image_name': image_name}
```

**New (async):**
```python
def save_async(data: SavePodDataClass) -> dict:
    """Start save job and return immediately"""
    
    # Create entry in jobs table
    job_id = JobManager.create_job_entry(
        container_id=container_id,
        status='pending'
    )
    
    # Trigger the job
    job_info = JobManager.create_snapshot_job(...)
    
    # Update job entry: pending -> running
    JobManager.update_job_status(job_id, 'running', started_at=now())
    
    # Return immediately - don't wait!
    return {
        'job_id': job_id,
        'job_name': job_info['job_name'],
        'status': 'pending'
    }
```

### 2. Snapshot Job Changes

**Update database on success/failure:**
```python
# In browseterm-dockerfiles/snapshot_job/main.py

async def main():
    try:
        # Update status to running
        await db.jobs.update({
            'job_id': os.getenv('JOB_ID'),
            'status': 'running',
            'started_at': now()
        })
        
        # ... build, push, etc ...
        image_name = await builder.build_and_push()
        
        # On success: update database
        await update_saved_image(container_id, image_name)
        await db.jobs.update({
            'job_id': os.getenv('JOB_ID'),
            'status': 'succeeded',
            'saved_image': image_name,
            'completed_at': now()
        })
        
    except Exception as e:
        # On failure: record error
        await db.jobs.update({
            'job_id': os.getenv('JOB_ID'),
            'status': 'failed',
            'error_message': str(e),
            'error_details': traceback.format_exc(),
            'completed_at': now()
        })
        sys.exit(1)
```

### 3. browseterm-server Event Listener

**Option A: Database Polling (Simpler)**
```python
import asyncio

class JobStatusPoller:
    def __init__(self, db, ws_manager):
        self.db = db
        self.ws_manager = ws_manager
        self.notified_jobs = set()
    
    async def poll(self):
        while True:
            try:
                # Query recent job status changes
                recent_jobs = await self.db.jobs.find({
                    'status': {'$in': ['succeeded', 'failed']},
                    'completed_at': {'$gte': now() - timedelta(minutes=5)}
                })
                
                for job in recent_jobs:
                    if job.job_id not in self.notified_jobs:
                        await self.notify_clients(job)
                        self.notified_jobs.add(job.job_id)
                
                await asyncio.sleep(5)  # Poll every 5 seconds
            
            except Exception as e:
                print(f"Polling error: {e}")
                await asyncio.sleep(5)
    
    async def notify_clients(self, job):
        event = {
            'type': 'save_completed',
            'container_id': job.container_id,
            'status': job.status,
            'image': job.saved_image,
            'error': job.error_message,
            'timestamp': job.completed_at.isoformat()
        }
        
        # Send to all connected clients for this container
        await self.ws_manager.broadcast_to_container(
            job.container_id,
            event
        )
```

### 4. Front End Implementation

**Show loading state:**
```javascript
async function saveTerminal() {
    // Show loading icon
    saveButton.classList.add('loading');
    saveButton.disabled = true;
    
    // Call save endpoint
    const response = await fetch('/api/save', {
        method: 'POST',
        body: JSON.stringify({container_id})
    });
    
    const {job_id} = await response.json();
    
    // Listen for completion event
    websocket.on('save_completed', (event) => {
        if (event.container_id === currentContainerId) {
            // Stop loading
            saveButton.classList.remove('loading');
            saveButton.disabled = false;
            
            if (event.status === 'succeeded') {
                showNotification(`✓ Progress saved at ${event.timestamp}`);
                updateSavedTimestamp(event.timestamp);
            } else {
                showNotification(`✗ Failed to save: ${event.error}`);
            }
        }
    });
}
```

---

## User Experience Timeline

```
t=0s   User clicks "Save Progress" button
       → Button shows loading spinner
       → jobs table: INSERT {job_id, container_id, status=pending}

t=1s   container-maker receives request
       → Updates jobs.status = running
       → Creates Kubernetes Job
       → Returns job_id to front end immediately

t=2s   Front end continues working (responsive UI)
       → User can still use terminal
       → No freezing, no wait

t=30s  Kubernetes Job starts
       → Building Docker image
       → jobs.status still = running

t=50s  Job pushes image to registry
       → Still building/pushing

t=55s  Job completes successfully
       → Runs db UPDATE: saved_image = 'test-pod-image:latest'
       → Updates jobs.status = succeeded
       → Updates jobs.completed_at = now()

t=56s  browseterm-server polling detects change
       → Constructs WebSocket event

t=57s  Front end receives WebSocket event
       → {type: 'save_completed', status: 'succeeded', timestamp}
       → Stops loading spinner
       → Shows popup: "✓ Progress saved at 2:45 PM"
       → Updates timestamp in UI

---

FAILURE SCENARIO:

t=0s   User clicks "Save Progress"
t=55s  Job fails (e.g., image push timeout)
       → jobs.status = failed
       → jobs.error_message = "Failed to push: connection timeout"
       → jobs.error_details = full traceback

t=56s  browseterm-server detects failed status

t=57s  Front end receives event
       → Stops loading spinner
       → Shows popup: "✗ Failed to save: connection timeout"
       → UI shows last known good timestamp (unchanged)
       → Button shows "Try Again" option

t=58s  User clicks "Try Again"
       → Another job is queued and triggered
       → Cycle repeats...
```

---

## Error Handling & Resilience

### Scenario 1: Job Fails (Image Push Error)

```
Job fails → jobs.status = 'failed'
         → saved_image NOT updated
         → Pod still works with:
             • Previous saved_image (if exists), OR
             • Base image (if first time)
         → Front end notified of failure
         → User sees error message
         → User can retry from UI
```

### Scenario 2: Database Update Fails Inside Job

```
Image built successfully
    ↓
Image pushed to registry successfully
    ↓
Try to update jobs table → CONNECTION ERROR
    ↓
Job catches exception, updates jobs.status = 'failed'
    ↓
jobs.error_message = "Database connection failed"
    ↓
Image orphaned in registry (data loss potential)
    ↓
Solution: Implement retry logic with exponential backoff
          or manual recovery process
```

### Scenario 3: browseterm-server is Down

```
Job completes → Database updated
    ↓
browseterm-server is offline
    ↓
No WebSocket notification sent
    ↓
Front end shows loading spinner (forever?)
    ↓
Solutions:
  - Front end can fallback to polling: check job status every 10 seconds
  - browseterm-server resumes, catches up on unnotified jobs
  - Timestamp visible in database if user refreshes page
```

### Scenario 4: Multiple Saves Queued

```
User clicks Save
    ↓
t=2s: Job 1 queued (job_id=uuid-1, status=pending)
    ↓
t=3s: User clicks Save again
    ↓
t=3s: Job 2 queued (job_id=uuid-2, status=pending)
    ↓
t=50s: Job 1 completes → saved_image = 'image-v1'
    ↓
t=70s: Job 2 completes → saved_image = 'image-v2' (overwrites v1)
    ↓
Pod now on image-v2 (latest wins)
    ↓
Solution: Disable save button while any job is running/pending
          or queue jobs sequentially
```

---

## Summary of Async Design Decisions

1. ✅ **Async saves** - SaveUtility returns immediately, job runs in background
2. ✅ **Event-driven notifications** - Real-time WebSocket updates via browseterm-server
3. ✅ **Separate jobs table** - Track status, errors, timestamps independently
4. ✅ **Database as source of truth** - Job writes directly to DB, not through container-maker
5. ✅ **Last saved timestamp** - Users know exactly when their last successful save was
6. ✅ **Graceful degradation** - Pod works even if save fails, uses previous image or base
7. ✅ **Clear error visibility** - Users see error messages and can retry
8. ✅ **No blocking operations** - UI remains responsive, user can continue working
9. ✅ **Status transparency** - Users can see job status in UI (optional)
10. ✅ **Automatic recovery** - On pod crash, K8s uses saved image automatically

---

## Scenario 1: Active Container (Play Button)

**State:** `active = true` in database, pod is running

**User Action:** Click "Play" button to create new session

**Flow:**
```
User clicks Play
    ↓
Call create(container_id, use_saved_image=False)
    ↓
Create pod with base image_name from CreatePodDataClass
    ↓
Pod runs fresh session
```

**Details:**
- Uses the original image specified in the container configuration
- Fresh start, no previous state
- Pod is immediately ready for user interaction

---

## Scenario 2: Inactive Container - Inactivity Termination (Reload Button)

**State:** `active = false` in database, pod is deleted

**When it happens:**
- Container terminated due to user inactivity timeout
- Pod is deleted
- `active` field set to `false` in database
- Saved image already built and exists in registry

**User Action:** Click "Reload" button to restore session

**Flow:**
```
User clicks Reload
    ↓
Call create(container_id, use_saved_image=True)
    ↓
Query database for saved_image using container_id
    ↓
Create pod with saved_image instead of base image
    ↓
Pod runs with previous state from snapshot
```

**Details:**
- Restores the container to its last saved state
- Much faster recovery since image is already built
- User resumes from where they left off
- No need to rebuild the image

---

## Scenario 3: Failed/Error Container (Reload Button)

**State:** Pod in `Failed` or `Error` state, visible in dashboard

**When it happens:**
- Pod crashes due to application error or resource issue
- Pod remains visible in cluster in Failed state
- User sees pod status in dashboard
- Saved image exists from previous successful save

**User Action:** 
1. Observes pod in Failed state in dashboard
2. Clicks "Reload" button to attempt recovery

**Flow:**
```
Pod crashes → Failed/Error state
    ↓
K8s automatically updates pod definition with saved image
    ↓
Pod remains Failed until user action
    ↓
User sees Failed pod in dashboard
    ↓
User clicks Reload
    ↓
Call create(container_id, use_saved_image=True)
    ↓
Query database for saved_image
    ↓
Create new pod with saved_image (or delete failed one first)
    ↓
Fresh pod starts with recovered state
```

**Details:**
- User has visibility into what failed via dashboard
- No automatic retry loops that could cascade failures
- User control enables informed recovery decisions
- If saved image also fails, user can investigate root cause

---

## K8s Auto-Recovery for Crash

**When a running pod terminates unexpectedly:**

```
Pod crashes (from running state)
    ↓
K8s reads pod definition (already patched with saved_image)
    ↓
K8s automatically creates new pod with saved_image
    ↓
User continues without interruption
    ↓
Pod recovery transparent to user
```

**Why this works:**
- After save, the pod's image is already patched to the saved_image
- K8s automatically restarts pods with their current definition
- No manual intervention needed for crashes
- Automatic recovery respects Kubernetes principles

---

## UI State Mapping

```
Database Field: active

active = true  → Show "Play" button
  - Fresh container
  - Create with base image

active = false → Show "Reload" button
  - Inactive container
  - Create with saved image
  - Pod is deleted

Pod Status = Failed/Error → Show "Reload" button
  - Failed container
  - Create with saved image
  - Choose to delete failed pod or create alongside
```

---

## Implementation Requirements

### 1. CreatePodDataClass Changes

Add field:
```python
use_saved_image: bool = False  # Use saved_image from DB instead of image_name
```

### 2. PodManager.create() Changes

Add logic:
```python
def create(data: CreatePodDataClass) -> dict:
    if data.use_saved_image:
        # Query database for saved_image using container_id
        saved_image = query_database_for_saved_image(container_id)
        if not saved_image:
            raise ValueError(f"No saved image found for container {container_id}")
        image_to_use = saved_image
    else:
        image_to_use = data.image_name
    
    # Create pod with image_to_use
    create_pod_with_image(image_to_use, ...)
```

### 3. Inactivity Termination Handler

When terminating due to inactivity:
```python
# 1. Set active = false in database
update_container_active_status(container_id, active=False)

# 2. Delete the pod
PodManager.delete(pod)

# 3. Do NOT recreate - user will click Reload
```

### 4. Failed Pod Handling

When user clicks reload for failed pod:
```python
# Option A: Delete failed pod first, then create new
PodManager.delete(failed_pod)
PodManager.create(create_data with use_saved_image=True)

# Option B: Create alongside failed pod (if multiple allowed)
PodManager.create(create_data with use_saved_image=True)
```

---

## Database Integration

Required database fields:
- `containers.active` - Boolean, indicates if container is currently active
- `containers.saved_image` - String, registry path to saved image (already exists)

Query to get container with saved image:
```python
SELECT container_id, saved_image, active FROM containers WHERE container_id = ?
```

---

## Benefits of This Design

1. **Visibility** - Failed pods visible in dashboard, not hidden by auto-retry
2. **Control** - User decides when to recover, not automatic loops
3. **Efficiency** - Saved image recovery faster than base image + work
4. **Simplicity** - Same recovery path for all failure types
5. **K8s Native** - Leverages native Kubernetes restart mechanism
6. **No Status Listeners** - Don't need continuous monitoring for failures
7. **Clear UI** - Play vs Reload button is intuitive state indicator

---

## Edge Cases

### Case 1: User clicks Reload but no saved_image exists
- Validation in code prevents this - check saved_image exists before calling create with use_saved_image=True
- If saved_image missing, show error to user

### Case 2: Pod crashes while user has unsaved work
- Same as before - user loses unsaved work
- Saved image represents last successful save point
- User should save frequently

### Case 3: Saved image itself is corrupted
- Pod will fail to start
- User sees Failed state in dashboard
- User can click Reload again or Play (base image) to investigate
- Logs in failed pod can help debug

### Case 4: Multiple pods from same container
- Not a typical use case
- If needed, handle in UI layer (show which pod user wants to recover)
- Or implement pod lifecycle that only allows one active pod per container

---

## Timeline Summary

```
Create Container
  ↓
User works in active pod
  ↓
User saves snapshot
  → Tar created → Job builds image → Database updated with saved_image
  → Pod image patched to saved_image
  ↓
User continues working
  ↓
Option A: Inactivity termination
  → Set active=false
  → Delete pod
  → User clicks Reload button
  → Create with saved_image
  
Option B: Pod crashes
  → Pod enters Failed state
  → K8s patches and tries to restart (uses saved_image from definition)
  → User sees Failed in dashboard
  → User clicks Reload (or observes if K8s recovers)
  → Create with saved_image
  
Option C: User terminates session normally
  → Set active=false
  → Delete pod
  → Later, user clicks Play to start fresh
  → Create with base image
```
