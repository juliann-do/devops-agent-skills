---
name: migrate-wordpress-to-ec2
description: Migrate a WordPress service off a legacy EC2 (docker-compose + containerised MariaDB, or a bare nginx + php-fpm vhost) onto a new Ansible-managed EC2 - assess the running stack, move its databases into the per-environment RDS MySQL instances, write the torilab-ansible role, carry the nginx vhost and uploads across, deploy uat then prod, and wire CI/CD through a reusable workflow. Use when asked to migrate a WordPress site to a new EC2, move a service off the legacy box, bring a site under Ansible management, or move a containerised MariaDB into RDS. Takes a service repo name and the legacy host IP (default <HOST_IP>; others such as <HOST_IP> use the same key). Read-only on the legacy host; every change goes through a PR the operator merges.
---

# Migrating a WordPress service to a new Ansible-managed EC2

`twomi-website` is the reference implementation. Its Ansible lives in
`torilab-ansible/bb-homepage/{uat,prod}/ap-northeast-1/bb-homepage-ec2/`. When
something here is ambiguous, look at what twomi actually does — it is the only
one of these that has been through a full cycle.

**Input:** the service repo (e.g. `torilab-ai/wordpress-neksai-com`), the
**legacy host** it runs on today, and the environment to do first. The operator
supplies all three; do not guess which repo a site is built from or which box it
lives on.

| Legacy host | Notes |
|---|---|
| `<HOST_IP>` (`<PRIVATE_HOSTNAME>`) | The original shared box: neksai-com, aiavatar.fun, investor.neksai.com |
| `<HOST_IP>` | ai-mentalhealth.clinic, among others |
| anything else | Same key `~/.ssh/jumphost-rsa`; confirm the login user (`ubuntu` on Ubuntu) |

Everything below writes the legacy host as `$LEGACY`:

```bash
LEGACY=ubuntu@<legacy-ip>          # e.g. ubuntu@<HOST_IP>
SSH="ssh -i ~/.ssh/jumphost-rsa -o BatchMode=yes $LEGACY"
```

Before anything else, survey the box as a whole (step 1). A legacy host other
than the original can be shaped completely differently — never assume its
layout from this document.

## Five rules that override everything

**The legacy host is read-only.** `$LEGACY` with `~/.ssh/jumphost-rsa`
usually carries several live sites, uat and prod side by side, for services that have
nothing to do with this migration. Read compose files, env files, nginx vhosts
and the database. Change nothing — no `docker compose` writes, no restarts, no
nginx edits, no file writes anywhere, with exactly one carve-out: the dump
fallback in step 3 may write a temp file under `/tmp`, confirmed before and
removed after. Nothing else. The old stack keeps serving and stays the rollback
until cutover. The only other exception is a change the operator asks for
**explicitly, in that moment** (e.g. resetting a basic-auth password on both old
and new) — back the file up first, change only the targeted line, verify the
untouched lines are byte-identical afterwards, and check which other vhosts use
the same file before touching it.

**In the service repo, touch only `.github/workflows/`, `Dockerfile` and
`.dockerignore`.** Not `wp-content/`, not themes, not plugins, not
`wp-config.php`. That code belongs to the dev team. A migration that needs an
application change has found a real blocker: name it with file and line, report
it, and leave it for them — or, if the operator explicitly asks you to do it,
do it as its own PR, verbatim, for the dev team to review.

A hardcoded `wp-config.php` is *not* such a blocker: keep it out of the image
with `.dockerignore`, render an equivalent from `group_vars/all.yml` in the
Ansible role, and bind-mount it read-only (see `investor_website`). Verify the
rendered file's constants equal the live one's by comparing hashes inside a
throwaway `php:7.4-cli` container — never by printing values.

**Confirm before acting, every time, at four gates.** Not once at the start.

| Gate | What needs confirmation |
|---|---|
| Database | Every dump, every `CREATE DATABASE`, every restore, before it runs |
| Ansible | Every `ansible-playbook` run against a real host — show the `--check` diff first |
| Shared workflow | Any *new* reusable workflow, or any edit to an existing one |
| Merge | Open the PR, report what it changes, wait. Never self-merge |

**Never commit a credential.** RDS passwords, MariaDB passwords scraped off the
legacy box, WordPress salts. They go in the gitignored `group_vars/all.yml`, and
their *names* go in `all.yml.example` with placeholder values. Anything you echo
lands in a transcript and a shell history — pipe secrets between commands, never
through your visible output.

**Reuse before you build.** Check `torilab-ai/torilab-shared-workflow` for a
reusable workflow that already fits before writing one. If none does, propose the
new one and get it reviewed before writing it.

## Sources and reasoning

- **Link what you researched.** When a conclusion rests on research (vendor or
  tool docs, chart/provider docs, release notes, a GitHub issue, a Jira or
  Confluence page), end it with a **References** list: one link per line plus
  what it supports. Mark any conclusion with no source as your own inference.
- **Say why before you trace.** Before reading logs, events, metrics, traces,
  or error output, state in one line what you are looking for and which
  symptom or hypothesis it tests; afterwards, say what it showed. Never dump
  logs without that reason.

## Order of work

Each step depends on the one before it. A role written before the compose file
has been read is a guess; a cutover before a verified restore is a data loss.

### 1. Assess the running service (read-only)

The repo is not the source of truth. The compose file that actually runs lives
on the box.

**First find out what shape the site actually is** — this decides most of the
work, and it is not always what the repo suggests:

| Shape | How to tell | What changes |
|---|---|---|
| docker-compose + containerised MariaDB | a stack under `/opt/deploy/`, `db-compose.yml` | the full flow below |
| bare host vhost + php-fpm, **no containers** | nginx `root /var/www/<site>`, `fastcgi_pass unix:/var/run/php/...` | containerise it (Dockerfile + compose); the live docroot is the code source |
| database **already on RDS** | `DB_HOST` in `wp-config.php` points at an RDS endpoint | skip step 3 entirely; reuse the same DB and user; cutover moves no data |
| prod-only (no uat copy) | only one docroot / stack exists | one environment; CI/CD is PR → `main` builds, merge deploys prod |

