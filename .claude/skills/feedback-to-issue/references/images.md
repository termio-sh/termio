# Images in GitHub issues

Read this reference only when the user supplies an image.

## 1. Inspect and protect

Inspect both textual and visual evidence. Record:

- legible text, preserving the original language;
- relevant UI state, error messages, and visible controls;
- uncertainty where text is cropped or unreadable.

Check repository visibility before uploading. For a public repository, stop and
ask before publishing names, account details, tokens, private URLs, customer
identifiers, or confidential conversations.

If the image is visible in the conversation but has no accessible local file,
use a browser attachment flow if available. Otherwise ask the user for a saved
file path; do not silently omit the evidence.

## 2. Choose an upload method

Prefer these methods in order:

1. **GitHub browser attachment:** paste or upload into the issue editor to get a
   permanent `github.com/user-attachments/assets/...` URL.
2. **Contents API fallback:** upload to the same repository's dedicated
   `issue-assets` branch without touching the default branch or current
   worktree.

Standard `gh issue create` cannot upload a local attachment. Do not use a local
filesystem path, `data:` URI, third-party image host, temporary API
`download_url`, or `raw.githubusercontent.com` URL for a private repository.

## 3. Upload through the Contents API

Before writing, state the exact repository, asset branch, and unique ASCII asset
path. Reuse `issue-assets`; never overwrite existing evidence.

```bash
request_repo='OWNER/REPO'
request_asset_branch='issue-assets'
request_image='/absolute/path/to/evidence.png'
request_asset_path='.github/issue-assets/YYYYMMDD-unique-description.png'

request_default_branch=$(
  gh repo view "$request_repo" --json defaultBranchRef \
    --jq '.defaultBranchRef.name'
)

if ! gh api \
  "repos/$request_repo/git/ref/heads/$request_asset_branch" >/dev/null 2>&1
then
  request_default_sha=$(
    gh api "repos/$request_repo/git/ref/heads/$request_default_branch" \
      --jq '.object.sha'
  )
  gh api --method POST "repos/$request_repo/git/refs" \
    -f ref="refs/heads/$request_asset_branch" \
    -f sha="$request_default_sha"
fi

base64 < "$request_image" | tr -d '\n' |
  jq -Rs \
    --arg message "docs: add feedback-to-issue evidence" \
    --arg branch "$request_asset_branch" \
    '{message:$message, content:., branch:$branch}' |
  gh api --method PUT \
    "repos/$request_repo/contents/$request_asset_path" --input -
```

Embed the stable authenticated repository URL:

```markdown
![User request](https://github.com/OWNER/REPO/raw/issue-assets/.github/issue-assets/YYYYMMDD-unique-description.png)
```

For a private repository, viewers must have repository access. Such images may
not render in email notifications.

## 4. Verify

Verify remote and local hashes:

```bash
gh api \
  "repos/$request_repo/contents/$request_asset_path?ref=$request_asset_branch" \
  --jq .content |
  tr -d '\n' | base64 -d | shasum -a 256

shasum -a 256 "$request_image"
```

After issue creation, confirm that every supplied image appears in the Markdown
body. If upload succeeds but issue creation fails, retry or report the orphan
asset path explicitly.
