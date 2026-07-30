# Recommended `main` branch rules

When branch rules are available for this repository, create an active ruleset
targeting the default branch with these settings:

- Block branch deletion and force pushes.
- Require changes to arrive through a pull request.
- Require all review conversations to be resolved before merging.
- Require linear history.
- Do not allow bypasses except an explicit maintainer emergency bypass.

For a solo-maintained repository, requiring another person's approval can make
routine maintenance impossible. Start with zero required approvals, then require
one approval and dismiss stale approvals when a regular second reviewer is
available.

Add required status checks only after the corresponding pull-request workflows
run on every relevant pull request. In particular, do not require the current
path-filtered iOS check globally: it is intentionally absent from unrelated
changes. Once available, CodeQL and dependency review should be required checks.