Survey the whole box before narrowing down:

```bash
$SSH 'hostname; sudo docker ps --format "{{.Names}}|{{.Image}}|{{.Ports}}"; sudo docker compose ls'
$SSH 'ls -la /opt/deploy/ /var/www/ 2>/dev/null'
$SSH 'for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do echo "$f: $(sudo grep -hE "^\s*(server_name|root|proxy_pass|fastcgi_pass)" $f | tr -s " " | tr "\n" " ")"; done'
$SSH 'systemctl list-units --type=service --state=running --no-pager --no-legend | awk "{print \$1}"'
```

For a compose site, find the deploy path from the service's existing workflow —
`COMPOSE_PATH` in `.github/workflows/deploy.yml`. On the original legacy host
the convention is `/opt/deploy/<service>` for uat and `/opt/deploy/prod-<service>`
for prod, both on the same EC2. Other hosts may differ.

**If the live docroot is the code source, check it against the repo before
building anything.** Sites edited in place on the server drift from git. Compare
every file's checksum, live vs repo, with a parser that survives spaces in
filenames (split on the first run of spaces only — `awk '{print $2}'` silently
truncates `home - Copy.css` and both hides and invents differences). An image
built from a repo that is behind the server rolls the site back at cutover.

The legacy box is Ubuntu and logs in as `ubuntu`; the Ansible-managed hosts are
Amazon Linux and log in as `ec2-user`. Same key, different user — a refused login
is usually the wrong user, not the wrong key.

```bash
$SSH 'ls -la /opt/deploy/'
$SSH 'cd /opt/deploy/<service> && ls -la && cat docker-compose.yml db-compose.yml'
$SSH 'cat /opt/deploy/<service>/.env'          # into a temp file if it holds secrets
$SSH 'sudo nginx -T 2>/dev/null | sed -n "/server_name <domain>/,/^}/p"'
$SSH 'systemctl is-active nginx; ls -la /etc/nginx/sites-enabled/'
```

Answer all of these before writing anything:

- **Which containers exist.** WordPress, nginx, and a *separate*
  `db-compose.yml`. Do not assume that second file holds only the database —
  on the legacy box it holds **the nginx container as well**, so missing it
  loses the web tier too, not just MariaDB. Read every compose file in the
  directory before concluding anything about the stack's shape.
- **Where nginx actually terminates.** The legacy stack may run nginx *in the
  compose project* (`docker compose exec nginx nginx -s reload`) *and* a host
  nginx under systemd in front of it. Read both. The new host runs host nginx
  under systemd only — see `roles/nginx_reverse_proxy`.
- **The database.** Engine and version (`mariadb:10.x` vs `mysql:8`), database
  name, user, and whether anything else shares it. Get credentials from the
  compose `environment:` block or `.env` — never retype them.
- **Uploads.** Where `wp-content/uploads` lives: a named volume, a bind mount, or
  an S3 mount. Its size (`du -sh`) decides whether the copy is minutes or hours.
- **Volumes that hold application code.** The legacy CI does
  `docker volume rm wp_data` on every deploy for a reason — see the hard-won
  comment in twomi's `deploy.sh.j2`. Docker populates a named volume from the
  image only when it is empty, so without that removal every deploy silently
  keeps serving the first image ever pulled.
- **The domain**, from the nginx `server_name`, and whether Cloudflare fronts it.
- **Where `siteurl`/`home` really come from.** Check both the database *and*
  `wp-config.php`. These sites define `WP_HOME`/`WP_SITEURL` from environment
  variables, which means the `wp_options` rows can be stale garbage —
  `http://localhost:8088` on a site serving `https://www.neksai.com` — and the
  live value comes from compose. Two consequences: no search-replace is needed,
  and the new deployment **must** set those env vars or the site emits
  `localhost` URLs everywhere. Anyone who later checks `siteurl` in RDS will see
  the stale row and think the migration broke something.
- **Access restrictions in the *container* nginx, not just the host one.** The
  legacy sites carry an IP allowlist on `/wp-admin` and `/wp-login.php` ending in
  `deny all`, and it only works because the same file trusts the full Cloudflare
  ranges via `set_real_ip_from` + `real_ip_header CF-Connecting-IP`. Carry the
  vhost without those and the allowlist evaluates Cloudflare's addresses and
  locks everyone out — including you.

  **An allowlist does not survive a host move unchanged.** Copy it verbatim only
  when the destination is the same network. Entries like the old box's own
  subnet and the Docker bridge ranges (`172.17.0.0/16`, `172.19.0.0/16`) mean
  something different, or nothing, on another host. Enumerate every entry and
  say which ones still apply before cutover, rather than discovering it when
  admin access is gone.
- **PHP overrides.** `php.ini` upload/memory limits; WordPress media uploads need
  these well above the 2M/8M defaults.

Then read the service's existing workflow end to end and write down its git flow.
It differs per service. For `wordpress-neksai-com` it is `push main → uat`,
`tag v* → prod`, both deploying to the same box.

**If the legacy CI has no Cloudflare purge step, do not add one.** The new
pipeline matches the old one's behaviour; cache purging is a separate change on
its own merits.

### 2. Target shape

**First establish whether the target host already exists and already serves
something.** These migrations are not always onto a fresh box: the usual target
is the existing `bb-homepage` EC2 pair, which already runs another WordPress
service. A co-tenant migration is a different job from a greenfield one —

- the inventory, `common`, `docker`, `deploy_user` and `nginx_reverse_proxy` are
  already in place and must not be disturbed;
- the existing service's role, vars and runner stay untouched;
- the new service gets its own role, its own `<service>_*` variable namespace,
  its own GitHub runner, and an extra `server` block in the nginx config;
- `uploads_services` gains an entry — the backup job is deliberately one job per
  environment tree, not per service, so it picks the new directory up by itself;
