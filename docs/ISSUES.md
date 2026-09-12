# Issues encountered

A running record of what went wrong while building each phase, what was
actually wrong underneath it, and how it was fixed. Kept because most of these
are the kind of problem that looks obvious in hindsight and costs an hour in
the moment - and because several of them will recur in later phases where the
same pattern applies to a different service.

| # | Phase | Issue | Caught by |
|---|---|---|---|
| 1 | 0 | `.gitignore` published the name of a file that was meant to be private | Review before push |
| 2 | 1 | Terraform provider lock file was being ignored | Terraform said so on `init` |
| 3 | 2 | Status script crashed on an empty bucket | Running it on a real empty bucket |
| 4 | 3 | Chained `.sort()` / `.limit()` were never recognised | Smoke test on write |
| 5 | 4 | Container could not read AWS credentials | First container run |
| 6 | 4 | Log file silently never written | Checking the file rather than assuming |
| 7 | 4 | Reports omitted every line that did not fail | Reading the first failure report |
| 8 | 5 | The tag query that teardown will use also matches the state bucket | Reading the tag query output after applying the shared stack |

---

## Variables used on this page

```bash
export PROJECT_ROOT=~/Documents/PROJECTS/mongo-dcu-pipeline
export EDITOR=vim          # or nano, code -w, whatever you use
```

| Variable | Example value | Where it comes from |
|---|---|---|
| `PROJECT_ROOT` | `~/Documents/PROJECTS/mongo-dcu-pipeline` | Wherever you cloned the repository |
| `EDITOR` | `vim` | Your own preference. Usually already set |
| `HOME` | `/home/enrique-coello` | Set by the shell. Shown here because a container has its own `HOME`, which is the whole subject of issue 5 |
| `APP_UID` / `APP_GID` | `1000` | **Your own**, from `id -u` and `id -g` - the subject of issue 5 |

`$bucket` and `$name` appear inside snippets below as loop variables. They are
set by the `for` line immediately above them and are not something to set
yourself.

---

## 1. The exclusion list published the thing it was excluding

**Phase 0.**

**Symptom.** Nothing broke. The repository worked exactly as intended - the two
local working documents were untracked and would never be pushed.

**What was actually wrong.** The mechanism for excluding them was `.gitignore`,
which *is* pushed. A `.gitignore` naming a file announces that file's name to
everyone who reads the repository, which for a public portfolio repository
defeats the point of excluding it.

**Fix.** The exclusions moved to `.git/info/exclude`, which is local to the
clone and never pushed, and the single existing commit was amended so the names
were absent from history too rather than merely from the current tree.

```bash
# append the filenames to the local-only exclude list
$EDITOR .git/info/exclude
git rm --cached <the files>
git commit --amend
git push --force-with-lease
```

The same trap caught this document later: a guide describing how to verify the
exclusion spelled the filenames out, which republished exactly what the
exclusion exists to keep private. Anything that *describes* a private name is
as public as the name itself - so the guides refer to "the local working
documents" and derive the names from the exclude file at run time.

**Generalises to.** `.gitignore` is for exclusions that are part of the
project - build output, dependencies, state files. `.git/info/exclude` is for
exclusions that are personal to one clone. The distinction is not about
effectiveness, it is about who is meant to see the rule.

**Cost of not catching it.** The amend was possible because the repository had
exactly one commit and no other clone. A day later it would have meant
rewriting pushed history.

---

## 2. The Terraform provider lock file was being ignored

**Phase 1.**

**Symptom.** `terraform init` finished with a note:

```
Terraform has created a lock file .terraform.lock.hcl to record the provider
selections it made above. Include this file in your version control repository
```

**What was actually wrong.** `.gitignore` had `.terraform.lock.hcl` sitting
next to `.terraform/`, which looks reasonable and is not. `.terraform/` is a
download cache and should never be committed. The lock file is the opposite: it
records exactly which provider builds were resolved, so every machine and every
CI run gets the same ones.

**Fix.** Removed from `.gitignore`, with the reason written next to it so it is
not re-added by whoever tidies the file next:

```gitignore
.terraform/
# .terraform.lock.hcl is deliberately NOT ignored - it pins provider
# versions so every apply resolves the same ones.
```

**Generalises to.** Lock files are committed; caches are not. The same applies
to `requirements.txt` pins, `Chart.lock`, and anything else whose job is
reproducibility.

---

## 3. The status script crashed on an empty bucket

**Phase 2.**

**Symptom.** `dev-s3-status.sh` printed `None` for the object count of the one
bucket that had a file in it, then died on the next bucket:

```
aws: [ERROR]: In function sum(), invalid type for value: None,
expected one of: ['array-number'], received: "null"
```

**What was actually wrong.** Two problems in one line of JMESPath:

```bash
--query '[KeyCount, sum(Contents[].Size) || `0`]'
```

