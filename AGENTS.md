# DaysWith execution rules

These rules record Henry's 2026-11-03 instruction to hand off the Mac workspace
and continue development in the cloud. Apply them to every task in this repository.

## Execution location

- Use the managed cloud environment by default for editing, reviews, tests,
  dependency installation, backend work, and Android builds.
- Do not use, contact, wake, or start work on Henry's Mac automatically. Use a Mac
  only for a necessary Xcode/iOS build or device acceptance step when that step
  has been authorized. Missing cloud tooling is a setup blocker, not permission
  to move a build onto the user's computer.
- Before an authorized Mac step, check disk space, memory, and running work;
  limit concurrency and report the specific local requirement. Preserve work
  before any environment transition.

## Handoff and recovery

- Preserve existing work. Verify repository identity, exact base commit, working
  tree, handoff byte size and SHA-256 before applying a handoff.
- Inspect archive member paths, symlinks, size limits and potential secrets before
  safe extraction. Validate the manifest and every recovered file independently.
- Use the current supported Library transfer flow. A remote file reference or
  a Mac path is not proof that bytes exist in the cloud. Stop a blocked transfer
  after its permitted bounded retry; report the exact failure without bypassing
  permissions or network policy.
- Read the recovered requirements, schedule, test evidence and execution rules
  before implementing changes. Preserve narrower recovered instructions too.

## Resources and validation

- Check disk and memory before builds. Run one large build at a time, use at most
  two test workers initially, and bound Gradle workers and memory for the actual
  cloud budget. Stop resource-heavy work if space becomes insufficient.
- Distinguish current test results from historical results and synthetic-data
  tests from real storage/device acceptance. Do not report a release as verified
  when its required build or acceptance step did not run.
- Record Xcode-dependent work as pending when Xcode is unavailable. Do not switch
  to the Mac to hide a cloud setup or transfer failure.

## Authorization and data

- Development, testing, local commits and recovery deliverables are authorized.
  Push, PR creation, merge, deployment, purchases, and persistent production
  credentials or privilege changes require explicit authorization.
- Use isolated synthetic data for family invitation and access-control tests.
  Do not upload real family data, delete original photos, or destructively migrate
  old archives. Do not print or package credentials, caches or private media.