- `service:` in `group_vars` is singular and drives `service_prefix`, the deploy
  path and the runner name. It keeps belonging to the *existing* service. Do not
  repoint it; namespace the new service separately.

Every change on a shared host is a change to a live service's machine. Treat the
co-tenant as production even when the service you are migrating is uat.

Otherwise, for a dedicated host:

- **Separate hosts per environment**, exactly as twomi does — two inventory
  directories, `bb-homepage/uat/...` and `bb-homepage/prod/...`, each with its
  own `group_vars/all.yml`, its own runner and its own deploy path. The legacy
  box runs uat and prod side by side on one machine; the new deployment splits
  them. That split is the point, so do not collapse them back into one inventory
  because the source happened to share a host.
- **One RDS instance per environment**, reached differently:

  | Env | Instance | Access |
  |---|---|---|
  | uat | `<RDS_ENDPOINT>` | tunnel via `ubuntu@<HOST_IP>` |
  | prod | `<RDS_ENDPOINT>` | direct, no tunnel |

**This makes the migration two independent migrations, not one.** The legacy box
holds two separate databases for the service — one behind
`/opt/deploy/<service>` and one behind `/opt/deploy/prod-<service>`, each with
its own `db-compose.yml` and its own credentials. uat data goes to the uat
instance and prod data to the prod instance, and the two never cross. Do uat
completely, prove it, and only then start prod; running them together is how a
prod dump lands in the uat instance.

The uat instance is not publicly reachable, so uat work goes through the tunnel
host. The prod instance is reachable directly and needs no tunnel:

```bash
# uat: open the tunnel, then connect to 127.0.0.1:3307
ssh -i ~/.ssh/jumphost-rsa -N -L 3307:<RDS_ENDPOINT>:3306 ubuntu@<HOST_IP>
mysql -h 127.0.0.1 -P 3307 -u admin -p

# prod: straight at the endpoint
mysql -h <RDS_ENDPOINT> -u admin -p
```

That asymmetry is the trap. A `mysql -h 127.0.0.1 -P 3307` typed while thinking
about prod connects to **uat** and succeeds, because the uat tunnel is still
open from earlier. Confirm what you are actually connected to before every
write, and do not rely on the shape of the command to tell you:

```sql
SELECT @@hostname, @@read_only;
```

(Worth noting once, as a fact rather than a blocker: prod being directly
reachable means its exposure is the security group alone. That is the operator's
call, not something this migration changes.)

The RDS master passwords are supplied by the operator at migration time. They are
not in this file, and they do not go into a committed one — see the credential
rule above.

### 3. Database: MariaDB container → RDS MySQL

**Confirm before each command in this section.** A dump is read-only and safe; a
`CREATE DATABASE` and a restore are not, and they land on an instance other
services already use.

Get the credentials from the box rather than asking for them:

```bash
$SSH 'cat /opt/deploy/<service>/db-compose.yml' > "$TMP/db-compose.yml"   # not printed
# read MYSQL_DATABASE / MYSQL_USER / MYSQL_PASSWORD / MYSQL_ROOT_PASSWORD from it
```

Dump with the client *inside* the container, so the client version matches the
server. A host `mysqldump` against a MariaDB server is where silent corruption
starts.

Pass the password through `MYSQL_PWD`, never as `-p<pass>`. This box is shared
and running `ps aux` on it is not privileged — a password in argv is visible to
every other user on the host for as long as the dump runs.

```bash
$SSH 'cd /opt/deploy/<service> && docker compose -f db-compose.yml exec -T \
  -e MYSQL_PWD="$PW" <db-service> \
  mysqldump -u root --single-transaction --quick --routines --triggers --events \
  --default-character-set=utf8mb4 --no-tablespaces <dbname>' > "$TMP/<dbname>.sql"
```

#### If streaming straight to local does not work

A big database over a slow link, an SSH timeout mid-dump, or a local disk with
no room for it. Two fallbacks, in order of preference. **Confirm which one before
running it, and verify the result with the operator afterwards** — both touch
more than the default route does.

| Route | What it does | Cost |
|---|---|---|
| Default | `$SSH 'mysqldump ...' > local.sql` | Writes nothing to the legacy host |
| Fallback A | Dump to a file on the legacy host, `scp` it down, restore from local | One temp file on a shared box |
| Fallback B | Dump and restore entirely on the legacy host, straight into RDS | No local copy to verify against |

**Before either fallback**, check the legacy host can afford it. It runs several
live sites; filling its disk is an outage for all of them, not just this service.

```bash
$SSH 'df -h /tmp /var/lib/docker'      # room for the dump, with margin
$SSH 'command -v mysql mysqldump'      # fallback B needs a client on the host
```

**Fallback A** — dump to `/tmp`, pull it down, then remove it. The removal is not
optional: it is a plaintext copy of the whole site's data sitting on a shared
box.

```bash
$SSH 'docker compose ... mysqldump ... > /tmp/<dbname>.sql && ls -lh /tmp/<dbname>.sql'
scp -i ~/.ssh/jumphost-rsa $LEGACY:/tmp/<dbname>.sql "$TMP/"
$SSH 'shred -u /tmp/<dbname>.sql'      # confirm it is gone
```

**Fallback B** — restore from the legacy host directly into RDS. Fastest for a
large database, and the one with the least safety margin: there is no local copy
to diff against if the restore goes wrong, so the verification queries in the
next section matter more, not less.

Two things to establish first:

```bash
# can the legacy host even reach the target instance?
$SSH 'nc -vz <rds-endpoint> 3306'
```

- uat RDS is private. The legacy host may well *not* reach it, in which case
  fallback B is unavailable for uat and the tunnel route stands.
- Prod RDS is directly reachable, so fallback B is usually viable there.

Put the RDS credentials in a `0600` defaults file rather than argv, and shred it
with the dump:

```bash
$SSH 'umask 077 && cat > /tmp/.my.cnf' <<'EOF'
[client]
user=admin
password=<supplied at runtime, never echoed>
EOF
$SSH 'docker compose ... mysqldump ... | mysql --defaults-extra-file=/tmp/.my.cnf -h <rds-endpoint> <dbname>'
$SSH 'shred -u /tmp/.my.cnf'
```