An empty bucket's `list-objects-v2` response has **no `Contents` key at all**,
so `Contents[].Size` is null and `sum(null)` raises before the `|| 0` fallback
can do anything - the fallback only applies to a value, not to an error. And
`KeyCount` was not surviving the multi-select the way it appeared to.

**Fix.** Fetch the response once and let `jq` handle the absent key, which it
does properly with `//`:

```bash
read -r count size < <(
  aws s3api list-objects-v2 --bucket "$bucket" --output json |
    jq -r '[(.Contents // [] | length), (.Contents // [] | map(.Size) | add // 0)] | @tsv'
)
```

**Generalises to.** An AWS API response omits empty collections rather than
returning an empty one, and JMESPath has no null-safe default for a function
argument. This will appear again in `status.sh` in Phase 6, across more
services - anywhere the answer could legitimately be "none".

**Why it was caught.** The script was run against a freshly created, genuinely
empty bucket set. Had it only ever been run against buckets with files in them,
it would have failed the first time it mattered.

---

## 4. Chained `.sort()` and `.limit()` were never recognised

**Phase 3.**

**Symptom.** A valid line was rejected at the shape stage:

```
db.properties.find({ state: "VA" }).sort({ listing_price: -1 }).limit(10)
  -> expected a chained call such as .limit(10) or .sort({...}) (col 36)
```

**What was actually wrong.** The pattern was anchored:

```python
_CHAIN_RE = re.compile(r"^\.(?P<name>[A-Za-z][A-Za-z0-9_]*)\s*\(")
```

and was applied part-way through the line with `_CHAIN_RE.match(text, index)`.
The `pos` argument to `match()` anchors the match at that position, but `^`
still means *start of string*. With `pos > 0` the two conditions can never both
hold, so the chain branch was unreachable - and the error message it produced
pointed at a perfectly correct character.

**Fix.** Dropped the `^`, since `match()` already anchors:

```python
# No ^ anchor: this is matched at a position part-way through the line, and
# ^ would only ever match at index 0.
_CHAIN_RE = re.compile(r"\.(?P<name>[A-Za-z][A-Za-z0-9_]*)\s*\(")
```

**Generalises to.** `re.match(s, pos)` and `^` do different things, and using
both is almost always a bug. `\A` has the same trap.

**Why it was caught immediately.** The valid-line smoke list included a chained
query from the start. A test suite written only against the cases the code was
designed for would have passed.

---

## 5. The container could not read AWS credentials

**Phase 4.** Two overlapping causes, which is why the first fix did not work.

**Symptom.**

```
botocore.exceptions.NoCredentialsError: Unable to locate credentials
```

despite `~/.aws` being mounted into the container and the same credentials
working fine on the host.

**Cause A - wrong path.** The mount target was `/home/appuser/.aws`, but the
container user's home directory is `/app` (`useradd --home-dir /app`). The SDK
looks under `$HOME`, so it was searching `/app/.aws`, which did not exist.

**Cause B - the real one.** `~/.aws/credentials` is mode `0600`, owned by host
uid 1000. The container ran as uid 1001. A read-only bind mount does not change
that: **the file's own permissions still apply inside the container**, and uid
1001 cannot read a 0600 file owned by uid 1000. Fixing the path alone would
have changed the error, not removed it.

**Fix.** Make the container's uid a build argument and have Compose build with
the host's uid, so the container user *is* the file's owner:

```dockerfile
ARG APP_UID=1001
ARG APP_GID=1001
RUN groupadd --gid ${APP_GID} appuser \
 && useradd --uid ${APP_UID} --gid ${APP_GID} --home-dir /app appuser
ENV HOME=/app
```

```yaml
build:
  context: .
  args:
    APP_UID: ${APP_UID:-1000}
    APP_GID: ${APP_GID:-1000}
volumes:
  - ${HOME}/.aws:/app/.aws:ro
```

`HOME` is set explicitly rather than left to the passwd entry, so the path
resolves identically even if the runtime overrides the user - which Kubernetes
does.

**Generalises to.** Any bind mount into a non-root container is a uid problem
waiting to happen. `:ro` controls whether the *container* may write; it does
nothing about whether the container's user may read. In QA and production this
does not arise, because credentials come from IRSA rather than a mounted file -
which is the better answer, and the reason this is a local-development-only
workaround.

---

## 6. The log file was silently never written

**Phase 4.**

**Symptom.** One ERROR line at startup, and then a perfectly healthy-looking
application:

```
level=ERROR component=logger msg="could not open the log directory"
  log_dir=/var/log/mongo-dcu error="[Errno 13] Permission denied"
```

Everything worked. Only the file Splunk is meant to monitor was missing - and
since stdout logging was fine, nothing downstream looked wrong.

