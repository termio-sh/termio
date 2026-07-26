---
name: feedback-to-issue
description: "Turn vague customer or user feedback from pasted text, chat excerpts, or screenshots into a clear, evidence-backed GitHub issue without inventing requirements. Use when the user says 'create an issue for this', 'turn this user request into an issue', 'file this feedback', '用户反馈建 issue', '把这个模糊需求变成 issue', '把这段聊天/截图建成 GitHub issue', or invokes /feedback-to-issue."
---

# Vague user request → actionable GitHub issue

Preserve the user's voice, identify the underlying problem, add only grounded
repository context, and create the smallest honest issue that moves the work
forward. Never turn missing information into confident requirements.

## Workflow

### 1. Normalize the raw input

Handle all three input modes:

- **Pasted text:** preserve the most useful original sentence verbatim.
- **Screenshot:** inspect both visible text and UI context. Transcribe only what
  is legible and mark uncertainty. Keep the original image for `Evidence`.
- **Mixed:** treat the pasted explanation as context and the screenshot as
  primary evidence unless they conflict; surface any conflict.

Build a private scratch intake before drafting:

| Field | Extract |
|---|---|
| Actor | Who experiences this? |
| Situation | When and where does it happen? |
| Friction | What is hard, broken, or missing now? |
| Desired outcome | What should the user be able to achieve? |
| Impact | Why does it matter? |
| Explicit constraints | What did the user actually require? |
| Unknowns | What remains unclear? |

Do not force the request into “As a user, I want…” language. Preserve a direct
quote when it expresses the pain better than a summary.

If the message is phrased as a question, identify the latent need but first
check whether existing behavior or documentation already answers it. Do not file
a feature request for something the product already supports.

### 2. Resolve repository conventions

Use an explicitly named repository; otherwise resolve the current checkout:

```bash
gh auth status
gh repo view --json nameWithOwner,defaultBranchRef,visibility,hasIssuesEnabled
gh issue list --state all --limit 10 --json number,title,state,url
rg --files -g 'CONTRIBUTING*' -g '.github/ISSUE_TEMPLATE/**'
```

Read any relevant issue template or contributing guide. Match the repository's
language, headings, title style, and metadata conventions. Do not invent labels,
types, milestones, or assignees.

### 3. Ground the request in the product

Do light, targeted exploration using nouns, UI labels, errors, and capability
names from the intake. Search README/docs first, then likely code:

```bash
rg -n -i 'user phrase|normalized capability|visible UI label' \
  README.md docs Sources Shared ios web 2>/dev/null
```

Stop when there is enough context to name the affected area, identify existing
behavior, or determine that this is a product-level discovery request. Code
exploration is context gathering, not implementation planning.

### 4. Apply the clarification gate

Ask at most three focused questions, and only when an answer would change one of:

- whether an issue should exist;
- bug vs feature/discovery classification;
- the core problem or desired outcome;
- reproduction of a bug;
- a material scope boundary;
- whether evidence is safe to publish.

First try to answer gaps from the screenshot, repository, docs, and related
issues. Do not ask the user to design the solution or manufacture acceptance
criteria. Put non-blocking uncertainty in `Open questions` and continue.

### 5. Classify honestly

| Type | Use when |
|---|---|
| Bug | Existing behavior contradicts expected or documented behavior |
| Feature/usability | A clear user outcome is unsupported or unnecessarily hard |
| Discovery | The need is real but the right behavior or scope still requires investigation |
| No new issue | Existing behavior/docs solve it, or a strong duplicate already tracks it |

When feedback is too broad for an implementation issue, create a bounded
discovery issue such as “Define task-completion notification behavior” instead
of inventing a complete solution.

### 6. Search for duplicates

Run separate searches using:

1. the user's exact phrase;
2. the normalized product capability;
3. the symptom or desired outcome.

```bash
gh issue list --repo OWNER/REPO --state all \
  --search 'query in:title,body' --limit 20 \
  --json number,title,state,url
```

If a strong duplicate exists, return it instead of creating another issue. If
the overlap is partial, create the new issue and link the related one.

### 7. Draft a problem-first issue

Read [references/templates.md](references/templates.md), choose the matching
template, and omit empty sections.

Follow these rules:

- Write a direct, scannable title under 72 characters.
- Separate original evidence, verified facts, and inference.
- Describe the problem and desired outcome before any possible solution.
- Include the user's original words as a short quote when useful.
- Add file/component references only when verified by repository exploration.
- Write acceptance criteria only for observable behavior supported by the
  request or established product conventions.
- Put unresolved product decisions under `Open questions`.
- Keep one issue focused on one outcome; split independent requests.

### 8. Attach evidence when present

If the input includes one or more images, read
[references/images.md](references/images.md) and follow its privacy, upload, and
verification workflow. Do not silently drop an image.

### 9. Create and verify

Before any GitHub write, state the exact repository, proposed title, and any
image asset path. Prepare the final Markdown body outside the repository, then:

```bash
gh issue create --repo OWNER/REPO \
  --title 'Concise problem or outcome' \
  --body-file /absolute/path/to/temporary-issue-body.md
```

Use an existing issue type or label only after confirming it exists. Then verify
the returned issue:

```bash
gh issue view ISSUE_NUMBER --repo OWNER/REPO \
  --json number,title,state,url,body,labels
```

Confirm the intended repository, title, body, evidence links, and metadata.
Return the issue URL plus any assumptions or open questions retained in it.

## Quality gate

Do not create the issue until all applicable checks pass:

- The original request is represented faithfully.
- The core problem and desired outcome are understandable.
- Facts and inference are distinguishable.
- No behavior, scope, or acceptance criterion was invented.
- Existing docs/code and likely duplicate issues were checked.
- The issue is actionable, or explicitly scoped as discovery.
- Supplied evidence is embedded and safe for the repository's visibility.
- The issue follows repository templates and conventions.