Whichever route runs, the legacy database itself is only ever read. No route
drops, truncates or alters it, and the old stack keeps serving throughout.


Then, before restoring, deal with the four things that break a MariaDB → MySQL 8
restore. Check for each; do not blanket-sed a dump you have not inspected.

| Problem | Symptom | Fix |
|---|---|---|
| MariaDB conditional comments `/*M!...*/` | Syntax error mid-restore | Strip the `/*M!...*/` wrappers |
| `DEFINER=` on views/triggers/procs | `access denied; you need SUPER` | Remove the `DEFINER=...` clauses |
| `utf8mb3` columns | Restores, then mangles non-ASCII | Confirm the dump is utf8mb4 end to end |
| Collation `utf8mb4_general_ci` vs `0900_ai_ci` | Restores fine, sorts differently | Keep the source collation; do not "upgrade" it |

Create the database and an application user. **Reuse the legacy application
user and password** — the ones already in the legacy `db-compose.yml` — rather
than generating new ones. That keeps the migration a pure data move: the
service's `.env` carries the same `WORDPRESS_DB_USER`/`WORDPRESS_DB_PASSWORD`
it always had, so a failure after cutover is unambiguously about the data or
the network, never about a credential that changed at the same time.

Take the database name and collation from the source too, rather than
defaulting to `utf8mb4_unicode_ci` — these sites use
`utf8mb4_unicode_520_ci`, and silently "upgrading" a collation changes sort
and comparison behaviour.

```sql
CREATE DATABASE `<dbname>` CHARACTER SET utf8mb4 COLLATE <source collation>;
CREATE USER '<legacy appuser>'@'%' IDENTIFIED BY '<legacy password>';
GRANT ALL PRIVILEGES ON `<dbname>`.* TO '<legacy appuser>'@'%';
FLUSH PRIVILEGES;
```

Still **never the RDS master account** — that stays for administration only.

**Check whether the user already exists before creating it.** These RDS
instances are shared across many sites, and an account named after the service
may already be there serving a different database. `CREATE USER ... IF NOT
EXISTS` is then a silent no-op: it does not set the password, reports success,
and the only symptom is `Access denied` from the application much later.

```sql
SELECT user, host, password_last_changed FROM mysql.user WHERE user='<appuser>';
SHOW GRANTS FOR '<appuser>'@'%';
```

If it exists and holds grants on another database, do not reset its password —
that breaks whatever else uses it. Create a distinct account for this service,
granted on its own database only, and say so in the PR. This happened on a
real migration: `neksai_user` on the prod instance was shared with an
`investor.neksai.com` database, so prod uses `neksai_wp` while uat keeps
`neksai_user`.

Two things follow from reusing the credentials. They were sitting in plaintext
on a shared box, so they are disclosed by definition: rotating them is a
sensible follow-up once the service is stable, done as its own change rather
than folded into the migration. And the password goes in the gitignored
`group_vars/all.yml`, never the committed `.example`.

Restore into the instance for *this* environment, then verify rather than assume:

```bash
# uat  (through the tunnel):
mysql -h 127.0.0.1 -P 3307 -u admin -p <dbname> < "$TMP/<dbname>.sql"
# prod (direct):
# mysql -h <RDS_ENDPOINT> -u admin -p <dbname> < "$TMP/<dbname>.sql"
# per-table row counts, both sides, and diff them
mysql ... -e "SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema='<dbname>' ORDER BY table_name;"
# WordPress's own sanity check
mysql ... -e "SELECT option_name, option_value FROM <prefix>_options WHERE option_name IN ('siteurl','home');"
```

**Pin session variables before comparing hashes across the two engines.** A
`GROUP_CONCAT`-based checksum is truncated by `group_concat_max_len`, which is
1048576 on MariaDB and **1024** on RDS MySQL — so the same data produces
different hashes and looks like corruption. Set `group_concat_max_len` and
`SET NAMES utf8mb4` explicitly on both sides, or compare with something that
has no such limit:

```sql
SELECT COUNT(*), SUM(CRC32(COALESCE(col,''))), SUM(LENGTH(COALESCE(col,'')))
FROM <table>;
```

`SUM(LENGTH(...))` is the one that actually proves encoding survived: equal
byte totals across both engines means nothing was re-encoded. Run that first,
and only then a hash — otherwise a flawed query sends you hunting a
charset bug that is not there.

`siteurl`/`home` must match the domain the new host will serve. If the migration
keeps the same domain — the normal case — they need no change, and running a
search-replace "just in case" is how a site ends up pointing at a hostname that
never existed. If they *do* need changing, use WP-CLI `search-replace`, never
raw SQL: serialised PHP in `wp_options` breaks when string lengths change.

The old MariaDB container keeps running and keeps its data throughout. It is the
rollback. Nothing deletes it during this migration.

### 4. Ansible: the new host

Repo `torilab-ansible`. Model the whole tree on
`bb-homepage/<env>/ap-northeast-1/bb-homepage-ec2/`. Read that env's `README.md`
and `site.yml` first; role order there is load-bearing and commented.

Role order, and why:

```
common
docker            # must precede deploy_user — creates the docker group it joins
deploy_user
github_runner
uploads_dirs      # must precede the app role — compose needs the dirs to exist
uploads_s3_backup
<service>_website
docker_prune
nginx_reverse_proxy
```

The app role is a near-copy of `twomi_website`: deploy dir, `docker-compose.yml`,
a non-secret `.env`, `php.ini`, `default.conf`, the ECR credential-helper config
for `deploy_user`, and a templated `deploy.sh`. Carry across two things that look
like noise and are not:

- **`deploy.sh` does `down` + `docker volume rm <prefix>_wp_data` + `up`.** Keep
  it. See step 1.
- **The role queries ECR for the latest `<env>-` tag** instead of trusting the
  compose default. A fixed fallback tag goes stale the moment a newer image is
  pushed, and an Ansible-triggered deploy then silently redeploys an ancient
  image. twomi hit exactly this.

