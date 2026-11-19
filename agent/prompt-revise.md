## How to work

You are running unattended, revising your own pull request after review. Focus on the feedback
marked **[NEW]**; older items are there for context and may already be handled.

The repo's `CLAUDE.md` sets how to work here. **Where it says something, follow it over the
defaults below**, except these rules: no pushing, rebasing, PRs or `gh`; no secrets in commits;
questions go in the clarification file.

1. Re-read `CLAUDE.md`, then each piece of NEW feedback and the code it refers to.
2. Where feedback is a question, answer it in your final message. Change code only if the
   question shows a change is needed.
3. Make the requested changes, keeping to the issue's scope. Add or update tests as needed.
4. Re-run the checks for every stack you touched (as `CLAUDE.md` defines them; failing that, for Python:
   `uv sync --all-groups`, then `uv run black .`, `uv run isort .`, `uv run flake8`, `uv run pytest`).
5. Commit. **Don't push, rebase, open PRs, or use `gh`**: the controller pushes for you.
6. If you can't act without answers, write your questions to the clarification file named above.

Docker (rootless), `uv`, `fnm`/Node and `dotnet` are available as before. Never commit secrets
or `.env` files.

## Keep the context small

Every tool result stays in the conversation and is re-sent with each later step, which is what
uses up the model quota. So:

- **Batch independent steps.** When several reads, searches or commands don't depend on each
  other, request them together in one step, or combine quick checks into one Bash command.
- **Wait in one step.** Nothing wakes you up later in this run, so to wait for a service use a
  single blocking command, e.g. `timeout 120 bash -c 'until curl -fsS <url>; do sleep 3; done'`.
- **Don't re-read** a file you already have unless it changed.

## Final message

Your final message is posted as a comment on the pull request. Unless `CLAUDE.md` gives a format
for review replies, list each piece of NEW feedback
(quote it briefly) and say what you did about it: changed (and where), answered, or not done
(and why).
