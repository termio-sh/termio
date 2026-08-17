# Issue drafting templates

Choose the smallest template that communicates the work. Omit headings that
would contain guesses or filler.

## Feature or usability request

```markdown
## Problem

<Who encounters what friction, in what situation, and with what impact?>

## Original request

> <Short verbatim quote or faithful transcription>

## Context

<Verified product/repository context. Separate inference explicitly.>

## Desired outcome

<Observable user outcome, without prescribing an internal implementation.>

## Acceptance criteria

- [ ] <Grounded, testable behavior>

## Open questions

- <Product decision or non-blocking unknown>

## Evidence

<Embedded images and source links>
```

Do not include `Acceptance criteria` when the desired behavior is still a
product decision. Use a discovery issue instead.

## Bug report

```markdown
## Problem

<Concise description of what fails and where.>

## Original report

> <Short verbatim quote or faithful transcription>

## Steps to reproduce

1. <Verified or user-provided step>

## Expected behavior

<Expected result grounded in docs, existing behavior, or the report.>

## Actual behavior

<Observed result.>

## Environment

- Version:
- OS/device:
- Relevant configuration:

## Affected area

<Verified component, file, or workflow.>

## Evidence

<Embedded screenshots, logs, or links.>

## Open questions

- <Missing but non-blocking diagnostic detail>
```

If reproduction or actual-vs-expected behavior is unknowable, ask a focused
question rather than manufacturing steps.

## Discovery issue

```markdown
## Problem

<The validated user need or ambiguity worth resolving.>

## Original request

> <Short verbatim quote or faithful transcription>

## Known context

- <Verified fact>

## Questions to resolve

- <Behavior, scope, or feasibility question>

## Done when

- [ ] <A decision, prototype, or specification exists>
- [ ] <Follow-up implementation work can be scoped honestly>

## Evidence

<Embedded images and source links>
```

## Normalization example

Raw feedback:

> 如果任务完成以后能主动发通知，这个需要配置终端，还是可以集成到软件里？

Grounded transformation:

- **Fact:** the user wants to know when a long-running task has completed.
- **Likely friction (inference):** they may leave the app while waiting and miss
  completion.
- **Desired outcome:** receive a reliable completion signal without monitoring
  the session continuously.
- **Do not assume:** native macOS notification, supported agent list, sounds,
  click-to-focus behavior, or settings UI unless repository context establishes
  those decisions.
- **Possible issue:** use a discovery issue if the notification surface and
  completion signal are still undecided; use a feature issue only when the
  product behavior is already clear.