Variables go in `group_vars/all.yml` (gitignored, real values) with every name
mirrored into `all.yml.example` (placeholders). Follow the existing naming:
`<service>_deploy_path`, `<service>_db_host`, `<service>_domain`, and so on.

**Uploads.** twomi's current shape is local directories under `/data/<env>/`
backed up to S3 on a timer — `uploads_dirs` + `uploads_s3_backup` — not an S3
mount. (The `twomi_website/README.md` still describes an older `s3_uploads_mount`
role that no longer exists; believe `site.yml`, not that README, and fix it while
you are there.) A new service is an entry in the `uploads_services` list, not a
new role.

Set `uploads_backup_on_calendar` to **every 6 hours** for this service. The twomi
default is `*:0/15`. Six hours means the RPO for uploads is six hours — say that
plainly in the PR so it is an accepted trade-off rather than a surprise.

**nginx.** `roles/nginx_reverse_proxy` installs host nginx via `dnf`, generates a
self-signed cert, templates the vhost, runs `nginx -t`, and starts it under
systemd. Two things to carry over carefully:

- The new vhost must match the legacy one's *behaviour*, not its text. The legacy
  box is Ubuntu (`sites-enabled/`, apt); the new host is Amazon Linux
  (`conf.d/`, dnf). Diff the two configs by what they do: `allow`/`deny` blocks,
  `client_max_body_size`, `location = /` redirects, proxy buffer sizes, and any
  `location` that bypasses PHP. A naive copy silently drops restrictions.
- The static-asset `location ~* \.(jpg|...)$` block and its `expires` TTL should
  match the legacy config unless the operator asks otherwise.

**Order the role so nginx and TLS come before the image pull.** The vhost's
`listen 443 ssl` block needs a certificate to exist or nginx will not start,
and the role generates a self-signed one (`creates:`-guarded, SAN covering the
domain and every alias) exactly as `nginx_reverse_proxy` does for the existing
service. Cloudflare fronts the origin, so its SSL mode must be **Full**, not
Full (strict), against a self-signed origin certificate.

Putting those tasks ahead of the ECR lookup and `docker compose` means a
registry problem cannot stop the vhost and certificate being installed.
`nginx -t` passes with nothing yet listening on the proxied port — the only
consequence is a 502 on that hostname until the container runs, which is
correct and is itself a useful signal that routing works.

Follow the nginx tasks with `meta: flush_handlers`. Without it the reload is
queued until the end of the play, and any later failure discards it silently.

Validate before proposing anything:

```bash
ansible-playbook --syntax-check site.yml
ansible-playbook --check --diff site.yml -i inventory/hosts.ini
```

### 5. Deploy uat, then prod

**Confirm before every real `ansible-playbook` run.** Show the `--check --diff`
output and wait.

uat first, completely: run the playbook, confirm containers are up, confirm
WordPress connects to RDS, confirm uploads are present and writable, load the
site through the new host before any DNS moves. Only then propose prod.

**Iterate freely on the new host.** It serves no traffic yet, so the loop is
`--check --diff` → confirm → apply → inspect → fix → re-run, as many times as it
takes. The playbook is idempotent. Note that re-running the app role is
*disruptive* by design — `deploy.sh` does `down` + `docker volume rm <prefix>_wp_data`
+ `up` — which is free before cutover and needs confirmation after it. This is
also why the legacy host stays untouched: it is the thing still serving users
while this one is being rebuilt repeatedly.

#### Verifying before DNS moves

The site must be tested on its **real hostname**, not on the IP. WordPress builds
absolute URLs from `siteurl`/`home`, so hitting the raw IP gives a page whose
every asset, redirect and form action still points at the live domain — it looks
broken in ways that have nothing to do with the migration, and it tests nothing.

Override resolution locally instead. Prefer `curl --resolve`, which needs no
sudo, no cleanup, and cannot be left behind:

```bash
NEW_IP=<new ec2 ip>
curl -ksSI --resolve '<domain>:443:'"$NEW_IP" https://<domain>/ | head -1
curl -ksS  --resolve '<domain>:443:'"$NEW_IP" https://<domain>/wp-login.php | grep -c 'user_login'
```

For real browser testing, add a hosts entry — and write down exactly what you
added so removing it later is exact rather than a hand-edit:

```bash
sudo sh -c 'printf "%s %s %s\n" "'"$NEW_IP"'" <domain> www.<domain> >> /etc/hosts'
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder   # macOS
# ... test in the browser ...
sudo sed -i '' "/^${NEW_IP//./\\.} /d" /etc/hosts              # remove, then re-verify
grep -n '<domain>' /etc/hosts || echo 'hosts entry removed'
```

**Remove it the moment testing ends.** A forgotten entry means every later check
— yours and anyone else's on that machine — silently hits the wrong box, and the
symptom is "DNS has not propagated yet" long after it has.

Two things that will look like faults and are not:

- **A TLS certificate warning.** `nginx_reverse_proxy` generates a self-signed
  cert, and bypassing DNS also bypasses Cloudflare, so you are hitting the origin
  directly with no public cert in front. Expect it; use `curl -k`. A cert error
  here says nothing about whether the site works after cutover.
- **Cloudflare-dependent behaviour missing.** Anything the proxy layer adds —
  caching, WAF rules, `CF-Connecting-IP` — is absent on a direct origin hit.

What to actually prove before calling uat good, each one testing a different
piece of the migration:

| Check | Proves |
|---|---|
| Homepage returns 200 on the real hostname | nginx vhost and PHP-FPM wiring |
| A DB-driven page renders (a post, a menu) | WordPress reached RDS, not a stale local DB |
| An existing uploaded image loads | uploads copied across with the right paths |
| `wp-login.php` renders and accepts a login | sessions, cookies, `siteurl` correctness |
| A media upload through wp-admin succeeds | uploads directory ownership and `php.ini` limits |
| The S3 backup timer has fired once | `systemctl list-timers`, and an object in the bucket |

