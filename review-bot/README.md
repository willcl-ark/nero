# Draft pull request reviewer

This small service accepts Forgejo `pull_request` webhooks for
`https://git.fish.foo/bitcoin/bitcoin`. It fetches the base branch and PR head
from that fixed origin, checks out the head in its own directory, and reviews
the full PR diff and commit messages. It writes Markdown drafts under
`STATE_DIR/drafts`. It never posts to Forgejo or runs PR code.

Run with Python 3.9 or newer and Git:

```sh
python3 bot.py --listen 127.0.0.1 --port 8765 \
  --state-dir /var/lib/review-bot \
  --openai-key-file /run/secrets/openai-api-key \
  --webhook-secret-file /run/secrets/review-bot-webhook-secret
```

Set the Forgejo webhook to `POST` JSON to
`https://YOUR_HOST/webhooks/forgejo`. Set a long random secret in Forgejo and
the same value in the webhook secret file. Select custom pull request events.
The receiver accepts `opened`, `reopened`, and `synchronize` actions. It also
accepts `synchronized` for Forgejo variants. It
validates `X-Forgejo-Signature` against the raw body before parsing JSON.

The bot skips a review when the fetched head no longer matches the webhook
head or when the diff and commit messages exceed 200,000 bytes. These skips
get a local draft explaining why. Existing drafts prevent repeated API calls
for the same PR head. A failed fetch or API call is logged without
including keys or patch content. Each request uses `gpt-6-sol` with
`store: false` and no tools.

Run local tests with `python3 -m unittest discover -s review-bot -p 'test_*.py'`.