**What was actually wrong.** `./logs:/var/log/mongo-dcu` was bind-mounted. When
the host directory does not exist, Docker creates it **owned by root**, and the
non-root container user cannot write to it. The directory had been created that
way during an earlier failed run and persisted.

**Fix.** A named volume rather than a host directory:

```yaml
volumes:
  - app-logs:/var/log/mongo-dcu
```

A named volume inherits its ownership from the image's directory, which the
Dockerfile already chowns to the application user. The Splunk service will
mount the same volume in Phase 11 - which is the local equivalent of the
`emptyDir` shared with the sidecar in QA and production, so the two
environments stay structurally the same.

**Generalises to.** Prefer a named volume to a bind mount whenever the
container writes as a non-root user and the host path is not something a person
needs to open directly.

**Worth noting about the failure mode.** The logging setup deliberately catches
this and continues rather than refusing to start - losing the Splunk feed is
bad, failing to start is worse. That decision is also what made it easy to miss.
It was caught only by checking the file existed rather than trusting that the
application was up.

---

## 7. Reports omitted every line that did not fail

**Phase 4.** The most substantive of these, and it was a design flaw rather
than a mistake.

**Symptom.** The first failure report for a five-query file read:

```
1 queries: 0 succeeded, 1 failed syntax, 0 failed execution
```

Four valid queries had vanished. The report then said *"Every line above is
listed for context"*, which was untrue.

**What was actually wrong.** Validation runs over the whole file before
anything executes, so that a syntax error on line 10 cannot leave lines 1 to 9
applied. That part is correct and deliberate. But the validation pass only
recorded lines that *failed*, and execution never ran - so the valid lines were
recorded nowhere at all.

The result was the one thing a report must never do: leave the reader unable to
tell whether a line ran. A line absent from a report is indistinguishable from
a line nobody thought to mention.

**Fix.** A fourth line status, `not_run` - valid, but never attempted because
another line in the file failed validation:

```
  SYN! line    9  db.properties.updateOne({ ... } )
            -> '{' opened at col 58 is closed by ')'
  --   line   13  db.properties.updateMany({ "listing_stat": "active" }, ...)
  --   line   17  db.properties.deleteOne({ "property_id": "PROP-99999" })
```

It runs through every layer: `LineStatus.NOT_RUN`, a `not_run_count` on the
run, a totals entry in the JSON report, a line in the email summary, and a
value the `run_lines.status` column accepts. `LineResult.failed` was narrowed to
mean the two real failures, so a `not_run` line does not itself fail a run that
already failed for a different reason.

**Incidental improvement.** The fix removed a piece of fragility. The execution
pass had been re-reading the downloaded file from a path it rebuilt from the
run id and file name, then re-parsing every line. The validation pass now
returns the parsed queries directly, so the file is read once, parsed once, and
the path is not reconstructed anywhere.

**Generalises to.** When a report's totals do not add up to the input, that is
the bug - not a presentation detail. The question to ask of any report is
whether a reader could mistake an omission for an absence of anything to say.

**Why it was caught.** By reading the generated report as its intended audience
would, rather than by checking that the file landed in the right bucket. The
routing was correct throughout; only the explanation was wrong.

---

## 8. The tag query that teardown will rely on also matches the state bucket

**Phase 5.** Nothing broke. This is a trap found before it was stepped in.

**Symptom.** After applying the shared stack, the tag query that
`scripts/nuke.sh` will be built on in Phase 6 returned three ARNs, not two:

```
arn:aws:s3:::mongo-dcu-pipeline-analytics-exports-950639281723
arn:aws:s3:::mongo-dcu-pipeline-tfstate-950639281723
arn:aws:ecr:us-east-1:950639281723:repository/mongo-dcu-pipeline-app
```

**What is actually wrong.** The bootstrap stack tags the Terraform state bucket
`project=mongo-dcu-pipeline, environment=shared`, exactly like everything else -
which is correct for discovery and reporting, and fatal for deletion. `nuke.sh`
is defined as *force-delete everything carrying the project tag, independently
of Terraform state*. Run as written, it would delete the bucket holding the
state for every environment, and the registry holding the image every
environment runs.

Deleting the state bucket does not destroy the AWS resources it describes. It
destroys the only record of them - leaving a cluster, two databases and a
dozen other billing resources running with nothing left that knows they exist.
That is the precise failure the teardown tooling exists to prevent.

**Fix.** Recorded here, and carried into Phase 6 as a requirement rather than a
hope: `nuke.sh` takes an explicit exclusion list, and the state bucket and the
ECR repository are on it. The rule it encodes is that a nuke operates on
environments, never on what environments are rebuilt *from*.

**Generalises to.** A discovery query and a deletion query are not the same
query, even when they return the same shape. Anything that survives teardown on
purpose has to be named somewhere, because tagging alone cannot express "find
this but never delete it".

**Why it was caught.** By reading the output of a verification command that had
already passed. Three ARNs where two were expected was the whole signal.
