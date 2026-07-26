<!--
  Posted automatically on every newly opened pull request by
  .github/workflows/pr-acknowledgement.yml

  EDIT THIS FILE to change what contributors are told. Blank it out to stop
  posting acknowledgements entirely — no workflow change needed.

  Keep it short, and keep it honest about what happens next. A promise of a
  timeline you will not meet is worse than no acknowledgement at all.
  Remove the review-status section below the moment it stops being true.
-->

Thanks for opening this — it has been seen, and it is queued.

This note is automated, but it is not a brush-off: it exists so you know where your PR stands instead of having to guess from silence.

**Current review status: reviews are running behind.** We are finishing release-critical work for `0.9.1-rc.1` — a coordination daemon that changed how the whole system runs, and the root-cause fix for a severe Windows memory leak ([#581](https://github.com/DeusData/codebase-memory-mcp/issues/581)) that could exhaust a machine's commit charge over hours. Those changes cross the memory allocator, thread lifecycle, and the store-resolution path that every tool call runs through, so merging other work on top of them while they settle would leave neither change trustworthy. The full explanation is in [discussion #1144](https://github.com/DeusData/codebase-memory-mcp/discussions/1144).

What that means for this PR, concretely:

- **It will not be closed for inactivity.** No stale bot touches pull requests here.
- It may sit longer than it should before a human reads it. That is on us, not on you.
- Review resumes once the release path is clear.

Things that will genuinely speed it up whenever review does happen:

- **Keep it rebased** on `main` — the tree is moving quickly right now, and a conflicting branch cannot be reviewed as the diff you intended.
- **Get CI green**, or say which failures you believe are pre-existing.
- **Keep the change to one claim.** Bundled features and refactors get split before they get merged, which costs you a round trip.
- Every commit needs a sign-off (`git commit -s`) — CI enforces DCO.

If this fixes a bug, a reproduction we can run is worth more than a description of the symptom.

Thanks for contributing, and sorry in advance for the wait.
