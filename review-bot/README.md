# Pull request reviewer

This service accepts Forgejo `pull_request` webhooks for
`https://git.fish.foo/bitcoin/bitcoin`. It fetches the base branch and PR head
from that fixed origin, checks out the head in its own directory, and reviews
the PR title, description, full diff, and commit messages. The model can read
full files in bounded chunks and search tracked text at that PR head to follow
functions and callers.
The review also checks for concrete, behavior-preserving simplifications.
It posts one comment from the configured bot account per PR. Later reviews edit
that comment only when its content changes. It never builds, runs, or tests PR
code; CI owns those checks.

Run with Python 3.9 or newer and Git:

```sh
python3 bot.py --listen 127.0.0.1 --port 8765 \
  --state-dir /var/lib/review-bot \
  --openai-key-file /run/secrets/openai-api-key \
  --webhook-secret-file /run/secrets/review-bot-webhook-secret \
  --forgejo-token-file /run/secrets/forgejo-review-bot-token \
  --bot-login review-bot
```

The Forgejo token must belong to `--bot-login`, be restricted to
`bitcoin/bitcoin`, and have `write:issue` for comments and PR metadata. The
service finds its comment using both the account name and a hidden marker.
It searches comment pages before creating one, stops if the mirror repeats a
page, and ignores a matching marker written by another account.

Set the Forgejo webhook to `POST` JSON to
`https://YOUR_HOST/webhooks/forgejo`. Set a long random secret in Forgejo and
the same value in the webhook secret file. Select custom pull request events.
The receiver accepts `opened`, `reopened`, `synchronize`, and `synchronized`
actions. It validates `X-Forgejo-Signature` against the raw body before
parsing JSON.

The bot skips a review when the fetched head no longer matches the webhook
head. It also checks the current `refs/pull/NUM/head` Git ref immediately before
posting. If the PR text, diff, and commit messages exceed 200,000 bytes, its
comment says the review was skipped. A failed fetch or API call is logged
without keys or patch content. Each request uses `gpt-6-sol` with
`store: false` and two read-only repository tools. A review allows at most
12 tool calls across eight model turns. A repeated webhook for an already
reviewed head skips the model call. An unchanged review never edits the comment.

Each new comment includes a collapsed public debug section with the request
settings and prompt, request and response hashes, tool calls, timing, token
usage, and an estimated model cost. It omits API credentials, PR text, the
patch, and file contents. The cost uses published `gpt-6-sol` Standard rates
and may differ from the billed amount.

Run local tests with `python3 -m unittest discover -s review-bot -p 'test_*.py'`.
