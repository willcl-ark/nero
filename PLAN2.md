Yes. I’d restructure it around immutable manifest jobs and make the current commit queue obsolete.

## Target architecture

Split the current combined service into two responsibilities:

1. A producer creates a manifest job.
2. A worker consumes manifest jobs and builds them.

The existing Bitcoin checkout remains useful, but only as one producer of jobs.

```text
manual manifests ───────┐
                        ├─> immutable job spool ─> Guix worker ─> profiles/substitutes
nightly Bitcoin checkout┘                              │
                                                       └─> ARM runner lifecycle
```

## 1. Define the manifest job format

Store jobs under the Guix data directory:

```text
/gnu/guix-bitcoin/jobs/
  queued/<job-id>/
  running/<job-id>/
  succeeded/<job-id>/
  failed/<job-id>/
```

Each job should contain:

```text
<job-id>/
  metadata
  manifests/
    manifest_build.scm
    manifest_codesign.scm
  context/
    contrib/guix/...
```

`metadata` should record at least:

- job ID
- submission timestamp
- submitting method: `manual` or `nightly`
- source repository, if applicable
- source commit, if applicable
- selected manifest filenames
- optional human-readable description

The job must contain copies of the manifests, not references to the submitter’s paths. This makes jobs immutable and retryable.

Because SCM manifests can depend on adjacent files, the job should also carry the relevant Guix context. For nightly Bitcoin jobs, this can initially be a snapshot of `contrib/guix`. Manual submissions should either be standalone manifests or supply an explicit context directory.

## 2. Use atomic queue transitions

Submission should work like this:

1. Create a temporary directory under `jobs/.tmp`.
2. Copy and validate all manifest files.
3. Copy any requested context.
4. Write metadata.
5. Atomically rename the completed directory into `jobs/queued/<job-id>`.

The worker claims a job by atomically renaming:

```text
queued/<job-id> -> running/<job-id>
```

On completion:

```text
running/<job-id> -> succeeded/<job-id>
```

On failure:

```text
running/<job-id> -> failed/<job-id>
```

Never process files directly from `queued`; partially submitted jobs must be impossible.

## 3. Add a reusable submission command

Add a Just recipe along these lines:

```bash
just guix-submit-manifests manifest_build.scm manifest_codesign.scm
```

The recipe should:

- accept one or more manifest paths;
- optionally accept a context directory;
- copy the files to Nero;
- generate a unique job ID;
- atomically enqueue the job;
- start the worker service.

A possible interface is:

```bash
just guix-submit-manifests \
  manifests/manifest_build.scm \
  manifests/manifest_codesign.scm \
  context=./contrib/guix
```

The exact syntax can be adjusted to Just’s variadic argument handling.

The old `just guix-build-commit` recipe should be removed in the same cutover. There should be no compatibility interpretation of `requested-commit` or `requested-repository`.

## 4. Make the nightly Bitcoin job a producer

The nightly path should retain its existing checkout behavior:

1. Clone the Bitcoin repository if necessary.
2. Fetch the configured branch.
3. Reset to the selected commit.
4. Discover `contrib/guix/manifest_*.scm`.
5. Create one manifest job containing all discovered manifests.
6. Copy the corresponding `contrib/guix` context.
7. Record the repository and commit in metadata.
8. Submit the job.
9. Start the worker.

The nightly job should no longer build profiles itself.

A missing manifest should fail the producer before creating a queued job.

The nightly job should submit one job containing all manifests, rather than creating one job per manifest. That preserves a coherent Bitcoin Core build while still making manifests the fundamental build unit inside the job.

## 5. Refactor the worker around jobs

The worker should no longer know about Bitcoin branches or requested commits.

For each claimed job it should:

1. Validate the job structure.
2. Discover the manifests from the job directory.
3. Generate system-specific wrappers.
4. Expand the existing matrix:

```text
job manifests
× configured native Guix systems
× Bitcoin target hosts
```

5. Materialize profiles.
6. Prewarm their closures.
7. Verify substitute availability.
8. Record per-manifest results.
9. Move the job to `succeeded` or `failed`.

The profile layout should become job-oriented:

```text
/gnu/guix-bitcoin/profiles/
  <guix-system>/
    <job-id>/
      <target-host>/
        <manifest-name>
```

