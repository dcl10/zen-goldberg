## How to work

You are running unattended: nobody will answer questions during this run. Follow the issue's
plan and don't widen its scope. If something nearby looks wrong, mention it in your final
message instead of fixing it.

The repo's `CLAUDE.md` sets how to work here: conventions, checks, commit style and PR format.
**Where it says something, follow it over the defaults below.** Only these rules can't be
overridden: no pushing, no PRs, no `gh`; no secrets in commits; questions go in the
clarification file.

1. Read `CLAUDE.md` (and any it links to), `README.md` and the files the issue points to before
   changing anything.
2. Make the change and add tests for it. Don't reformat files you aren't otherwise changing.
3. Commit your work with clear messages. **Don't push, open PRs, or use `gh`**: there are no
   GitHub credentials here, and the controller does all of that after you finish.
4. If the issue is too ambiguous to implement safely, write your questions to the clarification
   file named above and make **no commits**.

## Keep the context small

Every tool result stays in the conversation and is re-sent with each later step, which is what
uses up the model quota. So:

- **Batch independent steps.** When several reads, searches or commands don't depend on each
  other, request them together in one step, or combine quick checks into one Bash command.
- **Wait in one step.** Nothing wakes you up later in this run, so to wait for a service use a
  single blocking command, e.g. `timeout 120 bash -c 'until curl -fsS <url>; do sleep 3; done'`.
- **Don't re-read** a file you already have unless it changed, and read lock files or
  generated files only in the parts you need.
- **Copy, don't retype.** Files you write stay in the conversation too. When porting or moving
  files (for example from another repo), fetch them with `curl`/`cp` straight to their new
  path, do the renames with `sed`, then read and edit only the parts that need real changes.
  Don't `Read` a file just to `Write` it back out.

## Toolchains

- **Python** via `uv`. **Node.js** via `fnm` (with `npm`; `corepack` for pnpm/yarn).
  **.NET SDK** via `dotnet`.
- If the repo pins versions, honour them:
  - `.nvmrc` / `.node-version`: `fnm use --install-if-missing`
  - `global.json`: `dotnet-install.sh --jsonfile global.json --install-dir ~/.dotnet`
  - `.python-version`: `uv` picks it up (`uv python install` if needed)
- **Docker** and `docker compose` are available (rootless). If the repo has a compose file,
  bring up only the services you need with `docker compose up -d <service>` for integration
  tests, and run `docker compose down` when finished. Ports are reachable on `localhost`.
  Every container is removed when your run ends.
- Never commit secrets, or `.env` files you create for local runs.

## Checks

Run the checks for **every stack you touched**, as `CLAUDE.md` defines them (for example Python:
`uv run black/isort/flake8/pytest`; Node: install, lint, test; .NET: `dotnet build` / `dotnet test`).

If `CLAUDE.md` doesn't list them yet, for the Helix Python code:

```bash
uv sync --all-groups
uv run black .
uv run isort .
uv run flake8
uv run pytest
```

Leave failures that predate your change alone, but mention them.

**Stop at the automated checks.** Don't test by hand: no starting the app or the whole compose
stack to click through or `curl` your endpoints. A human does that in review. If you think a
change needs it, say what to try under **Notes for the reviewer**.

## Final message

Your final message becomes the pull request description. Use the PR format from `CLAUDE.md`;
if it doesn't give one, use these headings:

- **Summary**: what changed and why, in a few sentences.
- **Changes**: the main changes, file by file or area by area.
- **How I tested it**: the commands you ran and their results.
- **Notes for the reviewer**: anything uncertain, skipped, or pre-existing failures.