Cutover is a DNS change, and it is the operator's to make. The legacy stack stays
up and serving until they say otherwise, and stays untouched after that until
they confirm the new one is good.

### 6. CI/CD

Target flow — PR-driven, and it differs from the legacy one:

```
PR feature ─► uat    ci.yml   BUILDS        sha-<pr head>
merge to uat         cd.yml   re-tags       sha-<pr head> ─► uat-<merge sha>, deploys uat
PR uat ─► main                (head.sha IS that uat merge sha)
merge to main        cd.yml   re-tags       uat-<head sha> ─► prod-<merge sha>, deploys prod
```

**Name the uat tag after the MERGE commit, not the PR head.** That is the
hinge of the whole chain: the merge commit on uat becomes the *head* of the
following `uat → main` PR, so the prod run finds its source image by name. No
step has to inspect a running container, read a tag off a host, or be handed
one by a human — and none of them has an excuse to rebuild.

**Trigger CD on `pull_request: [closed]` with `merged == true`, never on
push.** Only the PR event carries `head.sha`, which is what names the image CI
built. A push event has just the merge commit, which nothing is tagged with —
and starting from push is precisely why rebuilding starts to feel unavoidable.

**One `cd.yml`, not one per environment.** The two differ in exactly four
values — source tag, destination tag, runner label, deploy path — so compute
them in a single `case` on `base.ref` and let `runs-on` take the labels from a
job output via `fromJSON`. Two near-identical workflow files drift.

Derive tags from the SHA itself (`${HEAD:0:7}`), never by slicing the
prefixed string (`${SRC:0:11}`) — that silently depends on every prefix being
the same length, and `prod-` is not `uat-`.

**Merging the `uat → main` PR is the approval gate.** It is a deliberate human
action on a reviewable diff, and it needs no Environment protection rule —
which matters, because this org cannot have one (see above).

Build **once**. prod deploys the exact image uat was tested with, promoted by
tag, never rebuilt. A prod job that rebuilds from the same commit is not
deploying what was tested — a rebuild picks up new base-image layers and
floating dependency versions.

**The obvious approval mechanism is not available here.** GitHub's native gate
is required reviewers on an Environment, and environment protection rules for
**private** repositories require Enterprise. This org is on **Team**, so the
API refuses outright:

```
HTTP 422: Failed to create the environment protection rule.
Please ensure the billing plan supports the required reviewers protection rule.
```

That makes `environment: prod` actively dangerous: the job *looks* gated, and
runs straight through. Worse than no gate, because it invites trust. Check the
plan before designing around it:

```bash
gh api -X PUT repos/<owner>/<repo>/environments/prod \
  --input - <<< '{"reviewers":[{"type":"User","id":<id>}]}'
```

Make the gate **a separate workflow a human must start** instead. That is a
real gate, independent of billing:

```yaml
# promote-prod.yml
on:
  workflow_dispatch:
    inputs:
      image_tag: { required: false, type: string, default: '' }
```

Keep `environment: prod` on the job if you want deployment history, but
comment plainly that it gates nothing — otherwise the next reader assumes it
does.

**Derive the tag; do not go and read it.** The shared CI tags every image
`sha-<first 7 of the commit SHA>`, so the promote workflow computes it from
the ref it was started on. An earlier version ran a job on the *uat* runner to
read the tag off the running container; that needed cross-environment access
for no benefit, and it failed outright (see `sudo` below). A derived tag needs
nothing but the commit.

Check the image exists before deploying. Without it a wrong or not-yet-built
tag fails *partway through* `deploy.sh` — after it has already taken the stack
down.

Shape the service's own workflow as a thin caller of a reusable workflow so other
WordPress services can adopt it:

```yaml
jobs:
  build:
    uses: torilab-ai/torilab-shared-workflow/.github/workflows/app-ci.yml@<tag>
    with:
      ecr_repository: <repo>
    secrets: inherit
```

`app-ci.yml` fits a compose-on-EC2 service unchanged — it builds on the shared
runner, pushes through that runner's instance role, outputs `image_tag`, and
sets `provenance: false`. `app-cd.yml` does **not**: it requires
`manifest_repo`/`values_file` and rewrites Helm values for ArgoCD. Write the
deploy half in the service repo rather than bending a shared workflow that
other services depend on.

**Pin to a release tag, and check what you are pinning to.** `@main` lets an
unrelated change alter how this service builds; a commit SHA pins correctly but
reads as noise and never prompts an upgrade. If the newest tag is behind a fix
you need, ask for a new tag rather than pinning to the SHA — see the pinning
section above.

Check what `torilab-shared-workflow` already provides before writing anything. If
an existing workflow fits, reuse it unchanged — do not edit a shared workflow that
other services depend on to suit this one. If none fits, propose the new reusable
workflow and get it reviewed **before** writing it.

Two things to carry from twomi's pipeline, both deliberate:

- **Build on the shared `torilab-ai` runner, never on an app host.** Image layers
  and build cache burn the app host's disk for no benefit.
- **Deploy jobs need no checkout.** `deploy.sh` and everything it uses are already
  on the host, templated by Ansible. A deploy job that checks out the repo is
  putting the repo on the app host for nothing.

Do not add a Cloudflare purge job unless the legacy pipeline had one.

## Where these migrations actually fail

