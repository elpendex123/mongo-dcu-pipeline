# Phase 0 - Repository

**What this phase built:** a git repository, a public GitHub repository, the
README, and the rule about what is deliberately excluded from both.

## 1. The repository exists and is clean

```bash
# variable form
cd $PROJECT_ROOT
git log --oneline
git status --short

# expanded
cd ~/Documents/PROJECTS/mongo-dcu-pipeline
git log --oneline
git status --short
```

Expect commits on `main`, oldest being `Initial commit: project README and
gitignore`, and an empty `git status`.

## 2. It is public, and the README renders

```bash
gh repo view elpendex123/mongo-dcu-pipeline --json name,visibility,url
gh repo view elpendex123/mongo-dcu-pipeline --web
```

Expect `"visibility": "PUBLIC"`. In the browser, the README's Mermaid flow
diagram should draw as a diagram rather than appear as a code block.

## 3. The local working documents are excluded, and so is the exclusion

Some planning documents are kept in the working directory but deliberately not
published. They must be untracked - **and** the mechanism excluding them must
not itself be published, since a `.gitignore` entry announces the name of every
file it names. See issue 1 in [ISSUES.md](../ISSUES.md).

The names are read from the exclude file rather than written out here, for the
same reason:

```bash
# variable form
git check-ignore -v $(grep -v '^#' .git/info/exclude | grep -v '^[[:space:]]*$')

# expanded - same command; the file supplies the names
```

Expect every one of them to be matched by `.git/info/exclude` and **not** by
`.gitignore`. Then confirm none of those names appears in anything published:

```bash
for name in $(grep -v '^#' .git/info/exclude | grep -v '^[[:space:]]*$'); do
  git grep -qi "$name" -- . && echo "PUBLISHED: $name"
done
echo "check complete"
```

Expect only `check complete`.

## 4. Nothing published carries tool attribution

```bash
git grep -riE 'co-authored|generated with|assisted by' -- .
git log --format='%B' | grep -riE 'co-authored|generated with'
```

Both should produce no output. This covers tracked content and commit messages,
which is everything a reader of the public repository can see. Extend the
pattern with any vendor or tool name that should stay out.

## 5. The provider lock file is tracked

Issue 2 in [ISSUES.md](../ISSUES.md).

```bash
git ls-files | grep terraform.lock.hcl
```

Expect at least `terraform/bootstrap/.terraform.lock.hcl`. A lock file is
committed; the `.terraform/` cache beside it is not.

## Pass criteria

- [ ] `main` has commits and a clean working tree
- [ ] Repository is public and the README diagram renders
- [ ] The local working documents are excluded via `.git/info/exclude`, not `.gitignore`
- [ ] None of their names, and no tool attribution, appears in tracked content or history
- [ ] `.terraform.lock.hcl` is tracked, `.terraform/` is not
