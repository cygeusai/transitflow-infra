# Recovering commits from a stranded session (the git-bundle handoff)

A Claude Code session sometimes ends up holding commits it cannot push: the
session was started without the repository attached, the credentials it was
given are read-only, or the push is rejected for a reason that cannot be fixed
from inside the container. The container is ephemeral — when it is reclaimed,
those commits are gone.

A **git bundle** is the escape hatch. It is a single ordinary file containing
real git objects and refs, so it can travel through any channel that moves
files (a chat attachment, cloud storage, email) and be fetched from on the
other side exactly like a remote.

> If the session *can* push, none of this applies. Push the branch and open a
> pull request — that is always the cheaper path.

## Producing the bundle (in the stranded session)

Bundle only the commits the destination is missing. Use a base commit that is
already on `origin/main`, so the file stays small:

```bash
git bundle create handoff.bundle origin/main..main
git bundle verify handoff.bundle    # prints the refs and the prerequisites
```

**Name the branch explicitly — never `HEAD`.** `git bundle create … origin/main..HEAD`
looks equivalent and is not: it records the ref as `HEAD` rather than
`refs/heads/main`, and the receiving fetch then fails with
`fatal: couldn't find remote ref main`. Verify the bundle before handing it
over and check the listing says `refs/heads/<branch>`:

```
The bundle contains this ref:
3f7c69e… refs/heads/main
The bundle requires this ref:
69f5db0…
```

`git bundle verify` run against the *source* clone always reports okay; its
value here is that listing. Note the prerequisite SHA — the destination must
already have that commit, or the fetch will be refused.

The commands below assume the work sits on `main`, matching the
fast-forward-`main` flow this runbook describes. If it sits on a feature
branch, substitute that name in both the `bundle create` range and the
receiving fetch refspec — they have to agree.

If you are unsure what the destination has, make the bundle self-contained
instead. It is larger but it cannot fail on a missing prerequisite:

```bash
git bundle create handoff.bundle main
```

Hand the file to the user. Keep the `.bundle` extension: it is binary, and
some file pickers will mangle a file they mistake for text.

## Option A — recover from a computer

Download the bundle onto any machine that already has a clone with push
rights, then fetch from the file and push. Fewest steps, but it needs a
computer.

## Option B — genuinely phone-only

More steps than Option A, but it works from a phone:

1. Download the bundle to the phone.
2. Start a **new** Claude Code session with `cygeusai/transitflow-infra` as its
   repository. Because the session is created against the repo, it has push
   rights from the start — this ordering is what makes the trick work.
3. Attach the bundle to that session.
4. Tell it: *fetch from the attached bundle and fast-forward `main`, then push.*

### What the receiving session should run

Attachments land under `/mnt/attach` in the web and mobile containers; confirm
the path rather than assuming it.

```bash
ls /mnt/attach

# Refuse early if the clone is shallow — a fast-forward will not resolve.
git rev-parse --is-shallow-repository        # must print false

git bundle verify /mnt/attach/handoff.bundle
git fetch /mnt/attach/handoff.bundle main:refs/remotes/bundle/main
```

Read what arrived before merging it. A bundle is arbitrary code from outside
the repository's review path:

```bash
git log --oneline origin/main..refs/remotes/bundle/main
git diff origin/main..refs/remotes/bundle/main
```

Then fast-forward and push:

```bash
git checkout main
git merge --ff-only refs/remotes/bundle/main
git push -u origin main
```

`--ff-only` is not optional. If it refuses, `main` has moved since the bundle
was cut and the history has genuinely diverged; rebase the bundled commits
onto the current `main` rather than forcing a merge commit through this path.

## Caveats worth knowing before you rely on this

- **`git bundle verify` failing on a prerequisite** — it reports
  `error: Repository lacks these prerequisite commits:` — means the destination
  is missing a commit the thin bundle assumed. Re-cut the bundle self-contained
  (`git bundle create handoff.bundle main`); do not try to fetch past it.
- **The direct push to `main` is the part most likely to be refused.**
  `CONTRIBUTING.md` describes `main` as protected and pull-request-only. Where
  that protection is enforced, land the bundled commits on a branch and open a
  pull request instead:

  ```bash
  git checkout -b recover/<what-it-is> refs/remotes/bundle/main
  git push -u origin recover/<what-it-is>
  ```

  This is the safer default regardless: it puts the recovered work through CI
  and review, which is exactly what a commit arriving by file attachment
  deserves.
- **Attachment size limits** apply to the surface you are uploading through. A
  self-contained bundle of a repository with long history can exceed them,
  which is the argument for cutting a thin bundle against `origin/main`
  whenever you know the destination has the base commit.
- **The source container is ephemeral.** Produce the bundle and get it off the
  container before the session goes idle. There is no second chance to cut it.