| Check | Why it bites |
|---|---|
| **Is there a second compose file?** | `db-compose.yml` is separate from `docker-compose.yml`. Miss it and you migrate a site without its database. |
| **Does the RDS security group admit the new EC2?** | Symptom is a connection *timeout* from WordPress, not an auth error. |
| **Is `wp_data` removed on deploy?** | If not, every deploy serves the first image ever pulled, and the symptom is "my change did not deploy" with a green pipeline. |
| **utf8mb4 end to end** | A restore that "succeeded" can still have mangled every non-ASCII character. Check actual content, not just row counts. |
| **Right dump into the right instance?** | uat is a tunnel on `127.0.0.1:3307`, prod is a direct endpoint. A prod-intended command typed at a still-open uat tunnel succeeds against uat. `SELECT @@hostname` before every write. |
| **Uploads ownership** | Files restored as root leave WordPress unable to write. Match the uid/gid the container runs as. |
| **Is `environment:` even capable of gating?** | Private repo on the Team plan cannot have protection rules at all, so the line is decoration. Use a separately-dispatched workflow. |
| **Is the repo granted access to the runner group?** | An org runner with matching labels and an active service will still never pick up the job. The symptom is "Waiting for a runner to pick up this job..." forever, with no error. Check the runner group's repository access before debugging labels. |
| **Does the runner service allow `sudo`?** | It is hardened with `NoNewPrivileges=true`, so `sudo` cannot escalate inside a job. It is not needed: the runner user is already in the `docker` group, and in the deploy user's group for `deploy.sh`. |
| **Can `workflow_dispatch` be tested before merge?** | No. The workflow must exist on the default branch, so a dispatch-only pipeline cannot be exercised from its own PR branch. Plan the pre-flight checks accordingly. |
| **Does the destination host's role have ECR access?** | Repository policies are per-repository. The host may pull one service's image fine and be denied another's — `AccessDeniedException ... no resource-based policy allows`. Check before writing the role, not at first deploy. |
| **Did you overwrite the registry policy?** | `aws ecr set-repository-policy` REPLACES the whole document. See below — this broke a live pipeline. |
| **Did the reload actually happen?** | Ansible handlers run at the END of a play, so a task that fails first means they never run. The vhost sits on disk, `nginx -T` prints it, and the running master has never loaded it. Check the master's start time, not the config dump. |
| **Did the base move before merge?** | Fetch and re-check `mergeable` before asking for a merge, even on a PR that was clean an hour ago. |
| **Did the merge actually take your latest commits?** | A squash merge captures the branch *at that moment*. Anything pushed afterwards is on the branch and not on `main`, and the PR still reads MERGED. Verify against `main`'s content — see below. |
| **Is `output_buffering` the same as legacy?** | The php docker image ships no `php.ini`, so it is `0`; Ubuntu's is `4096`. A stray newline before `<?php` in any file loaded at bootstrap is then sent before headers: 404s come back as **200**, redirects and cookies can break, and `headers already sent` warnings appear. Set `output_buffering = 4096` in the role's `php.ini`, then compare status codes of real and missing pages, old vs new. |
| **Can the allowlist be bypassed by a forged header?** | If the new host's 443 is open to `0.0.0.0/0` and the host vhost forwards `$http_cf_connecting_ip` verbatim, a direct origin hit with `CF-Connecting-IP: <allowlisted ip>` walks past the IP gate. Resolve the real IP **in the host vhost** (`set_real_ip_from` Cloudflare ranges + `real_ip_header CF-Connecting-IP`) and forward `$remote_addr`. Test: no header → 401, forged header → must also be 401. |
| **Is the htpasswd carried verbatim?** | Copy legacy entries byte-for-byte so existing logins keep working. `nginx:alpine` verifies both `apr1` and bcrypt `$2y$` (tested) — do not regenerate passwords on the assumption it can't. Test auth against a static file, never a `return 200` location: `return` runs before the access phase and passes any password. |
| **Does `uploads_dirs` touch a co-tenant?** | It enforces mode on *every* entry in `uploads_services`, so it will "fix" another service's manual drift. Scope a run with `-e '{"uploads_services":[{"name":"<service>"}]}'` — only `uploads_dirs` reads that list. |
| **Will an image tag in `all.yml` roll prod back?** | After CI deploys a newer tag, an Ansible run still installs the pinned `<service>_image_tag`. Bump the pin to what is running before the next playbook run. |
| **Can a scripted wp-login prove the password?** | Not when the form has reCAPTCHA. Call `wp_check_password()` via `php -r 'require "wp-load.php"; ...'` inside the container instead — it also proves the container reaches RDS. |
| **Did a secret reach your output?** | In zsh, `cmd | ssh host 'bash -s' <<EOF` sends BOTH the pipe and the heredoc as stdin (MULTIOS): the data line runs as a command and bash echoes it. BusyBox `wget --password=` echoes the value in its usage error. Pass the script as the remote command (`bash -c "$(printf %q "$script")"`) and data only on stdin; redirect from a 0600 file rather than piping into a heredoc. Rotate anything that leaks. |
| **Can Docker see the file you mounted?** | Colima shares `$HOME` only — a bind mount from `/private/tmp/...` silently becomes an empty path, and a check against it "passes". Feed files into throwaway containers on stdin. |
| **Does the laptop reach RDS?** | Prod RDS only admits the EC2 hosts. Run DB checks from the new app host (`mysql --defaults-extra-file=<(printf ...)`), credentials on stdin. |
| **Is the site already compromised?** | Check BEFORE copying data: `wp_users` joined to `wp_capabilities` (unexpected administrators, odd email domains like `@wp2shell.local`), attachments whose files are really PHP (`file -b` on uploads), and `207` responses to `rest_route=/batch/v1` in the access logs. ai-mentalhealth.clinic had 23 attacker admins and 91 shells; the migration had copied them to RDS and the new uploads before anyone looked. Pause, report, and clean only on the new side with backups. |
| **Will merging the service PR redeploy legacy?** | If the old `deploy.yml` is kept until cutover, merging to `main` runs it: `run_deploy.sh` recreates the legacy containers and **Docker discards their logs** — the only copy of real client IPs when the host nginx logs Cloudflare addresses. Save `docker logs <nginx>` to a file before asking for that merge. |
| **Is an nginx rule enough to block a REST route?** | No: WordPress accepts `rest_route` in the POST **body**, which nginx cannot see. Enforce in WordPress (a bind-mounted mu-plugin using `rest_pre_dispatch`, like `mentalhealth_website/files/torilab-hardening.php`) and treat nginx as defence in depth. |
| **Which `mysqldump` is on the new host?** | Amazon Linux ships the MariaDB client: `mysqldump --set-gtid-purged=OFF` fails with "unknown variable" and produces an empty dump. Guard every backup on its table count before acting on it. |
| **Does the official `wordpress:php7.4-fpm` still build?** | It is Debian bullseye; its security packages now 404 on `deb.debian.org`, so any `apt-get install` in the Dockerfile fails. Build on the shared `wordpress-base:php7.4-fpm` (gd and imagick included) after comparing `php -m` with the running image. |

