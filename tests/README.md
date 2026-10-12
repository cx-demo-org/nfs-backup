# Backup and restore acceptance tests (draft)

## Functional test data

- Nested directories and duplicate file names in different directories.
- Empty files, zero-byte directories where representable, small files, and a file larger than the expected transfer chunk size.
- Deterministic content with a manifest of relative path, object type, byte length, and SHA-256.
- Optional POSIX ownership, group, mode, symbolic-link, and hard-link cases if these are part of the required restore contract.

## Acceptance criteria

- The source share is mounted before snapshot creation; the point-in-time snapshot and its `.snapshots` directory identifier are recorded.
- The archive, source manifest, run metadata, and success marker appear under a unique recovery-point prefix in the separate destination account.
- The downloaded archive SHA-256 matches run metadata, and the restored-tree manifest matches the snapshot-tree manifest for all in-scope content and POSIX fields.
- The restore test reads every restored file and reproduces all explicitly required metadata.
- A failed backup is reported as failed, retains enough evidence to diagnose, and does not mark the recovery point as valid.
- A second run does not overwrite or silently mutate an earlier recovery point.
- Teardown targets only the disposable lab resource group and is blocked until immutable-retention constraints are understood.

## Scale tests to define

Measure elapsed time, peak local staging disk, CPU/memory, transactions, bytes transferred, and estimated storage/compute/network cost at representative data size and change rate. Do not infer production feasibility from a small functional test alone.