The source commit remains metadata, not the queue identity. This allows manual jobs and non-Bitcoin jobs to use exactly the same worker.

The existing `last-built-manifests-*` optimization should be removed initially. A job is immutable and has its own ID, so correctness is simpler if each submitted job is independently tracked. Content-addressed deduplication can be added later if needed.

## 6. Separate systemd units

Use separate units conceptually:

### `guix-bitcoin-nightly.service`

Producer only:

- performs the Bitcoin checkout;
- discovers manifests;
- submits one job;
- starts the worker.

The existing timer should trigger this service.

### `guix-manifest-worker.service`

Worker only:

- claims queued jobs;
- executes builds;
- records job results;
- exits when the queue is empty or when a job fails.

Manual submission starts this service directly.

The worker should process jobs serially at first. This keeps ARM lifecycle and failure handling unambiguous. Parallelism remains inside each job’s configured native-system build phases.

## 7. Make ARM shutdown unconditional and authoritative

The ARM runner lifecycle should be owned by the worker, not tied only to successful completion.

For every job requiring `aarch64-linux`:

1. Inspect the EC2 state.
2. Start it if stopped.
3. Wait for `running`.
4. Wait for `guix offload test`.
5. Run the job.
6. Power it off on success or failure.

Use both:

- a shell cleanup trap in the worker; and
- `ExecStopPost` as a systemd-level safety net.

The shutdown should preferably use the AWS API as the final authority:

```bash
aws ec2 stop-instances \
  --region eu-central-1 \
  --instance-ids i-033b747d5599f78b9
```

SSH `systemctl poweroff` can remain as an optional graceful path, but AWS stop should be the fallback so a broken SSH session cannot leave the instance billing.

Define the policy explicitly: after a build job finishes or fails, the runner is stopped unless a deliberate maintenance lock is present.

## 8. Job logging and retention

Each job should have durable logs:

```text
<job-id>/
  metadata
  manifests/
  context/
  worker.log
  results/
    <system>/<host>/<manifest>.result
```

The worker journal should include:

- job ID;
- manifest;
- native Guix system;
- target host;
- profile path;
- ARM instance state;
- final job result.

The cleanup service should remove old completed and failed jobs according to separate retention periods. Failed jobs should be retained longer than successful jobs for diagnosis.

## 9. Hard-cutover sequence

Implement in this order:

1. Define job directory layout and validation rules.
2. Add the submission helper and Just recipe.
3. Add the worker’s queue claim and state-transition logic.
4. Move existing manifest matrix/profile logic into the worker.
5. Add the nightly producer around the existing Bitcoin checkout.
6. Add ARM cleanup traps and AWS stop fallback.
7. Replace the current timer target with the nightly producer.
8. Remove:
   - `requested-commit`;
   - `requested-repository`;
   - `just guix-build-commit`;
   - commit-specific logic from the worker;
   - `last-built-manifests-*`;
   - direct checkout logic from the worker.
9. Update README and operational recipes.
10. Deploy Nero and submit a manual test job before enabling the nightly timer.

Before cutover, inspect whether any old `requested-*` files exist. Convert them into a real manifest job or explicitly discard them; do not teach the new worker to understand the old format.

## 10. Verification criteria

The cutover is complete when all of these work:

- A manual submission with one manifest creates and processes one job.
- A manual submission with multiple manifests processes them as one job.
- A job survives a worker restart.
- A failed job moves to `failed` and retains its logs.
- A successful job moves to `succeeded`.
- The nightly producer checks out Bitcoin and submits all discovered manifests.
- A missing manifest fails before queueing.
- A manifest with invalid or unsafe paths is rejected.
- ARM starts for an AArch64 job.
- ARM powers down after a successful job.
- ARM powers down after a failed job.
- ARM also powers down if the worker is terminated unexpectedly.
- Multiple queued jobs are processed without overwriting each other.
- No code path reads `requested-commit` or `requested-repository`.

The key design choice is that the queue should contain complete, immutable manifest jobs. Bitcoin checkout is then just one way to produce those jobs, while the worker becomes independent of Bitcoin Core and can build any valid SCM manifest bundle.