## "MERGED" does not mean your work landed

These repos squash-merge. A squash captures the branch **at the moment of the
merge**, so any commit pushed afterwards stays on the branch while the PR shows
MERGED and the branch shows as merged in the UI. The work is simply absent from
`main`, with nothing flagging it.

This is not hypothetical: three changes were lost this way across two PRs,
including a correctness bug that would have broken five production redirects at
cutover. The pattern that causes it is ordinary — open a PR, keep improving the
branch while it waits for review, and the operator merges from a page that was
rendered before the last push.

**Verify against `main`'s content, never against the PR's state.** Grep for the
thing itself:

```bash
git fetch origin
git show origin/main:path/to/file | grep -c 'the distinctive string'
```

Do that for every fix you expect to be there, and do it *after* every merge
someone else performs, not just your own.

**Do not re-open the old branch to land the remainder.** Squash-merged commits
are invisible to git, so the branch now diffs against `main` as a large
**revert** — one of ours showed 620 deletions, because `main` had moved on and
git could not tell that its content was already there under a different commit.
Cut a fresh branch from current `main` and copy across only the files that are
genuinely missing:

```bash
git checkout -b fix/gaps origin/main
git checkout origin/<old-branch> -- <only the files that are missing>
git diff --cached --stat        # must be small, and must contain no reverts
```

Then check the staged diff removes nothing `main` already had, because a
wholesale file copy can silently roll back a change made on `main` in the
meantime.

## ECR repository policies: replace, not merge

`aws ecr set-repository-policy` **overwrites the entire policy**. Granting the
new host access by writing a fresh document silently removes every principal
the old one named.

This happened. The new hosts were granted, the legacy host was not named, and
its pipeline started failing on the next deploy:

```
failed to resolve reference ...: unexpected status from HEAD request ...: 403 Forbidden
```

Three things to do, in order:

1. **Read the existing policy and check the read succeeded.** A failed read —
   an expired SSO token, a `RepositoryPolicyNotFoundException` — looks exactly
   like "no policy" if the command is wrapped in `|| echo "(none)"`. Print the
   raw result and confirm it before trusting it.
2. **Enumerate every principal that pulls this repository**, not just the hosts
   being migrated. The legacy box ran as a completely different role
   (`AmazonSSMRoleForInstancesQuickSetup`) in the same account as the new hosts.
3. **Grant account-root for pull** unless there is a reason to be narrower. It
   covers every principal in the account whose own IAM allows the action, which
   is what makes it robust against exactly this mistake.

Verify from the host that was working before, using the action a pull actually
performs:

```bash
aws ecr batch-get-image --repository-name <repo> --registry-id <id> \
  --image-ids imageTag=<tag> --query 'images[0].imageId.imageTag' --output text
docker pull <registry>/<repo>:<tag>
```

**Do not test with `describe-images`.** A pull uses `BatchGetImage`,
`GetDownloadUrlForLayer` and `BatchCheckLayerAvailability`. A role can pull
perfectly while being denied `DescribeImages`, so that test reports a failure
that does not exist — and, worse, can report success for a role that cannot
pull. Read the error text too: "no **resource-based** policy allows" means the
repository policy is the problem; "no **identity-based** policy allows" means
the policy is fine and the caller's own IAM is the limit.

## Pinning a reusable workflow: always a tag

**Reference the shared workflow by a release tag.** Not a branch, not a commit
SHA.

```yaml
uses: torilab-ai/torilab-shared-workflow/.github/workflows/app-ci.yml@v6
```

- **Not `@main`.** An unrelated change on the shared repository silently alters
  how this service builds, with no commit in this repo to review or revert.
- **Not a commit SHA.** It pins correctly but reads as noise: nobody can tell
  from `@fc913e2814638c1e03be9d18613670bee4d6fd6b` whether they are on the
  current release or two years behind, and nothing prompts an upgrade. A tag
  is a deliberate, legible version.

**Check what the tag contains before pinning to it.** Tags here lag `main`,
sometimes by a fix that matters:

```bash
gh api repos/<org>/<repo>/compare/<tag>...main \
  --jq '"\(.ahead_by) commits ahead", [.files[]?.filename]'
```

**If the newest tag is behind a fix you depend on, get a new tag cut — do not
reach for the SHA instead.** A SHA pin is how a known-stale tag quietly becomes
permanent: the service works, nobody revisits it, and the next service copies
the SHA. Cutting the tag takes a moment and leaves every consumer able to move
forward together. Cutting it is the shared repo's owner's call, so ask.

This happened: `v5` of the shared CI was one commit behind `main`, and that
commit replaced a **registry** build cache (`:buildcache` tag) with
`type=gha`, because the registry cache **fails outright on IMMUTABLE
repositories** — the first build creates the tag and every build after it
cannot overwrite it. Check the destination repository's mutability so you know
whether the older tag would merely be untidy or actually broken:

```bash
aws ecr describe-repositories --repository-names <repo> \
  --query 'repositories[].imageTagMutability' --output text
```

**A short SHA is not a valid reference at all.** A reusable workflow needs a
branch, a tag, or a FULL 40-character SHA. A 7-character one fails *before any
job starts*, reporting zero jobs and no log — which looks like an outage, not a
typo.

## Reporting

At each step say what was verified with which command, what is still unproven,
and what the next merge or playbook run will change on a real host. "The
playbook runs clean in `--check`" is not "the site works" — say which one you
mean.

Quote real output for anything load-bearing: row counts both sides of the
database migration, `nginx -t`, the `--check --diff`, the first green pipeline
run. A migration reported as done without that evidence is a migration nobody
can audit later.
