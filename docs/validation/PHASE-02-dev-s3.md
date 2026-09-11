# Phase 2 - Dev S3

**What this phase built:** the reusable S3 module, the dev environment stack -
the first on the remote backend - and the four `dev-s3-*` scripts.

## 1. The five buckets exist and are protected

```bash
# variable form
cd $PROJECT_ROOT && ./scripts/dev-s3-status.sh

# expanded
cd ~/Documents/PROJECTS/mongo-dcu-pipeline && ./scripts/dev-s3-status.sh
```

Expect five rows, `present: 5   absent: 0`, and `yes` under each of `ver`,
`enc` and `pab` - versioning, encryption, and public access blocking:

```
bucket                                              objects       size  ver  enc  pab
mongo-dcu-pipeline-dev-input-950639281723                0         0B  yes  yes  yes
...
summary
  present: 5   absent: 0
```

The script also reports what the tag query returns for `environment=dev`, which
should list all five ARNs.

## 2. The code and the live buckets agree

```bash
# variable form
terraform -chdir=$PROJECT_ROOT/terraform/environments/dev plan

# expanded
terraform -chdir=~/Documents/PROJECTS/mongo-dcu-pipeline/terraform/environments/dev plan
```

Expect `No changes.` Twenty-five resources are managed here: five buckets, each
with versioning, encryption, a public access block and a lifecycle rule.

## 3. The outputs feed the local environment file

```bash
terraform -chdir=$PROJECT_ROOT/terraform/environments/dev output -raw env_file_lines
```

Expect five `S3_*_BUCKET=` lines, ready to paste into `.env`. Nothing about a
bucket name should ever be typed by hand.

## 4. A file round-trips

```bash
# variable form
echo 'db.properties.find({})' | aws s3 cp - s3://mongo-dcu-pipeline-dev-input-$ACCOUNT_ID/roundtrip.txt
./scripts/dev-s3-status.sh
aws s3 rm s3://mongo-dcu-pipeline-dev-input-$ACCOUNT_ID/roundtrip.txt

# expanded
echo 'db.properties.find({})' | aws s3 cp - s3://mongo-dcu-pipeline-dev-input-950639281723/roundtrip.txt
./scripts/dev-s3-status.sh
aws s3 rm s3://mongo-dcu-pipeline-dev-input-950639281723/roundtrip.txt
```

The status output should show the object under a `contents` heading. **If the
local stack is running it will pick the file up and process it** - which is the
point of Phase 4, but unexpected if you only meant to test S3.

## 5. The full destroy and recovery cycle (optional, ~4 minutes)

Worth running once. These scripts are the model for `nuke.sh` in Phase 6, where
what they delete costs real money.

```bash
cd $PROJECT_ROOT/scripts

# Leave versions and a delete marker behind, so emptying is genuinely tested
echo 'db.properties.find({})' | aws s3 cp - s3://mongo-dcu-pipeline-dev-input-$ACCOUNT_ID/v.txt
echo 'changed'               | aws s3 cp - s3://mongo-dcu-pipeline-dev-input-$ACCOUNT_ID/v.txt
aws s3 rm s3://mongo-dcu-pipeline-dev-input-$ACCOUNT_ID/v.txt

aws s3api list-object-versions --bucket mongo-dcu-pipeline-dev-input-$ACCOUNT_ID \
  --query '{versions: length(Versions || `[]`), markers: length(DeleteMarkers || `[]`)}'
# expect: 2 versions, 1 marker

./dev-s3-nuke.sh --yes        # expect: "removed 3 object version(s)", then 5 x "gone:"
./dev-s3-status.sh            # expect: present: 0   absent: 5
./dev-s3-create.sh --yes      # expect: 25 added - the post-nuke reconciliation path
./dev-s3-status.sh            # expect: present: 5   absent: 0
```

`aws s3 rm --recursive` would **not** be enough here: it removes only current
versions, and a versioned bucket holding old versions and delete markers cannot
be deleted. The nuke script pages through `list-object-versions` and removes
both.

To test the ordinary path instead:

```bash
echo 'x' | aws s3 cp - s3://mongo-dcu-pipeline-dev-input-$ACCOUNT_ID/p.txt
./dev-s3-destroy.sh --yes     # succeeds despite the object: force_destroy = true on dev
./dev-s3-create.sh --yes
```

## 6. The scripts refuse to run unattended without consent

```bash
echo | ./scripts/dev-s3-destroy.sh
```

Expect a refusal naming `--yes`. A destructive script must not hang on a prompt
in a Jenkins job, and must not proceed silently either.

## Pass criteria

- [ ] Five buckets present, all three protections on
- [ ] `terraform plan` reports no changes
- [ ] `env_file_lines` prints five usable lines
- [ ] A file uploaded to `-input` is listed by the status script
- [ ] (Optional) nuke removes versions and delete markers; create reconciles
- [ ] Destructive scripts refuse to run unattended without `--yes`
