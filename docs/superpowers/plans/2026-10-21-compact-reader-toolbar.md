# Compact Reader Toolbar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Implement the approved two-row reading header while retaining every existing reading, filtering, sync and navigation action.

**Architecture:** Keep the existing Swift/WKWebView application and all message rendering and anchor state. Reorganize existing DOM controls, add one focused compact-toolbar controller and stylesheet, and connect it to existing render/transition hooks. Validate the resulting native web view, then build and install the full application.

**Tech Stack:** HTML, CSS, vanilla JavaScript, AppKit/WKWebView, Swift integration harness, Node test runner.

---

### Task 1: Compact header, filters and floating reading controls

Files: `Resources/ui/index.html`, `Resources/ui/app.js`, new `Resources/ui/compact-reader.css` and `Resources/ui/compact-reader.js`; new `tests/compact-reader.test.cjs` when pure behavior warrants tests.

- [x] Verify clean baseline and continue in the dedicated project checkout on `codex/v1.0.12-compact-reader`.
- [x] Move existing controls without changing their IDs or message rendering; replace the large standby cap with a compact version scoped to the chat header.
- [x] Add accessible sync and filter popovers. Bind truthful status to `renderSyncStatus`, active filter descriptions to `renderReader`, and close transitions to `setGroup`, `setView`, `setMode`, `enterStandby` and account reset. Existing `coverage-action`, `manual-position` and `return-position` handlers remain authoritative.
- [x] Ensure desktop ordering and two-row narrow behavior; popovers fit viewport; floating navigation reserves message clearance and moves above a visible selection bar.
- [x] Run focused existing Node tests and new behavioral tests. Review specification compliance, then code quality; resolve all significant findings.

### Task 2: Native integration and visual validation

Files: new `tests/CompactReaderUIHarness.swift`, `scripts/test-compact-reader-ui.sh`; `design-qa.md` and `docs/verification-v112.md`.

- [x] Derive native test setup from `tests/ReadingRefinementUIHarness.swift`; use isolated synthetic data and production resources.
- [x] At reading pane widths 1024, 820, 650 and 430 CSS px assert no horizontal overflow, no overlaps, compact row heights and visible navigation. Exercise menu keyboard/close paths, all filter kinds, clear, anchors, new messages, mode and group changes, standby and selection bar.
- [x] Capture light/dark and menu states; compare reference and implementation together at normalized dimensions. Record all differences, fixes and post-fix evidence in `design-qa.md`.
- [x] Run `bash scripts/test.sh`, `bash scripts/test-reading-refinement-ui.sh`, the new native harness, and additional focused regressions only when relevant failures justify them.

### Task 3: Package and install 1.0.12 (18)

Files: `scripts/build.sh`, `scripts/package-release.sh`, `docs/install-and-build.md`, `docs/compact-reader-v112.md`, `docs/verification-v112.md`.

- [x] Bump version to 1.0.12 and build to 18; list the new files in source export; update local release notes.
- [ ] Build arm64 and x86_64 with `bash scripts/build.sh`; verify signature and architectures; package with `bash scripts/package-release.sh --skip-build`.
- [ ] Verify source manifest, packaged resource identity, privacy allowlist, both app archives and hashes. Back up and normally quit the installed application, replace it, start the new app and verify the launched path, version, code signature and resource hashes.
- [ ] Commit completed source, documentation and verification evidence. Report the installed version, concrete layout changes and any remaining limitation.
