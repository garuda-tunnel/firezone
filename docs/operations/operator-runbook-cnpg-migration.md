# Operator runbook — Firezone v2.0.1 → v3.0.0 (CNPG)

## Scope and stop conditions

Migrate one live site at a time, with an operator present. This moves PostgreSQL
15 from the Firezone pod's `postgres` sidecar/hostPath to a separate CNPG
PostgreSQL 17.11 Cluster. It does not upgrade the Firezone application schema.
Do not deploy v3 against an empty database. Keep the old directory and the
off-node dump until the soak and rollback-retention period are complete.

Start on **v2.0.1**, not v1.2.0. For a 1.x site first follow
[the WireGuard-key migration](../../kube/README.md#migrating-from-1x), using
**v2.0.1** for both module and chart (v2.0.0 was not published), and verify an
existing client before continuing. Preserve the existing WireGuard key and all
six application encryption secrets, especially `databaseEncryptionKey`.

Stop on any failed command, count/key mismatch, restore error, unready database,
unexpected `Plan:` line or unplanned infrastructure replacement. Do not delete or
overwrite either database to make a retry pass (the one guarded exception is the
reset in section 3.3, which only applies to a CNPG database no workload uses).
The database is single-instance and node-local (not HA) and has **no database
backups** (no object store, no WAL archiving; decided for this migration). Its
durability is exactly the Proxmox backup job of the data disk that holds the CNPG
volume (section 1.2):

- the recovery point is that job's interval (`<backup job schedule = accepted RPO>`,
  section 1.6 item 6, signed off by the site owner): writes since the last run are lost;
- the backup is a **crash-consistent live image** (snapshot mode, guest-agent
  filesystem freeze) that PostgreSQL recovers by WAL replay, because `pgdata` and
  `pg_wal` share the one volume;
- the old `postgres-data` is deleted only after the gate of section 7.1 (a fresh
  off-node dump and the encrypted archives of it, the volume on the data disk, a
  Proxmox backup run that is newer than the migration and younger than one job
  interval, the monitoring marker);
- a lost or rebuilt hub VM is handled by section 9, which is site-specific and
  unrehearsed: when the data disk is part of the VM resource in Terraform, destroying
  that resource destroys the disk and its volume directory.

Expected client impact on the stand (see the rehearsal record): a data-plane
interruption of roughly 15-35 s per Firezone release change; none to about 60 s
for the k3s restart of section 1.2; none for the split Apply #1 after headroom and
pre-pull, but about 5 minutes each in two earlier rehearsals when the small hub
lost its k3s under a combined Apply #1, or a pod was evicted from a nearly full root
disk during the image pull. Plan every change as a minutes-long window, not
seconds, and measure your own.

## 0. Conventions that apply to every section

- **Shell model.** Use an interactive Bash on the operator/controller machine
  (not the hub) **without `set -e`**. Never run a command block by pasting it into
  that shell. Section 1.1 defines `blk`, which runs each block in a fresh
  `bash -euo pipefail`, so a failed guard stops the block, not your terminal.
  Every block below except 1.1 is `blk <<'EOF' … EOF`.
- **Plan gates.** `plan_gate` (defined in 1.1) runs the plan, prints it, extracts
  the summary with a pattern that matches both raw tofu output and Terragrunt's
  prefixed stdout (`10:28:52.959 STDOUT tofu: Plan: 0 to add, …`), requires
  **exactly one** such line, saves only it to `$BACKUP/plan-<label>.txt`, and fails
  unless it equals the expected line. A failed gate is a STOP: do not apply, do not
  edit the expected line in the window (the one exception is the k3s-restart
  recovery of section 2, which re-runs the same gate and may accept a different
  line under the conditions listed there). `apply_site … -auto-approve` is only ever in
  a separate block that follows a passed gate. Apply recomputes the plan: if
  anything changed since the gate, run the gate again. The infra unit is the
  exception: it applies the **saved** plan of its gate (it has no ephemeral tunnel).
  `env.sh` also exports `TG_TF_FORWARD_STDOUT` / `TERRAGRUNT_FORWARD_TF_STDOUT` so
  that every other parser of tofu output (`state pull | jq`, `show -json`) sees
  unprefixed stdout.
- **Plan output is secret.** The `helm_release` diff prints the previous
  release's metadata, including its **values** (admin password, all application
  keys, WireGuard key). This holds for every plan below, including the rollback
  plan. Do not tee, paste, screen-share or ticket plan output; clear the
  scrollback afterwards. The `Plan:` lines are the only thing to record.
- **`$BACKUP` is sensitive** (mode 0700): it holds key material and a full
  database dump. Never commit it. After verification, encrypt it at rest with the
  site's age recipient (section 5) and keep the plaintext only until the
  encrypted archive is proven readable.
- **Resume.** After a lost terminal: `export BACKUP=<the existing directory>;
  . "$BACKUP/env.sh"` and continue at the failed block. Never re-run section 1
  on a site that is already on v3 or has the CNPG operator applied: its captures
  are of the **v2** state. Post-soak cleanup (section 7) resumes the same way.

## 1. Prepare before the window

### 1.1 Session setup (interactive shell, no `set -e`)

Set only the site-specific values. The addresses below are the **direct-consumer**
layout (`module.firezone_kube`); a wrapper such as the garuda-internal mini-site
prefixes all three with `module.site.` (stand: see the last section). `UNIT` is the
site's Terragrunt unit. Production `k` runs kubectl **on the hub over SSH** (the
production kubeconfigs only exist during plan/apply, through the tunnel), so no
local kube context is involved; `kl` has no request timeout and is the only
helper used for `pg_dump`/`pg_restore` streams.

`HUB` must be an SSH alias that works **non-interactively** (`BatchMode`, so a
missing key or an unknown host key fails instead of prompting). For a stack whose
`root.hcl` materializes its operator key under its `state_dir` (any `terragrunt
init` of the stack materializes that key but only creates an **empty** `known_hosts`;
the hub's key lands there only through the infra keyscan, so it exists only on the
controller that ran the infra apply — on any other controller add it deliberately,
verifying the fingerprint out of band), the alias is:

```sshconfig
Host hub.example.net
  HostName <hub address recorded by the infra keyscan>
  User garuda
  IdentityFile ~/.local/state/garuda/<stack>/ssh/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile ~/.local/state/garuda/<stack>/known_hosts
  StrictHostKeyChecking yes
```

`garuda` is the k3s-bootstrap `ssh_user` (passwordless sudo). The thresholds at the
end of the variable list are the section 1.2 / 2 gates (the stand meets them with a
larger root disk, see the last section); `PG_IMAGE` and `OPERATOR_CHART` must equal the inputs
of section 2 (checked after Apply #1).

```bash
umask 077
BACKUP="$HOME/firezone-migration/$(date -u +%Y%m%dT%H%M%SZ)"
export BACKUP
mkdir -p "$BACKUP"   # umask 077: directories are 0700
UNIT="$HOME/sites/example/garuda"
NS=garuda
FZ=firezone
HUB=hub.example.net
FZ_MODULE=module.firezone_kube
DB_MODULE=module.firezone_db
OP_MODULE=module.cnpg_operator
SOPS_FILE="$HOME/sites/example/secrets.sops.yaml"
SOPS_ENC_EXPR='.firezone_encryption_secrets'
SOPS_WG_EXPR='.firezone_wireguard_private_key'
AGE_RECIPIENT='<site age public key>'
AGE_IDENTITY='<path of the site age identity file that decrypts AGE_RECIPIENT archives>'
# Section 1.6 item 6 (site facts, never guessed): the hub VM id and the Proxmox backup job interval in
# seconds = the accepted RPO. A placeholder left here makes the 7.1 gate fail, by design.
HUB_VMID='<hub VM id, digits>'
BACKUP_INTERVAL_S='<backup job interval in seconds>'
# Section 1.2: the hub's infra unit (k3s-bootstrap), the address of the hub node's converge
# resource in it, the local-path base directory and the data-disk mount it must be on.
INFRA_UNIT="$HOME/sites/example/infra"
# A tofu address holds literal double quotes and is only compared, never run as code.
# shellcheck disable=SC2089,SC2090
INFRA_HUB_ADDR='module.k3s["hub"].terraform_data.converge'
STORAGE_PATH=/opt/garuda/k3s-storage
DATA_MOUNT=/opt/garuda
# Section 2 pins and the hub gates (STOP below the memory/disk floors or above the load/usage ceilings).
PG_IMAGE='ghcr.io/cloudnative-pg/postgresql:17.11-202611020810-standard-trixie@sha256:4d0aac315c4d8c3202252bd06fea83b16951cc57234a7b610eeaa382ff4482d0'
OPERATOR_CHART=0.29.1
MEM_MIN_MIB=1536
LOAD_MAX=1.5
ROOT_USED_MAX=70
ROOT_FREE_MIN_GIB=4   # image pulls peak above their final size; kubelet hard-evicts pods below 5 % disk free (~95 % used)
DATA_FREE_MIN_GIB=4   # 2 x the database volume (module default storage_size 2Gi)
# shellcheck disable=SC2090   # INFRA_HUB_ADDR's literal quotes are dumped to env.sh, never expanded
declare -p UNIT NS FZ HUB FZ_MODULE DB_MODULE OP_MODULE SOPS_FILE SOPS_ENC_EXPR SOPS_WG_EXPR AGE_RECIPIENT \
  AGE_IDENTITY HUB_VMID BACKUP_INTERVAL_S INFRA_UNIT INFRA_HUB_ADDR STORAGE_PATH DATA_MOUNT \
  PG_IMAGE OPERATOR_CHART MEM_MIN_MIB LOAD_MAX ROOT_USED_MAX ROOT_FREE_MIN_GIB DATA_FREE_MIN_GIB BACKUP > "$BACKUP/env.sh"
cat >> "$BACKUP/env.sh" <<'ENVSH'
export TG_TF_FORWARD_STDOUT=true TERRAGRUNT_FORWARD_TF_STDOUT=true
hub() { local remote; printf -v remote '%q ' "$@"; ssh -T -o BatchMode=yes -o ConnectTimeout=15 "$HUB" "$remote"; }
k() { hub sudo k3s kubectl --request-timeout=60s "$@"; }
kl() { hub sudo k3s kubectl "$@"; }
init_infra() { (cd "$INFRA_UNIT" && terragrunt init); }
plan_infra() { (cd "$INFRA_UNIT" && terragrunt plan "$@"); }
apply_infra() { (cd "$INFRA_UNIT" && terragrunt apply "$@"); }
infra_show_json() { (cd "$INFRA_UNIT" && terragrunt show -json "$1"); }
# Addresses a saved infra plan $1 changes (one per line, sorted).
infra_changes() {
  infra_show_json "$1" |
    jq -r '[.resource_changes[] | select(.change.actions | . != ["no-op"] and . != ["read"]) | .address] | unique | .[]'
}
apply_init() { (cd "$UNIT" && terragrunt init); }
plan_site() { (cd "$UNIT" && terragrunt plan "$@"); }
apply_site() { (cd "$UNIT" && terragrunt apply -auto-approve "$@"); }
state_pull() { (cd "$UNIT" && terragrunt state pull); }
blk() { local s; s=$(cat); bash -euo pipefail -c ". \"\$BACKUP/env.sh\"
$s"; }
fz_pod() {
  k -n "$NS" get pods -l "app.kubernetes.io/name=firezone,app.kubernetes.io/instance=$FZ" -o json |
    jq -er '.items | map(select(.status.phase == "Running" and .metadata.deletionTimestamp == null)) | if length == 1 then .[0].metadata.name else error("expected one Firezone pod") end'
}
cnpg_primary() {
  k -n "$NS" get pod -l 'cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary' -o json |
    jq -er '.items | if length == 1 then .[0].metadata.name else error("expected one primary") end'
}
# Exact per-table row counts of "public" from pod $1 (database $2, default firezone), "table|count" lines.
counts_from() {
  k -n "$NS" exec -i "$1" -c postgres -- psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d "${2:-firezone}" < "$BACKUP/counts.sql"
}
# Identical except connectivity_checks, which a background writer may only grow.
counts_cmp() {
  diff <(grep -v '^connectivity_checks|' "$1") <(grep -v '^connectivity_checks|' "$2") || return 1
  local a b
  a=$(sed -n 's/^connectivity_checks|//p' "$1")
  b=$(sed -n 's/^connectivity_checks|//p' "$2")
  [[ ( -z $a && -z $b ) || ( -n $a && -n $b && $b -ge $a ) ]]
}
# All six application secrets and the WireGuard key, as stored (base64), sorted.
keys_snapshot() {
  k -n "$NS" get secret "$FZ-env" -o json | jq -S '.data | {
    COOKIE_ENCRYPTION_SALT: (.COOKIE_ENCRYPTION_SALT // error("missing COOKIE_ENCRYPTION_SALT")),
    COOKIE_SIGNING_SALT: (.COOKIE_SIGNING_SALT // error("missing COOKIE_SIGNING_SALT")),
    DATABASE_ENCRYPTION_KEY: (.DATABASE_ENCRYPTION_KEY // error("missing DATABASE_ENCRYPTION_KEY")),
    GUARDIAN_SECRET_KEY: (.GUARDIAN_SECRET_KEY // error("missing GUARDIAN_SECRET_KEY")),
    LIVE_VIEW_SIGNING_SALT: (.LIVE_VIEW_SIGNING_SALT // error("missing LIVE_VIEW_SIGNING_SALT")),
    SECRET_KEY_BASE: (.SECRET_KEY_BASE // error("missing SECRET_KEY_BASE")),
    WIREGUARD_PRIVATE_KEY: (.WIREGUARD_PRIVATE_KEY // error("missing WIREGUARD_PRIVATE_KEY"))
  } | if all(.[]; type == "string" and length > 0) then . else error("empty application key") end'
}
keys_unchanged() { keys_snapshot | cmp - "$BACKUP/keys-original.json"; }
# Start time (epoch seconds, UTC) encoded in a Proxmox backup run ID of the hub VM: the whole PBS snapshot
# ID `vm/<HUB_VMID>/<UTC>Z` (anchored: no prefix, no namespace, nothing after the Z) or a vzdump task UPID
# of the hub VM alone (fifth field = hex epoch; the ID field is empty for a job over several guests).
# Anything else fails, so no hand-typed local time can enter a marker.
backup_run_epoch() {
  local id=$1 re
  local -a f
  [[ $HUB_VMID =~ ^[0-9]+$ ]] || return 1
  re="^vm/${HUB_VMID}/([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)\$"
  if [[ $id =~ $re ]]; then
    date -u -d "${BASH_REMATCH[1]}" +%s
  elif [[ $id == UPID:* ]]; then
    IFS=: read -ra f <<< "$id"
    [[ ${#f[@]} -ge 8 && ${f[5]} == vzdump && ${f[6]} == "$HUB_VMID" && ${f[4]} =~ ^[0-9A-Fa-f]{8}$ ]] || return 1
    printf '%d\n' "0x${f[4]}"
  else
    return 1
  fi
}
# archive_proven <local archive> <copy downloaded back from protected storage> <marker>: the stored copy is
# byte-identical to the local archive and decrypts to a readable tar; only then is the marker written.
archive_proven() {
  [[ -s $1 && -s $2 && -r $AGE_IDENTITY ]] || { echo "STOP: archive, stored copy or age identity missing" >&2; return 1; }
  cmp "$1" "$2" || { echo "STOP: the stored copy differs from the local archive" >&2; return 1; }
  age -d -i "$AGE_IDENTITY" "$2" | tar -tf - > /dev/null || { echo "STOP: the stored copy does not decrypt" >&2; return 1; }
  date -u +%FT%TZ > "$3"
}
# The 7.1 cleanup gate except the dump block itself: everything that must hold right before the old
# directory goes. No database backup exists, so the proof is: a fresh verified off-node dump, both age
# archives (section 5 and the live dump) stored and decrypt-tested, the CNPG volume on the data disk, the
# newest Proxmox backup run of the hub VM (operator-attested run ID in proxmox-backup-confirmed) newer
# than window-end and younger than one job interval, and the monitoring marker.
cleanup_gate() {
  local pv path run start now
  find "$BACKUP/dump-verified" -mmin -1440 | grep -q . ||
    { echo "STOP: no verified dump within a day; run the dump block of 7.1" >&2; return 1; }
  (cd "$BACKUP" && sha256sum -c live-before-cleanup.dump.sha256) || return 1
  [[ -s "$BACKUP/archive-5-proven" && -s "$BACKUP/archive-live-proven" ]] ||
    { echo "STOP: the section 5 archive and the live-dump archive must both be stored and decrypt-tested" >&2; return 1; }
  pv=$(k -n "$NS" get pvc postgres-1 -o jsonpath='{.spec.volumeName}') || return 1
  path=$(k get pv "$pv" -o json | jq -er --arg root "$STORAGE_PATH/" '.spec.hostPath.path | select(startswith($root))') ||
    { echo "STOP: the CNPG volume is not under $STORAGE_PATH" >&2; return 1; }
  [[ "$(hub sudo findmnt -no TARGET -T "$path")" == "$DATA_MOUNT" ]] ||
    { echo "STOP: the CNPG volume is not on the data disk $DATA_MOUNT" >&2; return 1; }
  hub sudo test -s "$path/pgdata/PG_VERSION" || { echo "STOP: no database files in $path" >&2; return 1; }
  [[ -s "$BACKUP/proxmox-backup-confirmed" ]] || { echo "STOP: no Proxmox backup run recorded" >&2; return 1; }
  run=$(< "$BACKUP/proxmox-backup-confirmed")
  start=$(backup_run_epoch "$run") ||
    { echo "STOP: the marker is not a PBS snapshot ID or vzdump UPID of VM $HUB_VMID: $run" >&2; return 1; }
  now=$(date +%s)
  (( start > $(date -d "$(cat "$BACKUP/window-end")" +%s) )) ||
    { echo "STOP: the recorded Proxmox backup run started before window-end" >&2; return 1; }
  (( start <= now && now - start < BACKUP_INTERVAL_S )) ||
    { echo "STOP: the recorded run is not younger than one job interval; attest the newest run" >&2; return 1; }
  [[ -s "$BACKUP/monitoring-confirmed" ]] || { echo "STOP: monitoring is not confirmed (section 8)" >&2; return 1; }
}
# Every pod of the cluster is Running or Succeeded (no stale Pending/Failed/CrashLoop leftovers).
pods_settled() {
  k get pods -A -o json |
    jq -e '[.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded")] | length == 0' >/dev/null
}
# Used percent of the hub filesystem holding path $1.
hub_used_pct() { hub df --output=pcent "$1" | tail -n1 | tr -d ' %'; }
k3s_restarts() { hub systemctl show k3s -p NRestarts --value; }
# STOP unless the hub has the memory, the quiet and the root-disk space for a heavy apply.
headroom() {
  local mem load used free fail
  mem=$(hub cat /proc/meminfo | awk '/^MemAvailable:/ { print int($2 / 1024) }')
  load=$(hub cat /proc/loadavg | cut -d' ' -f2)
  used=$(hub_used_pct /)
  free=$(hub df -B1 --output=avail / | tail -n1 | tr -d ' ')
  printf 'hub: MemAvailable %s MiB (min %s), 5-min load %s (max %s), root disk %s%% used (max %s), %s bytes free (min %s GiB)\n' \
    "$mem" "$MEM_MIN_MIB" "$load" "$LOAD_MAX" "$used" "$ROOT_USED_MAX" "$free" "$ROOT_FREE_MIN_GIB"
  fail=0
  if (( mem < MEM_MIN_MIB || used >= ROOT_USED_MAX || free < ROOT_FREE_MIN_GIB * 1024 ** 3 )); then
    echo "STOP: memory or root-disk space shortfall; free space, or grow the root disk / hub memory through the infra unit as a separate announced change" >&2
    fail=1
  fi
  if ! awk -v l="$load" -v m="$LOAD_MAX" 'BEGIN { exit !(l < m) }'; then
    echo "STOP: 5-min load above the ceiling; wait for a quiet period" >&2
    fail=1
  fi
  if (( fail )); then echo "never relax the thresholds in the window" >&2; return 1; fi
}
# plan_gate <label> <expected "Plan:" line> [plan args...]; PLAN_FN=plan_infra plans the infra unit.
# The pattern matches raw tofu output and Terragrunt-prefixed stdout alike; exactly one summary is required.
plan_gate() {
  local label=$1 want=$2 out got
  local -a found
  shift 2
  out=$(mktemp -p "$BACKUP")   # plan output is secret: inside the 0700 directory, removed on return
  trap 'rm -f "$out"; trap - RETURN' RETURN
  if ! "${PLAN_FN:-plan_site}" -no-color "$@" > "$out" 2>&1; then cat "$out"; echo "STOP: plan failed" >&2; return 1; fi
  cat "$out"
  mapfile -t found < <(grep -aoE 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy[.]' "$out" || true)
  got=${found[*]}
  printf '%s\n' "$got" > "$BACKUP/plan-$label.txt"
  (( ${#found[@]} == 1 )) || { printf 'STOP: expected exactly one Plan line, found %s\n' "${#found[@]}" >&2; return 1; }
  [[ "$got" == "$want" ]] || { printf 'STOP: expected [%s], got [%s]\n' "$want" "$got" >&2; return 1; }
}
ENVSH
. "$BACKUP/env.sh"
df -h "$BACKUP"
```

Confirm outside the shell that the Terraform state backend keeps version history
(you will not store a decrypted state copy) and that the site's sops file and
its decrypt capability are backed up.

### 1.2 Storage location precondition

There are no database backups, so **the data disk is the only protection** of the
database. Placement is a platform concern, and before Apply #1 the database volume
must be on the Proxmox-backed-up data disk with room to grow; neither belongs in a
Kubernetes module. The `Retain` class keeps the volume directory when the Cluster,
PVC or namespace go; it does not survive the loss of the disk. A rebuilt VM loses the
PVC-to-volume binding (it lives in the k3s datastore on the root disk) in every case,
and the volume directory only if the data disk survives: when the data disk is an
inline disk of the VM resource in Terraform (the production layout: `virtio1`, serial
`garuda-data`, mounted at `/opt/garuda` by label), destroying or rebuilding that
resource through Terraform **destroys the data disk** and only a `protection` setting
blocks it. The same holds for the v2 hostPath database today. See section 9. Confirm in
Proxmox, and record in section 1.6 item 6, that this VM's data disk is part of a
scheduled backup job, how that job runs and when its last run succeeded (the gate of
section 7.1 needs a run **after** the migration).

#### Volumes on the data disk

The CNPG volume is a `local-path` volume, so it lands under the provisioner's base
directory. The hub's k3s must have it on the data disk through the infra unit's
k3s-bootstrap `k3s_config` **of the hub only** (not through the application stack).
A stack that runs one `module "k3s"` over several nodes (hub and edges) with a
shared literal `k3s_config` must not edit that literal: every node's `converge`
would be replaced and the edges restarted for a setting they do not use. Merge the
key in conditionally:

```hcl
k3s_config = merge(
  { "kubelet-arg" = ["... existing keys ..."] },
  # hub only: local-path volumes (the CNPG database) on the backed-up data disk = STORAGE_PATH
  each.key == "hub" ? { "default-local-storage-path" = "/opt/garuda/k3s-storage" } : {},
)
```

Behaviour verified on the stand (a running k3s, changed through k3s-bootstrap v0.3.2):
the node's `terraform_data.converge` is **replaced** (plan `1 to add, 0 to change,
1 to destroy` for one node), k3s restarts, and the `local-path-config` ConfigMap
then carries the new path. Volumes that already exist keep their old directory;
only new volumes use the new one. The directory itself is created by the
provisioner with the first volume, so on a missing or unmounted data disk it
would silently appear on the root disk: the first block therefore requires the
mount **before** creating the directory. The k3s restart interrupted the client
data plane for up to about a minute on the stand (62 s once, not measurable another time) (the pods are not recreated, but the
node's networking and workloads reconcile): do it as its own announced
interruption, before the migration window. The v2 sidecar uses its own hostPath and
is unaffected.

First prove the mount and the capacity (the database volume lives here; with no
quota on `local-path`, keep at least five times the database size free: a rule of thumb for the
7.1 scratch copy of the database (1x), growth until the next check and WAL up to
`wal_keep_size`, plus margin; an absolute floor of twice the volume size covers small
databases. The root disk, which holds the k3s datastore and the images, stays below its
ceiling):

```bash
blk <<'EOF'
hub mountpoint -q "$DATA_MOUNT"
hub sudo mkdir -p -m 0755 "$STORAGE_PATH"
[[ "$(hub findmnt -no TARGET -T "$STORAGE_PATH")" == "$DATA_MOUNT" ]]
hub findmnt -no SOURCE,TARGET,FSTYPE -T "$STORAGE_PATH"
db_bytes=$(k -n "$NS" exec "$(fz_pod)" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d firezone -Atc "SELECT pg_database_size('firezone')")
free_bytes=$(hub df -B1 --output=avail "$STORAGE_PATH" | tail -n1 | tr -d ' ')
root_used=$(hub_used_pct /)
printf 'database %s bytes; free on the data disk %s bytes (needs 5x and %s GiB); root disk %s%% used (max %s%%)\n' \
  "$db_bytes" "$free_bytes" "$DATA_FREE_MIN_GIB" "$root_used" "$ROOT_USED_MAX"
(( free_bytes >= 5 * db_bytes ))
(( free_bytes >= DATA_FREE_MIN_GIB * 1024 ** 3 ))
(( root_used < ROOT_USED_MAX ))
echo CAPACITY_OK
EOF
```

Edit the hub's `k3s_config` as above, then gate the **infra unit**. If the
pre-window checklist (section 1.6, item 3) already ran this gate and apply, skip both
here: re-running the gate would STOP with `found 0`, because the replacement is
already in state. The gate saves
the plan (the plan output is secret, section 0) and asserts the one replaced
resource by its address, not only by count:

```bash
blk <<'EOF'
init_infra
PLAN_FN=plan_infra plan_gate infra 'Plan: 1 to add, 0 to change, 1 to destroy.' -out="$BACKUP/infra.tfplan"
changed=$(infra_changes "$BACKUP/infra.tfplan")
printf 'changed: %s\n' "$changed"
[[ "$changed" == "$INFRA_HUB_ADDR" ]]
echo INFRA_GATE_OK
EOF
```

**STOP** unless the line is exactly that and the one replacement is the hub's
`terraform_data.converge` (`INFRA_HUB_ADDR`): a second node's address means the
`k3s_config` edit reached an edge, and any other change in the infra unit is applied
separately before this migration. Then apply **the saved plan** (not a recomputed
one: what was reviewed is what runs) in its own announced interruption; stale pods
are a STOP first, because k3s restarts and what is already broken is hard to tell
apart from what the restart broke:

```bash
blk <<'EOF'
# A rejected plan must not be applicable: re-assert the gate before applying its saved plan.
[[ "$(cat "$BACKUP/plan-infra.txt")" == 'Plan: 1 to add, 0 to change, 1 to destroy.' ]]
[[ "$(infra_changes "$BACKUP/infra.tfplan")" == "$INFRA_HUB_ADDR" ]]
pods_settled || { echo "STOP: pods that are not Running/Succeeded; resolve them before restarting k3s" >&2; k get pods -A | grep -vE 'Running|Completed'; exit 1; }
printf 'k3s restarts before: %s\n' "$(k3s_restarts)"
apply_infra "$BACKUP/infra.tfplan"
echo INFRA_APPLIED
EOF
```

The checks after the apply are their own block: re-run it as often as needed (a lost
terminal, a slow restart) without applying anything again. It waits for the API, for the
new path in the ConfigMap, restarts the provisioner and settles the pods:

```bash
blk <<'EOF'
for _ in $(seq 60); do k get --raw=/readyz >/dev/null 2>&1 && break; sleep 3; done
k get --raw=/readyz
for _ in $(seq 60); do
  path=$(k -n kube-system get cm local-path-config -o json | jq -er '.data["config.json"] | fromjson | .nodePathMap | map(select(.node == "DEFAULT_PATH_FOR_NON_LISTED_NODES") | .paths) | add | join(",")') && [[ $path == "$STORAGE_PATH" ]] && break
  sleep 3
done
[[ $path == "$STORAGE_PATH" ]]
# The provisioner sees the new ConfigMap only after kubelet syncs its mounted file (minutes): restart it so
# the throwaway claim below cannot land on the old path (found on the stand: it did, right after the apply).
k -n kube-system rollout restart deployment/local-path-provisioner
k -n kube-system rollout status deployment/local-path-provisioner --timeout=180s
for _ in $(seq 60); do pods_settled && break; sleep 3; done
pods_settled
k -n "$NS" get pods
printf 'k3s restarts after: %s\n' "$(k3s_restarts)"
echo STORAGE_PATH_OK
EOF
```

Prove that the provisioner now really writes under `STORAGE_PATH` on the data
disk, with a throwaway claim of the built-in `local-path` class (reclaim `Delete`,
so the claim, its volume and its directory disappear with it):

```bash
blk <<'EOF'
P=local-path-probe
cleanup() { k -n default delete pod,pvc "$P" --ignore-not-found --wait=true --timeout=120s; }
trap cleanup EXIT
cleanup
image=$(k -n kube-system get cm local-path-config -o json | jq -er '.data["helperPod.yaml"]' | awk '/image:/ { print $2; exit }')
k apply -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $P, namespace: default}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: {requests: {storage: 16Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: $P, namespace: default}
spec:
  restartPolicy: Never
  containers:
    - name: w
      image: $image
      command: [sh, -c, "echo ok > /data/probe"]
      volumeMounts: [{name: d, mountPath: /data}]
  volumes:
    - name: d
      persistentVolumeClaim: {claimName: $P}
YAML
k -n default wait "pod/$P" --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
pv=$(k -n default get pvc "$P" -o jsonpath='{.spec.volumeName}')
# the built-in class provisions `local` volumes, the Retain class of the module hostPath ones
path=$(k get pv "$pv" -o json | jq -er --arg root "$STORAGE_PATH/" '(.spec.hostPath.path // .spec.local.path) | select(startswith($root))')
[[ "$(hub sudo cat "$path/probe")" == ok ]]
# the provisioner makes the base directory 0700 root, so the inner path needs sudo
[[ "$(hub sudo findmnt -no TARGET -T "$path")" == "$DATA_MOUNT" ]]
cleanup
trap - EXIT
for _ in $(seq 40); do hub sudo test -e "$path" || break; sleep 3; done
if hub sudo test -e "$path"; then echo "STOP: the probe volume directory was not removed" >&2; exit 1; fi
echo LOCAL_PATH_OK
EOF
```

### 1.3 Preflight (asserted, not just printed)

Confirm in configuration that the Firezone module source and chart are
`v2.0.1` / `2.0.1` (the check below reads the state). Record the k3s-bootstrap
pin manually. On Ubuntu kernels **≥7.0.0-41**, k3s-bootstrap **≥v0.3.2** is
mandatory before either apply: apply it separately, recreate affected pods, then
run this block. Never disable AppArmor or relax host restrictions to get through
this migration; v0.3.2 fixes runc attachment, not database permissions, and its
named unconfined `runc`/`userns` trade-off must be accepted by the operator.

```bash
blk <<'EOF'
[[ "$(k get nodes -o name)" == "node/$(hub hostname)" ]]
kernel=$(hub uname -r)
echo "hub kernel: $kernel"
hub df -h /opt /var/lib/rancher/k3s
k -n "$NS" get deployment "$FZ" -o wide
apply_init
version=$(state_pull | jq -er --arg m "$FZ_MODULE" '[.resources[] | select(.module == $m and .type == "helm_release" and .name == "firezone")] | if length == 1 then .[0].instances[0].attributes.version else error("no single firezone helm_release in state") end')
[[ "$version" == 2.0.1 ]]
OLD_POD=$(fz_pod)
k -n "$NS" get pod "$OLD_POD" -o json > "$BACKUP/old-pod.json"
jq -e 'any(.spec.containers[]; .name == "postgres")' "$BACKUP/old-pod.json" >/dev/null
jq -er '.spec.volumes[] | select(.name == "postgres-data") | .hostPath.path' "$BACKUP/old-pod.json" > "$BACKUP/old-data-path"
k -n "$NS" exec "$OLD_POD" -c postgres -- pg_isready -U postgres -d firezone
k -n "$NS" exec "$OLD_POD" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d firezone -Atc 'SHOW server_version;'
k -n "$NS" exec "$OLD_POD" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d firezone -Atc "SELECT pg_size_pretty(pg_database_size('firezone'));"
# Rollback depends on the sidecar accepting loopback connections without a prompt.
k -n "$NS" exec "$OLD_POD" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d firezone -c 'SELECT line_number, type, database, user_name, address, auth_method, error FROM pg_hba_file_rules'
[[ "$(k -n "$NS" exec "$OLD_POD" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d firezone -Atc 'SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL')" == 0 ]]
[[ "$(k -n "$NS" exec "$OLD_POD" -c postgres -- env -u PGPASSWORD psql -X -w -h 127.0.0.1 -U postgres -d firezone -Atc 'SELECT 1')" == 1 ]]
# AppArmor: no stacked label anywhere, enabled, both sysctls 1, runc profile present.
label=$(k -n "$NS" exec "$OLD_POD" -c postgres -- sh -ec 'cat /proc/self/attr/current; trap : USR1; kill -USR1 $$; locale -a >/dev/null')
echo "postgres container label: $label"
[[ "$label" != *'//&'* ]]
hub_labels=$(hub sudo sh -c 'cat /proc/[0-9]*/attr/current 2>/dev/null | tr "\0" "\n"')
[[ -n $hub_labels ]]
if [[ $hub_labels == *'//&'* ]]; then
  echo "STOP: a hub process has a stacked AppArmor label" >&2; exit 1
fi
[[ "$(hub sudo aa-enabled)" == Yes ]]
for s in kernel.apparmor_restrict_unprivileged_userns kernel.apparmor_restrict_unprivileged_unconfined; do
  [[ "$(hub sysctl -n "$s")" == 1 ]]
done
if [[ "$(printf '%s\n' "$kernel" 7.0.0-41 | sort -V | head -n1)" == 7.0.0-41 ]]; then
  hub sudo test -f /etc/apparmor.d/k3s-bootstrap-runc
fi
echo PREFLIGHT_OK
EOF
```

RuntimeDefault is normally `cri-containerd.apparmor.d (enforce)`;
privileged/Unconfined containers can be `runc (unconfined)`.

### 1.4 Capture and verify the keys (never print or commit these files)

```bash
blk <<'EOF'
keys_snapshot > "$BACKUP/keys-original.json"
jq -S '{
  guardianSecretKey: (.GUARDIAN_SECRET_KEY | @base64d),
  secretKeyBase: (.SECRET_KEY_BASE | @base64d),
  liveViewSigningSalt: (.LIVE_VIEW_SIGNING_SALT | @base64d),
  cookieSigningSalt: (.COOKIE_SIGNING_SALT | @base64d),
  cookieEncryptionSalt: (.COOKIE_ENCRYPTION_SALT | @base64d),
  databaseEncryptionKey: (.DATABASE_ENCRYPTION_KEY | @base64d)
}' "$BACKUP/keys-original.json" > "$BACKUP/encryption-secrets.json"
jq -j '.WIREGUARD_PRIVATE_KEY | @base64d' "$BACKUP/keys-original.json" > "$BACKUP/wireguard-private-key"
test -s "$BACKUP/wireguard-private-key"
echo CAPTURED
EOF
```

`keys_snapshot` fails on any missing or empty key (it does not rely on
`@base64d`, which turns `null` into a string). The file uses **exact camelCase
field names** (not the Secret's UPPER_SNAKE names): the module's older recovery
hint does not translate them, and unknown object keys are discarded, so keys would
silently regenerate after a state loss.

**A. Production (the stack already passes a sops `encryption_secrets` object).**
Compare all six fields and the WireGuard key against the live Secret, byte for
byte. `databasePassword` is excluded from the comparison only: it stays in sops
untouched (v3 ignores it; a rollback to v2 reuses it).

```bash
blk <<'EOF'
cmp <(jq -S . "$BACKUP/encryption-secrets.json") \
    <(sops -d --output-type json "$SOPS_FILE" | jq -Se "$SOPS_ENC_EXPR | del(.databasePassword)")
cmp "$BACKUP/wireguard-private-key" \
    <(sops -d --output-type json "$SOPS_FILE" | jq -ej "$SOPS_WG_EXPR")
echo SOPS_MATCHES_LIVE
EOF
```

Any difference is a STOP: the live Secret is authoritative, never replace it with
an unused generated or stale value. Fix the sops file first. If `jq` reports a
missing key, fix the expression (`SOPS_ENC_EXPR` / `SOPS_WG_EXPR`, which must point
at the keys the stack's `encryption_secrets` / `wireguard_private_key` inputs read)
or the stack, **never add keys** to make the comparison pass.

**B. Only if no override exists (generated keys, e.g. the stand).** The live key
must equal the generated key in state, then store the captured six-field object
in the site's sops store, wire it into `encryption_secrets` unchanged, and keep
`wireguard_private_key` byte-identical. This runs after the capture above, so a
mismatch cannot lose the capture.

```bash
blk <<'EOF'
state_pull | jq -j --arg m "$FZ_MODULE" '[.resources[] | select(.module == $m and .type == "random_bytes" and .name == "database_encryption_key")] | if length == 1 then .[0].instances[0].attributes.base64 else error("no single generated database key in state") end' |
  cmp - <(jq -j '.databaseEncryptionKey' "$BACKUP/encryption-secrets.json")
echo STATE_KEY_MATCHES_LIVE
EOF
```

Never put a decrypted override or private key in tracked Terraform files.

### 1.5 Exact per-table counts (not `pg_stat_user_tables` estimates)

```bash
blk <<'EOF'
cat > "$BACKUP/counts.sql" <<'SQL'
\set ON_ERROR_STOP on
SELECT format('SELECT %L, count(*) FROM %I.%I;', tablename, schemaname, tablename)
FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename
\gexec
SQL
counts_from "$(fz_pod)" > "$BACKUP/counts-preflight.txt"
cat "$BACKUP/counts-preflight.txt"
EOF
```

### 1.6 Production pre-window checklist

The stand rehearsal replaced the production helper layer (see "Not run as written"), so
the first production contact is a separate, announced task **before** the window.
Items 1 and 2 are read-only; the window is not scheduled until all seven items are
recorded.

1. **Read-only dry-run on the hub**, with a throwaway `$BACKUP` (section 1.1 against
   the real hub alias, `UNIT`, `INFRA_UNIT`): sections 1.1, 1.3, 1.4 (capture and
   comparison A with the corrected `SOPS_*` expressions) and 1.5. Shred the
   directory afterwards; it holds key material and a database snapshot of counts.
2. **Terragrunt.** `terragrunt --version` is at least 0.67.5. The `plan_gate` extraction
   finds exactly one `Plan:` line in real `terragrunt plan` output of **both** units. A
   settled unit has no such line, so probe with a plan-only destroy preview of one cheap
   resource (nothing is applied): `plan_gate probe 'Plan: 0 to add, 0 to change, 1 to
   destroy.' -destroy -target=<one resource address>` for the garuda unit and with
   `PLAN_FN=plan_infra` for the infra unit. The probe passes when it reports the
   count it found (a mismatch of the expected count is fine here, `found 0` or `plan
   failed` is not). Then `plan_site -no-color -detailed-exitcode` exits 0 **and prints
   no `Plan:` line** (the drift check of section 5): the garuda unit has no unrelated
   drift.
3. **Storage.** Section 1.2 mount and capacity blocks pass, and the section 2
   headroom block passes; the hub-only `k3s_config` edit is in place; the infra
   gate shows `1 to add, 0 to change, 1 to
   destroy` on `INFRA_HUB_ADDR` and nothing else; the saved plan is applied in its own
   announced interruption and the throwaway `local-path` claim lands under
   `STORAGE_PATH`.
4. **Release.** The garuda release with the CNPG modules is cut and the module trees
   of `modules/cnpg_operator` and `modules/cnpg_database` in it equal those of
   garuda-internal `906bcc06` (module delta since the rehearsed `b12124c4`: unused backup and
   generation code and outputs removed; rendered values of the database release unchanged,
   tftest `rendered_values_are_exactly_the_plain_initdb_cluster`; gate lines unchanged);
   both images of Apply #1 are pre-pulled (section 2).
5. **Protection.** The state backend keeps version history; the sops file and a way
   to decrypt it are backed up; the age recipient decrypts; the Proxmox backup job
   of the data disk exists and its failure alerts a human; the disk and backup-freshness
   monitoring of section 8 (schedule and alert) exists before 7.1 is ever run.
   Section 7.2 is not run on a production site before it has been re-run on the stand.
6. **Backup facts of the site.** Not known to this runbook; record them, never assume them:
   hub VM id `<hub VM id>` (`HUB_VMID`); backup job schedule `<backup job schedule = accepted
   RPO>` and its interval in seconds (`BACKUP_INTERVAL_S`), with the RPO signed off by
   `<site owner>` on `<date>`; backup storage `<PBS datastore | file storage>` (this decides
   the run ID form of 7.1 and the freshness query of section 8); retention `<keep policy>`;
   snapshot mode with the guest agent enabled in the VM options and running in the guest;
   who is alerted on a failed run `<alert target>`; and the 7.1 inspection list passes on the
   newest run today (data disk included, root disk excluded, freeze/thaw in the task log; its
    File Restore line is item 7's, because the CNPG volume does not exist before Apply #1b).
7. **Re-attach rehearsal.** The re-attach procedure (section 9.1) carries a rehearsal note
   and record (below) of both cases; read it now, not after a loss, and have it rehearsed at
   the pinned commit before the window. The Proxmox and Terraform side of section 9 is not
   covered by that rehearsal. Its cheap pre-window proof is a **File Restore** of
   `drive-virtio1.img` (`raw`) in the newest PBS snapshot of the hub VM: it must list the v2
   database's `PG_VERSION` at the `old-data-path` of 1.3 without the `DATA_MOUNT` prefix (production
   layout: `firezone/postgres-data/PG_VERSION`; the v2 sidecar's PGDATA is that directory). The CNPG volume
   (`k3s-storage/.../pgdata/PG_VERSION`) exists only after Apply #1b; the 7.1 inspection proves it.

## 2. Apply #1 — add CNPG, leave Firezone v2.0.1 (1a operator, 1b database)

Add the existing `cnpg_operator` and `cnpg_database` modules from a garuda
release. Source them as modules, do **not** copy directories into the stack. Chart
pins, in the module defaults or inputs: operator chart **0.29.1**, Cluster chart
**0.9.0**, Cluster/release **postgres**, DB/owner **firezone**, one instance,
PostgreSQL **17.11**, StorageClass **local-path-retain** (`Retain`),
`enableSuperuserAccess = false`, Cluster annotation `helm.sh/resource-policy = keep`.
Keep the operator outside the application's release and running for the whole
database lifecycle. Use the same hub providers as `module.firezone_kube`.

There are no backups: `cnpg_database` has no backup input and nothing installs a backup
plugin. Durability is the Proxmox backup of the data disk (section 9).

```hcl
module "cnpg_operator" {
  source = "git::https://github.com/garuda-tunnel/garuda.git//modules/cnpg_operator?ref=<garuda release containing cnpg modules>"
  # renovate: datasource=docker depName=ghcr.io/cloudnative-pg/charts/cloudnative-pg
  chart_version = "0.29.1"
  providers = {
    helm       = helm.hub
    kubernetes = kubernetes.hub
  }
  depends_on = [<the module that provides the k3s hub and namespace>]
}

module "firezone_db" {
  source = "git::https://github.com/garuda-tunnel/garuda.git//modules/cnpg_database?ref=<garuda release containing cnpg modules>"
  # renovate: datasource=docker depName=ghcr.io/cloudnative-pg/charts/cluster
  chart_version = "0.9.0"
  # shortcut: the org Renovate regex needs an X.Y.Z value and has no digest capture, so this
  # tag@digest pin is bumped by hand until garuda-tunnel/.github gains a digest matchString.
  image = "ghcr.io/cloudnative-pg/postgresql:17.11-202611020810-standard-trixie@sha256:4d0aac315c4d8c3202252bd06fea83b16951cc57234a7b610eeaa382ff4482d0"
  providers = {
    helm = helm.hub
  }
  namespace     = "garuda" # = NS: the Firezone release namespace
  name          = "postgres"
  database      = "firezone"
  owner         = "firezone"
  storage_class = module.cnpg_operator.storage_class_name
}
```

For production stacks add **only these blocks** (operator, database) and leave
`module.firezone_kube` on v2.0.1 exactly as it is. The garuda-internal mini-site
at the CNPG-enabled revision already contains them, but its Firezone block is the
final v3 one: there, keep both CNPG blocks and restore the **entire**
`module "firezone_kube"` block from the site's v2.0.1 configuration: source
`?ref=v2.0.1`, chart `2.0.1`, original `firezone_dir =
local.firezone_facts.directory`, no `database_secret_name`, no database
dependency in `depends_on`, all other inputs (encryption and WireGuard keys)
preserved, plus the old `local.firezone_facts.directory` field in `locals.tf`
(mini-site default `/opt/garuda/firezone`; use the site's original value). The
rollback in section 6 uses this same v2 block.

Headroom first. Apply #1 is heavy: the operator and PostgreSQL start and pull images, and a
hub of the stand's size (2 vCPU, 4 GiB) lost its k3s API under the load of a combined
apply (see "If an apply is cut by a k3s restart" below).
The block stops unless the hub has `MEM_MIN_MIB` of available memory, a 5-minute load
below `LOAD_MAX`, a root disk below `ROOT_USED_MAX` % used with `ROOT_FREE_MIN_GIB`
free, and no stale pod. It then pulls every image of Apply #1 into the hub's
containerd **before** anything is applied: the PostgreSQL image of the `firezone_db`
block (`PG_IMAGE`) and the operator image that the pinned operator chart renders. The free-space floor is absolute because a pull needs more than the image's
final size while it unpacks: on a stand hub with an 8.6 GiB root disk (79 % used) it
crossed the kubelet's hard eviction threshold (k3s default: imagefs/nodefs available
below 5 %, i.e. ~95 % used), a pod was evicted and the client lost
its tunnel for about 6 minutes (see the rehearsal record). STOP on any failure, wait
for a quiet period and run it again; never relax a threshold in the window. This
needs `helm` on the operator machine and internet access from the hub. If a chart pin
changes, so does the image set: the block derives it, and the check after Apply #1b
proves that every image the new pods use was pulled here.

```bash
blk <<'EOF'
headroom
pods_settled
render() {
  helm template x "oci://ghcr.io/cloudnative-pg/charts/$1" --version "$2" |
    sed -nE 's/^[[:space:]]*(- )?image:[[:space:]]*"?([^" ]+)"?[[:space:]]*$/\2/p'
}
{ printf '%s\n' "$PG_IMAGE"; render cloudnative-pg "$OPERATOR_CHART"; } |
  sort -u > "$BACKUP/prepull-images"
cat "$BACKUP/prepull-images"
(( $(wc -l < "$BACKUP/prepull-images") >= 2 ))
while IFS= read -r -u 3 image; do
  hub sudo k3s crictl pull "$image"
done 3< "$BACKUP/prepull-images"
headroom
echo PREPULL_OK
EOF
```

Apply #1 is two applies, both with the Firezone module untouched, so that each
interruption is as small as it can be and the second starts from a settled hub:
**1a** the operator and the Retain StorageClass (`-target="$OP_MODULE"`), **1b** the
database (`-target="$DB_MODULE"`).
Gate 1a (read the plan; `-target` includes dependencies; Firezone must not appear):

```bash
blk <<'EOF'
apply_init
plan_gate apply1a 'Plan: 2 to add, 0 to change, 0 to destroy.' -target="$OP_MODULE"
EOF
```

**STOP** unless the line is exactly that and the two additions are the operator
Helm release and the Retain StorageClass.
Apply 1a, then assert (the block prints the k3s restart counter before and after):

```bash
blk <<'EOF'
headroom
printf 'k3s restarts before: %s\n' "$(k3s_restarts)"
apply_site -target="$OP_MODULE"
k -n cnpg-system rollout status deployment/cnpg-cloudnative-pg --timeout=300s
k get storageclass local-path-retain -o json | jq -e '.reclaimPolicy == "Retain"' >/dev/null
k get crd clusters.postgresql.cnpg.io
for _ in $(seq 60); do pods_settled && break; sleep 3; done
pods_settled
printf 'k3s restarts after: %s\n' "$(k3s_restarts)"
echo APPLY1A_OK
EOF
```

Gate 1b. Wait until `headroom` passes again first (the pods of 1a settling raises the
load); the database Helm release is the one addition:

```bash
blk <<'EOF'
headroom
plan_gate apply1b 'Plan: 1 to add, 0 to change, 0 to destroy.' -target="$DB_MODULE"
EOF
```

**STOP** unless the line is exactly that and the one addition is the database Helm
release. The expected counts come from the stand run of garuda-internal `a8c3806f`
(`modules/cnpg_operator`, `modules/cnpg_database`; the sum is the single
`Plan: 3 to add` of a combined apply); if the pinned modules change them, update these
lines from a new stand run before the window, never in it.

Apply 1b, then assert:

```bash
blk <<'EOF'
printf 'k3s restarts before: %s\n' "$(k3s_restarts)"
apply_site -target="$DB_MODULE"
k -n "$NS" wait cluster/postgres --for=condition=Ready --timeout=300s
PRIMARY=$(cnpg_primary)
k -n "$NS" wait "pod/$PRIMARY" --for=condition=Ready --timeout=300s
[[ "$(k -n "$NS" exec "$PRIMARY" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d firezone -Atc 'SELECT current_user, pg_is_in_recovery()')" == 'postgres|f' ]]
[[ "$(k -n "$NS" exec "$PRIMARY" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d firezone -Atc "SELECT count(*) FROM pg_tables WHERE schemaname='public'")" == 0 ]]
k -n "$NS" get secret postgres-app -o json | jq -e '.data | has("host") and has("port") and has("dbname") and has("username") and has("password")' >/dev/null
k -n "$NS" get cluster postgres -o json | jq -e '.metadata.annotations["helm.sh/resource-policy"] == "keep" and .spec.enableSuperuserAccess == false' >/dev/null
# The volume landed on the data disk (section 1.2), not on the root disk.
pv=$(k -n "$NS" get pvc postgres-1 -o jsonpath='{.spec.volumeName}')
k get pv "$pv" -o json | jq -er --arg root "$STORAGE_PATH/" '.spec.hostPath.path | select(startswith($root))'
# Every image the new pods run was pulled by the pre-pull block, and PG_IMAGE is the Cluster's image.
[[ "$(k -n "$NS" get cluster postgres -o jsonpath='{.spec.imageName}')" == "$PG_IMAGE" ]]
k get pods -A -o json | jq -r '.items[] | select(.metadata.namespace == "cnpg-system" or .metadata.labels["cnpg.io/cluster"] == "postgres") | (.spec.containers[], (.spec.initContainers // [])[]) | .image' |
  sort -u > "$BACKUP/running-images"
[[ -z "$(comm -13 "$BACKUP/prepull-images" "$BACKUP/running-images")" ]]
echo "primary: $PRIMARY"
k -n "$NS" get pod "$(fz_pod)" -o json | jq -e 'any(.spec.containers[]; .name == "postgres")' >/dev/null
printf 'k3s restarts after: %s\n' "$(k3s_restarts)"
echo APPLY1B_OK
EOF
```

The initial primary is normally **postgres-1**, but always select it by CNPG
labels (`cnpg_primary`); never restore to a replica. All commands inside it use
`postgres` over the **local Unix socket** (no `-h`, no password); disabled
superuser password access does not disable peer authentication there. Confirm
the UI/client still work. No Firezone upgrade belongs in Apply #1. Apply #1 is
**not** interruption-free even when split; announce an interruption of several
minutes, in a quiet period.

**If an apply is cut by a k3s restart.** On the stand's hub (2 vCPU, 4 GiB, on a
CPU-starved nested host) the k3s API timed out and k3s restarted once under the
load of a single combined apply (journal: handler timeouts, controller-manager lost
its lease, exit 1), and the client lost the tunnel for 289 s until its workloads were
back; the commands then fail with API timeouts or refused connections, and
`k3s_restarts` is higher than printed before (`NRestarts` counts only automatic
restarts after a failure, not the planned restart of section 1.2). Do nothing by hand
and delete nothing:

1. Wait for k3s: `k get --raw=/readyz`, then `pods_settled` and `headroom` (the
   restart count and `hub sudo journalctl -u k3s` say why it restarted).
2. Run the **same gate** again. State may lag what was created (a release installed but
   not recorded, a failed release marked for replacement), so its line may differ.
3. Accept a different line **only** if every action is a create or replace of a resource
   of `module.cnpg_operator` or `module.firezone_db`
   **and CNPG holds no data yet** (nothing restored: before 3.2). Anything touching
   Firezone, the infra unit or another module is a STOP. A replaced database release
   meets the kept (`helm.sh/resource-policy = keep`) empty Cluster: use the back-out
   below to remove the **empty** Cluster first, never to remove a Cluster with data.
4. Apply again and run the assertion block of the cut step.

**Back-out of a failed or abandoned Apply #1** (Firezone v2 is untouched, so
the site keeps working): inspect first. To abandon, remove the `firezone_db`
block and apply targeted at it (the Cluster has the keep annotation and
survives; the database is empty at this point), delete the empty Cluster with
the guarded steps of section 7 (retirement part), and remove the operator block
**last**, only after no Cluster exists.

## 3. Migration window — dump, restore, compare

Announce **no administrative edits, user/device enrollment, token creation or
OIDC configuration changes** until verification finishes. Existing clients may
keep sending packets; device handshake/counter updates after the dump are
intentionally lost. Allowed background writes: only `connectivity_checks` rows
(production only: a background job inserts one every 60 s after start and every
12 h) — the guards below tolerate their growth and nothing else. A transient
`api_tokens` row on sites with OIDC (created by the reconcile sidecar) is **not**
tolerated: if `api_tokens` differs, inspect it (never print token values) and
decide before continuing. Stop automation that performs admin changes. If other
writes cannot be stopped, arrange a proper write-freeze first. Do not scale
Firezone to zero: that also stops its PostgreSQL sidecar.

### 3.1 Dump (and prove nothing changed under it)

```bash
blk <<'EOF'
date -u +%FT%TZ > "$BACKUP/window-start"
OLD_POD=$(fz_pod)
counts_from "$OLD_POD" > "$BACKUP/counts-before.txt"
kl -n "$NS" exec "$OLD_POD" -c postgres -- pg_dump -Fc -U postgres firezone > "$BACKUP/firezone.dump.part"
test -s "$BACKUP/firezone.dump.part"
mv "$BACKUP/firezone.dump.part" "$BACKUP/firezone.dump"
(cd "$BACKUP" && sha256sum firezone.dump > firezone.dump.sha256)
counts_from "$OLD_POD" > "$BACKUP/counts-after-dump.txt"
counts_cmp "$BACKUP/counts-before.txt" "$BACKUP/counts-after-dump.txt" ||
  { echo "STOP: the old database changed while dumping; find the writer, then redo 3.1" >&2; exit 1; }
cat "$BACKUP/counts-before.txt"
EOF
```

The dump is on the controller **off the node**, not in a pod or hostPath.

### 3.2 Restore and compare

```bash
blk <<'EOF'
(cd "$BACKUP" && sha256sum -c firezone.dump.sha256)
PRIMARY=$(cnpg_primary)
[[ "$(k -n "$NS" exec "$PRIMARY" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d firezone -Atc "SELECT count(*) FROM pg_tables WHERE schemaname='public'")" == 0 ]]
kl -n "$NS" exec -i "$PRIMARY" -c postgres -- pg_restore --list < "$BACKUP/firezone.dump" > "$BACKUP/dump.list"
kl -n "$NS" exec -i "$PRIMARY" -c postgres -- pg_restore --exit-on-error --single-transaction \
  --no-owner --no-acl --role=firezone -U postgres -d firezone < "$BACKUP/firezone.dump"
counts_from "$PRIMARY" > "$BACKUP/counts-restored.txt"
counts_cmp "$BACKUP/counts-before.txt" "$BACKUP/counts-restored.txt"
echo RESTORE_OK
EOF
```

Restore is atomic and fails on its first error. Do not use `--clean`, and never
restore into a populated or live database. A count mismatch ends the window
without upgrade: the v2 site is still authoritative; investigate the concurrent
writer first.

### 3.3 Reset the CNPG database for a new restore (only while v2 serves)

Only if 3.2 failed or a retry is needed, or in section 6 before going forward
again after a rollback: in all of these v2 is the running Firezone and **no
workload uses the CNPG database**. The guards refuse to run if the running Firezone
pod is not the v2 sidecar pod, the Deployment references the CNPG secret, or
anything is connected to the CNPG `firezone` database. It then recreates `public`
and requires 0 tables; afterwards repeat 3.1 (fresh dump) and 3.2. After a rollback
from a v3 that took writes, the reset discards the only live copy of those writes:
the explicit loss decision of section 6 must precede it.

```bash
blk <<'EOF'
k -n "$NS" get pod "$(fz_pod)" -o json | jq -e 'any(.spec.containers[]; .name == "postgres")' >/dev/null
k -n "$NS" get deployment "$FZ" -o json | jq -e '[.spec.template.spec.containers[].env[]? | select(.valueFrom.secretKeyRef.name? == "postgres-app")] | length == 0' >/dev/null
PRIMARY=$(cnpg_primary)
[[ "$(k -n "$NS" exec "$PRIMARY" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d firezone -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname = 'firezone' AND pid <> pg_backend_pid()")" == 0 ]]
k -n "$NS" exec "$PRIMARY" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d firezone -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION firezone;'
[[ "$(k -n "$NS" exec "$PRIMARY" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d firezone -Atc "SELECT count(*) FROM pg_tables WHERE schemaname='public'")" == 0 ]]
echo RESET_OK
EOF
```

## 4. Apply #2 — switch Firezone to v3

Restore the final CNPG-enabled Firezone block: source `?ref=v3.0.0`, chart
`3.0.0`, `database_secret_name = module.firezone_db.secret_name`,
`module.firezone_db` in `depends_on`, no `firezone_dir`, no `postgres_image`.
Leave the sops `encryption_secrets` object as it is, `databasePassword`
included: v3 no longer has that attribute and ignores it, and a rollback reuses
it. Do not move module/resource addresses. All six application secrets and the
WireGuard key must still match the captured values. Do not use saved plans
(ephemeral `tunnel_path` connections).

Gate:

```bash
blk <<'EOF'
apply_init
plan_gate v3 'Plan: 0 to add, 1 to change, 1 to destroy.' -target="$FZ_MODULE"
EOF
```

**STOP** unless the line is exactly that: the one change is the Firezone
`helm_release` (`2.0.1` → `3.0.0`) and the one destruction is
`random_bytes.database_password`. Targeting includes dependencies; any unrelated
replacement is a STOP. If configuration or state changes after the gate, run
the gate again.

Apply. The first lines are the write-freeze check, **immediately before** the
change: both databases are re-counted against `counts-before` (only
`connectivity_checks` may have grown) and the keys re-compared.

```bash
blk <<'EOF'
OLD_POD=$(fz_pod)
PRIMARY=$(cnpg_primary)
counts_from "$OLD_POD" > "$BACKUP/counts-pre-v3-old.txt"
counts_from "$PRIMARY" > "$BACKUP/counts-pre-v3-cnpg.txt"
counts_cmp "$BACKUP/counts-before.txt" "$BACKUP/counts-pre-v3-old.txt" ||
  { echo "STOP: old database changed since the dump (writes after the dump would be lost); redo 3.1-3.3" >&2; exit 1; }
counts_cmp "$BACKUP/counts-before.txt" "$BACKUP/counts-pre-v3-cnpg.txt" ||
  { echo "STOP: CNPG database differs from the dump; reset (3.3) and restore again" >&2; exit 1; }
keys_unchanged
apply_site -target="$FZ_MODULE"
k -n "$NS" rollout status "deployment/$FZ" --timeout=300s
keys_unchanged
NEW_POD=$(fz_pod)
k -n "$NS" get pod "$NEW_POD" -o json | jq -e 'all(.spec.containers[]; .name != "postgres")' >/dev/null
counts_from "$PRIMARY" > "$BACKUP/counts-v3.txt"
counts_cmp "$BACKUP/counts-before.txt" "$BACKUP/counts-v3.txt"
echo APPLY2_OK
EOF
```

Expected side effects, not reasons to rotate keys:

- v3 destroys `random_bytes.database_password`. A rollback creates it again
  (see section 6).
- Helm's `stringData` removal leaves legacy `DATABASE_HOST/NAME/USER/PASSWORD`
  and `POSTGRES_*` keys in the live `<name>-env` Secret: empty after a direct
  v2→v3 upgrade, stale sidecar values (`127.0.0.1`, `postgres`, the old trust
  password) after a rollback→forward cycle. Explicit v3 container
  `env`/`secretKeyRef` entries override `envFrom` (verified: the v3 pod sees
  `DATABASE_HOST=postgres-rw`); these keys are harmless. Optional cleanup after
  verification (not needed for migration; block follows this list).

```bash
blk <<'EOF'
k -n "$NS" patch secret "$FZ-env" --type=merge -p \
  '{"data":{"DATABASE_HOST":null,"DATABASE_NAME":null,"DATABASE_USER":null,"DATABASE_PASSWORD":null,"POSTGRES_USER":null,"POSTGRES_DB":null,"POSTGRES_PASSWORD":null}}'
EOF
```

## 5. Verify before reopening admin writes

1. **Data proof first.** Both must hold: the section 4 count diff passed
   (`users` and `devices` equal), and the UI lists the pre-existing users and
   devices. On **OIDC sites the admin login proves little**: the OIDC sidecar
   resets the admin password on every start, so a working login does not show
   the database was restored. The user/device counts and the listed devices are
   the real proof there.
2. Sign out, then sign in with the **existing admin password** at the site's
   `https://hub.example.net` UI (substitute the FQDN). Do not reset the password
   to hide a failed login.
3. Use a **previously enrolled** client with its unchanged config. Generate
   traffic through the tunnel; on that client run `sudo wg show` and require a
   fresh handshake (under 180 seconds), RX/TX growth, and a successful request to
   a known site service. A new client alone does not prove encrypted device keys
   survived.
4. Drift gate and window end (block below).

```bash
blk <<'EOF'
out=$(mktemp -p "$BACKUP")   # plan output is secret
trap 'rm -f "$out"' EXIT
rc=0
plan_site -no-color -detailed-exitcode > "$out" 2>&1 || rc=$?
cat "$out"
lines=$(grep -aoEc 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy[.]' "$out" || true)
case $rc in
  0) (( lines == 0 )) || { echo "STOP: exit code 0 but the output has a Plan line" >&2; exit 1; }
     date -u +%FT%TZ > "$BACKUP/window-end"; echo "No drift" ;;
  2) echo "STOP: pending changes; review the plan, record window-end only after accepting them" >&2; exit 2 ;;
  *) exit "$rc" ;;
esac
EOF
```

With deliberately pending unrelated changes exit 2 is expected: keep edits
frozen, review and record that full plan (secrets, section 0), then record
`window-end` by hand. Do not claim no drift from a targeted plan. Record window
duration separately from client outage.

Only now reopen administrative writes. There is no database backup: until the next
Proxmox backup run of the data disk has finished the live volume and the off-node dump
of 3.1 are the only copies, and afterwards the newest run bounds the loss to the job
interval (the RPO, section 1.6 item 6). Start that run now: "Backup now" of the hub VM
in Proxmox in snapshot mode, then record its run ID (inspection list and marker in 7.1;
the PBS snapshot ID or the UPID of the task). A run recorded here satisfies the 7.1 gate
for as long as it is younger than one job interval. Encrypt the `$BACKUP` directory at
rest:

```bash
blk <<'EOF'
tar -C "$(dirname "$BACKUP")" -cf - "$(basename "$BACKUP")" | age -r "$AGE_RECIPIENT" > "$BACKUP.tar.age"
test -s "$BACKUP.tar.age"
EOF
```

Copy (upload) the `.tar.age` to the site's protected storage and **keep the local archive
until the proof block below passes** (it compares the stored copy against it). Download the
stored copy back to a path outside `$BACKUP` and prove it (the 7.1 gate requires this marker):

```bash
ARCHIVE_COPY='<path of the archive as downloaded back from protected storage>' blk <<'EOF'
archive_proven "$BACKUP.tar.age" "$ARCHIVE_COPY" "$BACKUP/archive-5-proven"
echo ARCHIVE_5_PROVEN
EOF
```

Only then remove plaintext copies that are not needed for rollback. The dump,
keys and counts contain credentials and customer data. Set a site-specific soak
deadline (at least 24 hours and one normal operator/client cycle) and an
explicit rollback-retention deadline before any deletion.

## 6. Rollback

Before reopening writes, rollback restores the v2 Firezone block from section 2
with the **original hostPath** and both pins `v2.0.1` / `2.0.1`; leave CNPG
installed. Remove v3-only inputs and the dependency; keep all application and
WireGuard keys. Gate (the plan output prints secrets, see section 0):

```bash
blk <<'EOF'
apply_init
plan_gate rollback 'Plan: 1 to add, 1 to change, 0 to destroy.' -target="$FZ_MODULE"
EOF
```

**STOP** unless exactly that: the add is `random_bytes.database_password`, the
change is the Firezone `helm_release` (`3.0.0` → `2.0.1`). Then:

```bash
blk <<'EOF'
apply_site -target="$FZ_MODULE"
k -n "$NS" rollout status "deployment/$FZ" --timeout=300s
OLD_POD=$(fz_pod)
k -n "$NS" get pod "$OLD_POD" -o json | jq -e 'any(.spec.containers[]; .name == "postgres")' >/dev/null
counts_from "$OLD_POD" > "$BACKUP/counts-rollback.txt"
counts_cmp "$BACKUP/counts-before.txt" "$BACKUP/counts-rollback.txt"
keys_unchanged
echo ROLLBACK_OK
EOF
```

Check existing-password login and the existing client's handshake as in
section 5. The `random_bytes.database_password` resource is re-created either
way (v2.0.1 always has it), but the Secret's `DATABASE_PASSWORD` only changes
when the site has **no** `databasePassword` in sops (rehearsal: it did change and
was harmless). A site whose sops `encryption_secrets` carries `databasePassword`
gets the unchanged value back. Either way the initialized hostPath database
accepts it or ignores it (loopback access works, checked in 1.3). The old
`postgres-data` was never mounted by v3.

After writes resume on v3, rollback loses **all** subsequent user/device/admin
changes as well as stats; freeze edits and obtain an explicit loss decision
first. This runbook does not merge diverging databases or reverse-copy CNPG into
the old data directory.

**Forward again:** repeat section 4–5; the guard at the top of the section 4
apply block re-counts **both** databases against `counts-before`. If either
differs (writes on v2 after rollback, or on v3 before it), do not proceed:
take a fresh dump of the old database (3.1), reset the CNPG database (3.3; its
guards hold because the rollback made v2 the running Firezone again, and it
discards the CNPG copy of any v3 writes, which the loss decision above already
gave up), restore (3.2) and then repeat sections 4–5. If v2 administrative writes occurred
that you cannot afford to lose, that fresh dump is mandatory.

## 7. Cleanup after soak (destructive; separate approval)

Resume rule: `export BACKUP=<the directory>; . "$BACKUP/env.sh"`. Every block
still runs through `blk`.

### 7.1 Old sidecar directory after a successful migration

Do not destroy CNPG on the migrated site. At the agreed retention deadline,
verify the v3 pod has no hostPath and **no pod in the cluster mounts the old
path** (or its parent/child). The path file contains the **postgres-data**
directory, not its parent. Inspect:

```bash
blk <<'EOF'
OLD_DATA=$(cat "$BACKUP/old-data-path")
[[ "$OLD_DATA" == /*/postgres-data && "$OLD_DATA" != *..* ]]
k get pods -A -o json | jq -e --arg p "$OLD_DATA" '[.items[].spec.volumes[]? | select(.hostPath != null) | .hostPath.path as $h | select($h == $p or ($p | startswith($h + "/")) or ($h | startswith($p + "/")))] | length == 0' >/dev/null
printf 'Old directory to review on the hub: %s\n' "$OLD_DATA"
hub sudo test -d "$OLD_DATA"
hub sudo du -sh -- "$OLD_DATA"
EOF
```

**Cleanup gate (in this session, before any deletion).** There is no database backup:
once the old directory is gone, the live CNPG volume and the proof below are all that
is left. First a **fresh dump of the live CNPG database**, kept off the node on the
controller, restored into a scratch database of the same cluster (read-only against
`firezone`; dropped afterwards) to prove that per-table counts of the dump equal the
live database (`connectivity_checks` may only have grown). The restore needs free
space for a second copy of the database (section 1.2). Record the printed sha256 in
the change record:

```bash
blk <<'EOF'
# A re-run needs its own archive of the new dump: drop the marker and the archive of the previous one
# (the stored copy of that archive downloaded earlier is not the proof for this dump either: delete it).
rm -f "$BACKUP/archive-live-proven" "$BACKUP/live-before-cleanup.tar.age"
PRIMARY=$(cnpg_primary)
counts_from "$PRIMARY" > "$BACKUP/counts-gate-before.txt"
kl -n "$NS" exec "$PRIMARY" -c postgres -- pg_dump -Fc -U postgres firezone > "$BACKUP/live-before-cleanup.dump.part"
test -s "$BACKUP/live-before-cleanup.dump.part"
mv "$BACKUP/live-before-cleanup.dump.part" "$BACKUP/live-before-cleanup.dump"
(cd "$BACKUP" && sha256sum live-before-cleanup.dump | tee live-before-cleanup.dump.sha256)
cleanup() { k -n "$NS" exec "$PRIMARY" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -c 'DROP DATABASE IF EXISTS dump_check WITH (FORCE)'; }
trap cleanup EXIT
cleanup
k -n "$NS" exec "$PRIMARY" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -c 'CREATE DATABASE dump_check'
kl -n "$NS" exec -i "$PRIMARY" -c postgres -- pg_restore --exit-on-error --single-transaction --no-owner --no-acl \
  -U postgres -d dump_check < "$BACKUP/live-before-cleanup.dump"
counts_from "$PRIMARY" dump_check > "$BACKUP/counts-gate-dump.txt"
counts_from "$PRIMARY" > "$BACKUP/counts-gate-after.txt"
if ! { counts_cmp "$BACKUP/counts-gate-before.txt" "$BACKUP/counts-gate-dump.txt" &&
       counts_cmp "$BACKUP/counts-gate-dump.txt" "$BACKUP/counts-gate-after.txt"; }; then
  echo "STOP: the dump differs from the live database; repeat in a quiet moment and investigate" >&2
  exit 1
fi
cat "$BACKUP/counts-gate-dump.txt"
cleanup
trap - EXIT
[[ "$(k -n "$NS" exec "$PRIMARY" -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -Atc "SELECT count(*) FROM pg_database WHERE datname = 'dump_check'")" == 0 ]]
date -u +%FT%TZ > "$BACKUP/dump-verified"
echo DUMP_VERIFIED
EOF
```

The live dump is a second copy of customer data on the controller: archive it with age,
store it, and prove the stored copy before the gate (the section 5 archive was made before
this dump and does not contain it). The plaintext dumps are shredded after the deletion:

```bash
blk <<'EOF'
cd "$BACKUP"
tar -cf - live-before-cleanup.dump live-before-cleanup.dump.sha256 | age -r "$AGE_RECIPIENT" > live-before-cleanup.tar.age
test -s live-before-cleanup.tar.age
echo DUMP_ARCHIVED
EOF
```

Copy (upload) `live-before-cleanup.tar.age` to the site's protected storage and keep the local
archive until the proof block passes; download the stored copy back to a path outside
`$BACKUP` and prove it (this writes the marker the gate requires; the section 5 archive needs
its own marker, written by the block there):

```bash
ARCHIVE_COPY='<path of the live-dump archive as downloaded back from protected storage>' blk <<'EOF'
archive_proven "$BACKUP/live-before-cleanup.tar.age" "$ARCHIVE_COPY" "$BACKUP/archive-live-proven"
echo ARCHIVE_LIVE_PROVEN
EOF
```

Then the two confirmations only a human can make. **Proxmox.** Inspect the newest backup run
of the hub VM and record its run ID, never a hand-typed local time. Two forms are accepted,
and the gate derives the start time from the ID (`backup_run_epoch` matches the **whole** ID):

- **PBS snapshot ID** `vm/<vmid>/<UTC>Z`. The Backup tab of the PVE storage shows it as the volume ID
  `<storage>:backup/vm/<vmid>/<UTC>Z`: strip the `<storage>:backup/` prefix, and a namespace
  prefix `ns/<ns>/` if the datastore uses namespaces (the gate refuses anything else). On the PBS
  itself `proxmox-backup-client snapshot list "vm/<vmid>" [--ns <ns>]` prints it.
- **UPID of the vzdump task** (Tasks), whose fifth colon-separated field is the start time in hex
  epoch and whose sixth/seventh fields are `vzdump` and the VM id. A job that covers **several
  guests** has an **empty ID field** (`...:vzdump::root@pam:`) and is refused: on PBS use the
  snapshot ID instead; on file storage start "Backup now" of the hub VM **alone** and record the UPID
  of that task.

Before recording, check all of:

- VM **Hardware**: `virtio1` (serial `garuda-data`) has backup enabled and `scsi0` has
  `backup=no`, so the run contains the data disk only;
- the **task log** of the run: status `OK`, a line `include disk 'virtio1'`, and the
  guest-agent `fs-freeze` / `fs-thaw` (a missing freeze means a crash-consistent image
  of an unfrozen filesystem: still recoverable, but say so in the change record);
- on PBS: **File Restore** of `drive-virtio1.img` lists
  `k3s-storage/pvc-<uid>_garuda_postgres-1/pgdata/PG_VERSION` (the CNPG volume exists once
  Apply #1b has run and a run followed it; before that, section 1.6 item 7 proves the old
  directory the same way).

The run must be the **newest** one, newer than `window-end` and **younger than one job
interval** (`BACKUP_INTERVAL_S`) at the time the gate runs; otherwise wait for the next run
and record that one. **Monitoring.** Confirm that the scheduled disk-usage and
backup-freshness checks of section 8 exist and alert a human, and record that:

```bash
printf '%s\n' '<PBS snapshot ID vm/<vmid>/<UTC>Z, or the vzdump UPID, of the newest OK run>' > "$BACKUP/proxmox-backup-confirmed"
date -u +%FT%TZ > "$BACKUP/monitoring-confirmed"
```

(Run those two lines yourself in the operator shell; they are not a `blk` block on purpose.
The gate refuses to run without either marker, because without them the volume is a single
copy nobody would notice losing.) The gate then checks that the CNPG volume is under
`STORAGE_PATH` **on the data disk** with its database files, and repeats the dump, archive,
Proxmox and monitoring guards:

```bash
blk <<'EOF'
cleanup_gate
echo CLEANUP_GATE_OK
EOF
```

Delete only after the separate approval. The guards repeat right before the deletion
(the dump marker must be less than a day old, otherwise run the dump block again, which
also requires a new stored archive). The plaintext dumps are shredded afterwards: the two
archives are the copies, and `shred` is best effort on journaling and copy-on-write
filesystems, so keep `$BACKUP` on an encrypted volume:

```bash
blk <<'EOF'
cleanup_gate
OLD_DATA=$(cat "$BACKUP/old-data-path")
[[ "$OLD_DATA" == /*/postgres-data && "$OLD_DATA" != *..* ]]
k get pods -A -o json | jq -e --arg p "$OLD_DATA" '[.items[].spec.volumes[]? | select(.hostPath != null) | .hostPath.path as $h | select($h == $p or ($p | startswith($h + "/")) or ($h | startswith($p + "/")))] | length == 0' >/dev/null
hub sudo rm -rf -- "$OLD_DATA"
for f in "$BACKUP/firezone.dump" "$BACKUP/live-before-cleanup.dump"; do
  [[ ! -e $f ]] || shred -u -- "$f"   # a missing file (shredded by an earlier run) must not fail the block
done
EOF
```

Never remove `$STORAGE_PATH` itself, the k3s data directory or the Firezone parent directory.
Deleting the old directory ends this hostPath rollback path. Keep the two stored age
archives (section 5 and the live dump) according to the site's retention policy: with no
database backup they are the only recovery material besides the Proxmox backup of the
data disk.

### 7.2 Deliberately retire a CNPG database (not routine migration cleanup)

Keep the operator running. **Do not use `destroy -target` while Firezone depends
on the database module:** targeted destroy includes dependent resources and can
uninstall Firezone too. Order matters: disconnect Firezone **first**, then dump.

```bash
blk <<'EOF'
k -n "$NS" scale "deployment/$FZ" --replicas=0
k -n "$NS" wait pod -l "app.kubernetes.io/name=firezone,app.kubernetes.io/instance=$FZ" --for=delete --timeout=120s
PRIMARY=$(cnpg_primary)
kl -n "$NS" exec "$PRIMARY" -c postgres -- pg_dump -Fc -U postgres firezone > "$BACKUP/before-retirement.dump.part"
test -s "$BACKUP/before-retirement.dump.part"
mv "$BACKUP/before-retirement.dump.part" "$BACKUP/before-retirement.dump"
(cd "$BACKUP" && sha256sum before-retirement.dump > before-retirement.dump.sha256)
kl -n "$NS" exec -i "$PRIMARY" -c postgres -- pg_restore --list < "$BACKUP/before-retirement.dump" > "$BACKUP/before-retirement.list"
counts_from "$PRIMARY" > "$BACKUP/counts-before-retirement.txt"
cat "$BACKUP/counts-before-retirement.txt"
EOF
```

(Helm does not notice the manual scale. To bring the site back later, restore
the dump into a freshly created Cluster after `sha256sum -c`, then scale to 1.)
Disconnect every other consumer of the database too. This retirement path was
rehearsed in an earlier revision (also without backups); only its volume path
(`$STORAGE_PATH`) and its file-descriptor loops changed since, and it was not re-run in
this one: run it once on the stand before the first use on a production site.

Remove **only the database module** from configuration: replace Firezone's
`database_secret_name = module.firezone_db.secret_name` with the literal
`database_secret_name = "postgres-app"`, remove `module.firezone_db` from its
`depends_on`, remove the `module "firezone_db"` block and any other reference to
it (keep the operator and storage class). Gate, then a **normal** targeted apply:

```bash
blk <<'EOF'
apply_init
plan_gate retire 'Plan: 0 to add, 0 to change, 1 to destroy.' -target="$DB_MODULE"
EOF
```

**STOP** unless exactly that line and the one destruction is the database Helm
release (no Firezone, no operator).

```bash
blk <<'EOF'
apply_site -target="$DB_MODULE"
k -n "$NS" get cluster postgres
k -n "$NS" get pvc -l cnpg.io/cluster=postgres
[[ "$(k -n "$NS" get pvc -l cnpg.io/cluster=postgres -o json | jq '[.items[] | select(.status.phase == "Bound")] | length')" -ge 1 ]]
EOF
```

The Cluster and Bound PVCs **must survive** Helm uninstall because of `keep`;
the PV is still Bound, not Released. If they do not survive, stop and
investigate. Reinstalling a kept Cluster may require Helm ownership
reconciliation; do not create a second empty database over it.

Record each volume's node and hostPath **before** deleting the Cluster
(non-destructive). The loops read the list on file descriptor 3: every `k`/`hub`
call is an `ssh`, which would otherwise swallow the rest of the list from stdin.

```bash
blk <<'EOF'
k -n "$NS" get pvc -l cnpg.io/cluster=postgres -o json > "$BACKUP/cnpg-pvcs.json"
jq -er '.items[].spec.volumeName' "$BACKUP/cnpg-pvcs.json" > "$BACKUP/cnpg-pv-names"
while IFS= read -r -u 3 pv; do
  k get pv "$pv" -o json > "$BACKUP/$pv.json"
  jq -e '.spec.persistentVolumeReclaimPolicy == "Retain"' "$BACKUP/$pv.json" >/dev/null
  jq '{name:.metadata.name,nodeAffinity:.spec.nodeAffinity,path:.spec.hostPath.path}' "$BACKUP/$pv.json"
done 3< "$BACKUP/cnpg-pv-names"
EOF
```

Delete the Cluster (after approval); the PVs must end up `Released`:

```bash
blk <<'EOF'
k -n "$NS" delete cluster postgres --wait=true --timeout=300s
k -n "$NS" wait pvc -l cnpg.io/cluster=postgres --for=delete --timeout=300s
while IFS= read -r -u 3 pv; do
  k get pv "$pv" -o json | jq -e '.status.phase == "Released"' >/dev/null
done 3< "$BACKUP/cnpg-pv-names"
EOF
```

If the PVCs remain, inspect finalizers/ownerReferences; do not remove protection
finalizers blindly. Retain leaves each PV **Released** and its node directory
intact. Inspect each directory (non-destructive); the checks refuse a volume
assigned to another node, a non-Retain/Released PV, or a path outside the k3s
local-path base directory (`$STORAGE_PATH`):

```bash
blk <<'EOF'
while IFS= read -r -u 3 pv; do
  k get pv "$pv" -o json | jq -e '.status.phase == "Released" and .spec.persistentVolumeReclaimPolicy == "Retain"' >/dev/null
  path=$(jq -er '.spec.hostPath.path' "$BACKUP/$pv.json")
  node=$(jq -er '.spec.nodeAffinity.required.nodeSelectorTerms[].matchExpressions[] | select(.key == "kubernetes.io/hostname") | .values[]' "$BACKUP/$pv.json")
  [[ "$node" == "$(hub hostname)" ]]
  [[ "$path" == "$STORAGE_PATH"/* && "$path" != *..* ]]
  hub sudo test -d "$path"
  hub sudo du -sh -- "$path"
done 3< "$BACKUP/cnpg-pv-names"
EOF
```

Only after the separate deletion approval, remove **each volume's directory and
PV**, never a glob or the storage root:

```bash
blk <<'EOF'
while IFS= read -r -u 3 pv; do
  k get pv "$pv" -o json | jq -e '.status.phase == "Released" and .spec.persistentVolumeReclaimPolicy == "Retain"' >/dev/null
  path=$(jq -er '.spec.hostPath.path' "$BACKUP/$pv.json")
  node=$(jq -er '.spec.nodeAffinity.required.nodeSelectorTerms[].matchExpressions[] | select(.key == "kubernetes.io/hostname") | .values[]' "$BACKUP/$pv.json")
  [[ "$node" == "$(hub hostname)" ]]
  [[ "$path" == "$STORAGE_PATH"/* && "$path" != *..* ]]
  hub sudo rm -rf -- "$path"
  k delete pv "$pv" --wait=true --timeout=60s
done 3< "$BACKUP/cnpg-pv-names"
EOF
```

Uninstall the operator only after all intended Clusters have been retired.

## 8. Monitoring the disks and the backup (permanent)

With no database backup the volume is the data, and a full disk is the failure that
can be seen coming: the data disk holds the database (it only grows), the root disk
holds the k3s datastore and the images (a full root disk makes kubelet evict pods).
By hand, after every apply and at least daily from the operator machine:

```bash
blk <<'EOF'
for path in "$STORAGE_PATH" /; do
  used_pct=$(hub_used_pct "$path")
  printf '%s: %s%% used\n' "$path" "$used_pct"
  (( used_pct < 80 ))
done
echo DISKS_HEALTHY
EOF
```

Both filesystems must be below 80 %. The protection of the data itself is the Proxmox
backup job of the data disk. A failed run alerts a human on the Proxmox side (section 1.6,
item 5), but a job that silently stops (disabled, storage unreachable, VM dropped from the
selection) alerts nobody, so a **freshness check** also runs on a schedule from a host
that is not the hub (the hub is the VM it protects), alerting a human (non-zero exit =
alert, via the site's cron/timer mail or monitoring) when the newest backup of the hub VM
is older than the job interval plus slack. It asks the PVE storage content API or, on PBS,
the PBS snapshot list; keep one branch:

```bash
#!/usr/bin/env bash
# Scheduled backup-freshness check for the hub VM (cron or a systemd timer on a monitoring host).
set -euo pipefail
SOURCE='<pve or pbs>'
HUB_VMID='<hub VM id, digits>'
BACKUP_INTERVAL_S='<backup job interval in seconds>'
SLACK_S='<slack in seconds, e.g. the longest normal run time>'
PVE_NODE='<node>' PVE_STORAGE='<storage id>'          # SOURCE=pve: run as root on a PVE node (pvesh is local-only)
PBS_REPOSITORY='<user@realm!token@host:datastore>'    # SOURCE=pbs: the token secret is in PBS_PASSWORD (or PBS_PASSWORD_FILE)
PBS_NS='<namespace, e.g. a/b, or empty for the root namespace>'
export PBS_FINGERPRINT='<server certificate fingerprint>'   # SOURCE=pbs: pins the certificate of a PBS with a self-signed one

case $SOURCE in
  pve) newest=$(pvesh get "/nodes/$PVE_NODE/storage/$PVE_STORAGE/content" --content backup --vmid "$HUB_VMID" \
         --output-format json | jq -er 'max_by(.ctime) | .ctime') ;;
  pbs) snap=$(proxmox-backup-client snapshot list "vm/$HUB_VMID" --repository "$PBS_REPOSITORY" \
         ${PBS_NS:+--ns "$PBS_NS"} --output-format json | jq -ec 'max_by(."backup-time")')
       newest=$(jq -er '."backup-time"' <<< "$snap")
       # the newest snapshot must contain the data disk image, not only the VM config
       jq -e '[.files[] | (.filename? // .)] | index("drive-virtio1.img.fidx")' <<< "$snap" > /dev/null ||
         { echo "ALERT: the newest snapshot of the hub VM has no drive-virtio1.img.fidx" >&2; exit 1; } ;;
  *) echo "STOP: set SOURCE to pve or pbs" >&2; exit 2 ;;
esac
age_s=$(( $(date +%s) - newest ))
printf 'newest backup of VM %s is %s s old (limit %s s)\n' "$HUB_VMID" "$age_s" "$(( BACKUP_INTERVAL_S + SLACK_S ))"
(( age_s <= BACKUP_INTERVAL_S + SLACK_S )) || { echo "ALERT: the newest backup of the hub VM is too old" >&2; exit 1; }
```

The script is **unrehearsed against a real Proxmox** (the stand has none; it is only `bash -n` and
shellcheck clean and was run against stubbed `pvesh` / `proxmox-backup-client`, so the JSON shapes it reads
(`ctime`, `backup-time`, `files[].filename`) are those documented for the PVE and PBS APIs, not observed
here): run it once on the real monitoring host with a tiny limit and read its output before relying on it.

The migration is not finished until both checks run on a schedule and alert a human; the
`monitoring-confirmed` marker of 7.1 attests the disk-usage **and** the freshness check
(an alert that was seen to fire once, for example by running the freshness check with a
tiny limit).

## 9. After a hub rebuild or a lost data disk

The Proxmox backup of the data disk is the only copy of the database, so what survives
depends on how the data disk is owned. On the production hub it is an inline disk of the
hub VM resource in Terraform (`infra/proxmox.tf`: `virtio1`, serial `garuda-data`,
`backup = true`; the root disk `scsi0` has `backup = false`; `scripts/hub-data-disk.sh`
mounts the disk by its label `garuda-data` at `/opt/garuda` and never formats a disk that
already carries that label). Consequences, for the v3 CNPG volume and equally for the v2
hostPath directory today:

- **Destroying or rebuilding the VM resource through Terraform destroys the data disk and
  the volume directory with it** (`delete_unreferenced_disks_on_destroy` of the provider is on by
  default). Only the VM's `protection` flag blocks that (production sets `protection: true`,
  `inputs.tfvars.yaml`, applied by `infra/proxmox.tf`). The `Retain` class does not help: it
  keeps the directory when the Cluster, PVC or namespace go, not when the disk goes.
- The hub VM resource has no fixed `vm_id`: a rebuilt VM gets a **new VMID**, and the provider's
  `purge_on_destroy` (default on) removes the old VMID from the backup jobs. Nothing backs the new VM up
  until step 5 below.
- A rebuild therefore starts with **keeping or restoring the data disk from Proxmox**, and only then
  re-attaches the database. The k3s datastore (PV, PVC and Cluster objects) on the root disk
  is gone in every rebuild.
- **The `protection` flag also blocks the recovery itself**: qemu-server refuses `qm set --delete
  virtio1`, removing the unused disk and `qm disk move` out of a protected VM, and a VM restored from
  the backup of a protected VM is protected too (`qm.1`: "This will disable the remove VM and remove
  disk operations"). The steps below lift it **per VM, only for those commands, and set it back at once**
  (`qm set <vmid> --protection 0|1`). Never lift it while a Terraform plan that replaces or destroys the hub
  is pending: with the flag off, an apply is what destroys the disk. The one exception is the deliberate
  destruction of the old, already disk-less VM in step 0, after its plan was reviewed.

Both procedures below are **site-specific and unrehearsed**: the Proxmox and Terraform steps
were not run anywhere (the stand has no Proxmox), only the final re-attach was, on the stand
(see the rehearsal record). The `qm`, `qmrestore` and PBS commands were checked against the Proxmox
VE documentation (`qm.1`, `qmrestore.1`) and the Proxmox Backup client documentation, not run. Read them
before the window, not after a loss. `<hub vmid>`, `<old vmid>` and `<spare vmid>` are the VM ids of the
rebuilt hub, the previous hub and the spare VM that temporarily holds the data disk; `<disk volid>` is the
volume ID that `qm config` prints for it.

**Rebuild (VM and k3s gone or to be replaced).**

0. **If the old hub VM still exists, do not restore a backup and do not apply yet: its live
   `virtio1` is newer than any backup, and the apply destroys it.** Shut it down
   (`qm shutdown <old vmid>`: a clean guest shutdown flushes the database), lift its protection
   (`qm set <old vmid> --protection 0`), create an empty spare VM (`qm create <spare vmid> --name
   hub-data-spare`) and **move the live disk out** of the VM that will be destroyed:
   `qm disk move <old vmid> virtio1 --target-vmid <spare vmid> --target-disk virtio1`. Check
   `qm config <spare vmid>` shows `virtio1`, then set `qm set <old vmid> --protection 1` again. (The
   alternative, "Backup now" of the **stopped** VM and a restore of that backup as in step 1, leaves the
   live disk in the VM that the apply destroys, so a mistake there loses the newest data: prefer the move.)
   The apply that replaces the now disk-less old VM needs its protection off: lift it only after that
   plan has been reviewed and the move verified, immediately before the apply; the new VM comes up
   protected from the configuration. With the disk moved, skip step 1: the spare already holds the newest data.
1. Only if no old VM exists (or its disk could not be moved — then the old VM stays protected and
   **no apply runs** until a "Backup now" of the stopped old VM has completed and that backup is the one
   restored here): in Proxmox restore the newest
   backup of the hub VM to a **spare VMID**, without starting it and with a fresh MAC (the
   restored config copies the NIC and the cloud-init address of the hub):
   `qmrestore <backup volid> <spare vmid> --unique 1` (PBS: `<pbs storage>:backup/vm/<old vmid>/<UTC>Z`; `--start`
   defaults to off). It contains the data disk only (`scsi0` has `backup=0`). Keep the spare stopped.
2. Apply the rebuild through Terraform **only as far as the VM** (`-target` its address, in
   production `proxmox_virtual_environment_vm.hub`): the later resources must wait until the data disk is
   the restored one. `terraform_data.hub_data_disk` (`infra/k3s.tf`) formats a **blank** `virtio1` over SSH
   (`scripts/hub-data-disk.sh`; it refuses a disk with another filesystem and accepts the label
   `garuda-data` as it is) and `module.k3s` depends on it. Then swap the disks: shut the new VM down
   (`qm shutdown <hub vmid>`), lift the protection of **both** VMs, drop the blank disk, move the restored one in
   under the same key, set the serial the guest paths expect, protect the hub VM again, start it:
   ```text
   qm set <hub vmid> --protection 0
   qm set <spare vmid> --protection 0
   qm set <hub vmid> --delete virtio1            # detaches the blank disk: it becomes unused0
   qm disk unlink <hub vmid> --idlist unused0    # removes it (qm config first: unused<n> is the blank disk)
   qm disk move <spare vmid> virtio1 --target-vmid <hub vmid> --target-disk virtio1
   qm set <hub vmid> --virtio1 <disk volid>,serial=garuda-data,backup=1,discard=on,iothread=1
   qm config <hub vmid>                          # virtio1 = the restored volume, serial garuda-data
   qm set <hub vmid> --protection 1
   qm start <hub vmid>
   ```
   The restored filesystem carries the label `garuda-data`, so the infra apply of step 3 mounts it without
   formatting it. Keep the (now disk-less) spare VM until step 4 has passed, then remove it
   (`qm config <spare vmid>` must list no `virtio*`, `scsi*` or `unused*` disk — otherwise the move did
   not complete and destroying it deletes data; only then `qm set <spare vmid> --protection 0` if it is
   protected and `qm destroy <spare vmid>`).
3. Reconcile Terraform: `tofu plan` of the infra unit must show **no replacement of the VM or its
   disk** (refresh or adjust the state; never accept a plan that replaces the disk, and never
   apply a plan that destroys the VM while its protection is off), then run the rest of the infra
   apply (`terraform_data.hub_data_disk` mounts the restored disk, then k3s).
4. Re-attach the database: section 9.1 below. It needs the application keys
   (section 1.4) and does not use the old `postgres-data` or the dump of 3.1. It covers both the
   case where the app has not been applied yet and the case where Firezone already runs on a new
   empty Cluster.
5. **Put the rebuilt VM back under backup.** If the VMID changed: confirm in Proxmox that the new VM is
   selected by the backup job (the old VMID was removed from it; a job that selects VMs by id needs the new id
   added, one that selects a pool or all VMs may already have it); record the new id in `$BACKUP/env.sh`
   (later definitions win; the freshness check of section 8 has its own `HUB_VMID`, update it too); run
   "Backup now" of the hub VM and record that run as in 7.1. Until it has finished the live volume is the
   only copy:

```bash
NEW_HUB_VMID='<new hub VM id, digits>' blk <<'EOF'
[[ $NEW_HUB_VMID =~ ^[0-9]+$ ]]
printf 'HUB_VMID=%s\n' "$NEW_HUB_VMID" >> "$BACKUP/env.sh"
. "$BACKUP/env.sh"
printf 'HUB_VMID is now %s\n' "$HUB_VMID"
EOF
```

**In place (VM and k3s survive, the data disk is lost or damaged).** Shut the **VM** down
(`qm shutdown <hub vmid>`): stopping only k3s (`systemctl stop k3s`) leaves the pods and their
processes running on the damaged disk (k3s documents that its service stop does not stop the pods).
Restore the newest backup to a spare VMID with the `qmrestore` command of step 1 above, lift the protection of both VMs, detach the
bad disk (`qm set <hub vmid> --delete virtio1`: it stays as `unused<n>`, keep it until the restored data has
been verified, then remove it with `qm disk unlink <hub vmid> --idlist unused<n>`), move the
restored disk in as `virtio1` and set the serial exactly as in step 2, protect the hub VM again
(`qm set <hub vmid> --protection 1`) and start it. The Cluster, PVC and PV objects still point at the same
volume path, so CNPG starts the instance on the restored directory and PostgreSQL replays its WAL by
itself: no dump is needed. Reconcile Terraform as in step 3 (the plan must not replace the VM or its disk;
refresh or adjust the state, never accept a plan that replaces the disk). Verify as in section 5 (Cluster
Ready, per-table counts plausible, existing admin password, enrolled client handshake). If the restored
directory is unusable, fall back to the rebuild procedure from its step 4. Remove the spare VM afterwards
exactly as at the end of step 2 (`qm config` shows no disk first).

The crash-consistent image is as recent as the last backup run: everything written since
is lost (the RPO of section 1.6 item 6).

### 9.1 Re-attach the old volume after a VM rebuild

Rehearsed on the local stand on 2026-11-10 with the module code of `a8c3806f` (a
running Cluster with seeded users and devices and an enrolled client): the volume
directory was copied while the Cluster ran, under an `fsfreeze` of its filesystem, so the
copy is crash-consistent (the temporary Postgres below logs "not properly shut down" and
replays WAL); the app and database releases were uninstalled and the Cluster, PVC and PV
deleted, the copy was put back as the old directory, and both cases of step 2 were followed
verbatim. Per-table counts were identical, the admin signed in with the existing password
and the enrolled client handshook again. It restores from the old data directory by a dump
into a fresh Cluster, the simplest path to reason about. Adopting the old PVC directly
(CNPG's detached-PVC / hibernation flow) was not evaluated.

1. Precondition: the data disk is mounted at the same base directory (`<base>`) and holds
   the old volume directory `<base>/pvc-<uid>_<ns>_<name>-1` with `pgdata/PG_VERSION` at
   the major version of the module's `image`. The temporary Postgres below **modifies**
   that directory (crash recovery): work on a snapshot or on a copy of a directory no
   Postgres was writing, and keep the original until the end of step 5.
2. A new, empty Cluster `<name>` must exist and be Ready, and nothing may use its database.
   Depending on how far the rebuilt site got:
   - **No app yet** (the first apply on the rebuilt hub has not run): `tofu apply
     -target=module.<this module>` (it pulls in the operator and the StorageClass). The old
     Cluster object is gone with the datastore, so this creates the empty Cluster with a
     new `pvc-<new uid>_...` directory.
   - **The app already runs on the new empty Cluster** (a full apply ran): stop the app
     first (Helm does not notice a scale), then discard what it wrote since, which is its
     first-boot data and anything enrolled after it:

         kubectl -n <ns> scale deployment/<app> --replicas=0
         kubectl -n <ns> wait pod -l app.kubernetes.io/name=<app> --for=delete --timeout=120s
         kubectl -n <ns> exec <name>-1 -c postgres -- psql -v ON_ERROR_STOP=1 -U postgres -d <database> \
           -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION <owner>;'

   Then, in both cases:

       kubectl -n <ns> wait --for=condition=Ready cluster/<name> --timeout=300s
       kubectl -n <ns> exec <name>-1 -c postgres -- psql -v ON_ERROR_STOP=1 -U postgres -d <database> -Atc \
         "SELECT count(*) FILTER (WHERE schemaname = 'public') || '/' || (SELECT count(*) FROM pg_stat_activity WHERE datname = '<database>' AND pid <> pg_backend_pid()) FROM pg_tables"

   must print `0/0` (no table, no connection) before you go on.
3. Start a temporary Postgres on the old directory, node-local, no network (the CNPG
   image runs as uid 26; take the image from the module's `image`; the settings
   overridden on the command line come from CNPG's generated config in `pgdata/`, whose
   `log_directory` points into `/controller` and so needs the logging collector off; if
   it still fails to start, read `kubectl -n <ns> logs old-db` and override the named
   setting the same way). Save the pod manifest as `old-db.yaml` and apply it:

       apiVersion: v1
       kind: Pod
       metadata: {name: old-db, namespace: <ns>}
       spec:
         nodeName: <the hub node>
         restartPolicy: Never
         securityContext: {runAsUser: 26, runAsGroup: 26}
         containers:
           - name: postgres
             image: <the module image>
             command: [postgres]
             args: [-D, /old/pgdata, -c, listen_addresses=, -c, unix_socket_directories=/tmp,
                    -c, ssl=off, -c, archive_mode=off, -c, shared_preload_libraries=,
                    -c, logging_collector=off, -c, log_destination=stderr]
             volumeMounts: [{name: old, mountPath: /old}]
         volumes:
           - name: old
             hostPath: {path: <base>/pvc-<uid>_<ns>_<name>-1, type: Directory}

   Apply and wait for crash recovery to finish (`pg_isready` answers on the socket):

       kubectl apply -f old-db.yaml
       kubectl -n <ns> wait --for=condition=Ready pod/old-db --timeout=300s
       kubectl -n <ns> exec old-db -- pg_isready -h /tmp

4. Move the data atomically into the empty database: `pg_dump` over the socket on the old
   side (peer authentication as `postgres`), one transaction and the first error aborts on
   the new side, no `--clean`; objects end up owned by `<owner>`:

       kubectl -n <ns> exec old-db -- pg_dump -h /tmp -Fc -d <database> > <database>.dump
       test -s <database>.dump
       kubectl -n <ns> exec -i <name>-1 -c postgres -- \
         pg_restore --exit-on-error --single-transaction --no-owner --no-acl --role=<owner> \
         -U postgres -d <database> < <database>.dump

   Compare the exact per-table row counts of schema `public` on both sides; they must be
   identical (`counts.sql` lists them):

       cat > counts.sql <<'SQL'
       SELECT format('SELECT %L, count(*) FROM %I.%I;', tablename, schemaname, tablename)
       FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename
       \gexec
       SQL
       kubectl -n <ns> exec -i old-db -- psql -h /tmp -X -qAt -d <database> < counts.sql > counts-old.txt
       kubectl -n <ns> exec -i <name>-1 -c postgres -- psql -X -qAt -d <database> < counts.sql > counts-new.txt
       diff counts-old.txt counts-new.txt

   Also compare them with the counts you recorded before the loss, if you have any (the
   crash-consistent image is as recent as the last backup run, not as the loss). The dump
   holds the whole database (Firezone's users and devices): keep it off shared locations
   and delete it afterwards.
5. `kubectl -n <ns> delete pod old-db`, then bring the app up: a full `tofu apply` (no app
   yet), or `kubectl -n <ns> scale deployment/<app> --replicas=1` (it ran before). Check as
   in section 5: the Deployment references `<name>-app`, the pod is Ready,
   the admin signs in with the existing password, users and devices are listed, and an
   enrolled client handshakes with its unchanged config. The application's own secrets
   (Firezone encryption keys and WireGuard key) come from the site configuration and must be
   the old ones. Remove the old `pvc-<uid>_...` directory only after that.

## Rehearsal record (local stand)

Rehearsed on the local stand on 2026-11-10 (fourth revision of this runbook, the
no-backups design; the fifth revision, the review fixes and the re-attach rehearsal below, did
not re-run these blocks): every block of this file extracted and run as written in a fresh
`bash` without `set -e` (the stand mapping below applies; see "Not run as written").
Start state: garuda-internal `cea243ef` (Firezone v2.0.1, k3s-bootstrap v0.3.2, no CNPG)
after a clean `./stand reset && ./stand up` (first attempt), with 3 users/3 devices,
single hub, kernel 7.0.0-43, an enrolled client probed through the tunnel every ~2 s.
The Apply #1 and Apply #2 trees are garuda-internal commit `a8c3806f` (branch
`feat/firezone-cnpg`), with the v2 Firezone block restored for Apply #1/rollback and the
throwaway key override. The published release is `906bcc06`; the module paths compared against it
are `modules/cnpg_operator` and `modules/cnpg_database`. Module delta since the rehearsed
`b12124c4`: unused backup and generation code and outputs removed; rendered values of the
database release unchanged (tftest `rendered_values_are_exactly_the_plain_initdb_cluster`);
gate lines unchanged (1a `2/0/0`, 1b `1/0/0`). Durations depend on
image pulls and database size; the hub is small (2 vCPU, 4 GiB) and the stand host is
CPU-starved, so treat them as a floor.

| Step | Result |
|------|--------|
| 1.2 capacity block | `CAPACITY_OK` (database 9 MB, 11.6 GiB free) |
| 1.2 infra gate and apply | `Plan: 1 to add, 0 to change, 1 to destroy.`, the changed address is exactly the hub's `terraform_data.converge` (stand: `module.node["hub"]...`); saved plan applied in ~3.7 min, k3s restarted by the plan, `NRestarts` 0 -> 0; **no probe failure** |
| 1.2 throwaway `local-path` claim | **First run failed**: the claim's volume landed under the old `/var/lib/rancher/k3s/storage`, because the provisioner reads the new ConfigMap only after kubelet syncs its mounted file, minutes after the apply. Fixed by restarting the provisioner in the apply block. The infra change was then reverted ad hoc (not a runbook block) and the gate, apply and claim blocks re-run as written: `LOCAL_PATH_OK`, volume under `/opt/garuda/k3s-storage`, removed afterwards |
| Pre-pull (2 images: PostgreSQL by digest, operator 1.30.1) | the `headroom` block STOPped for about 25 min on the 5-minute load (4.4, decaying to 1.0 after the two k3s restarts; the threshold was not relaxed); then passes in 35 s, root disk 37 % -> 43 % (11 GiB free). The stand hub's disk had been grown to 20 GiB (see the mapping); on its original 8.6 GiB the pull evicts pods (an earlier rehearsal: client outage 349 s, hence the absolute `ROOT_FREE_MIN_GIB` floor) |
| Apply #1a (operator + Retain class) | gate `Plan: 2 to add, 0 to change, 0 to destroy.`; ~50 s; k3s restart counter 0 -> 0; no probe failure |
| Apply #1b (empty database) | gate `Plan: 1 to add, 0 to change, 0 to destroy.` (the database Helm release); ~63 s; Cluster Ready, volume under `/opt/garuda/k3s-storage`, every running image was pre-pulled and `PG_IMAGE` is the Cluster's image; k3s restart counter 0 -> 0; no probe failure |
| Dump / restore | 27 KiB dump, ~4 s each; all 9 `public` table counts identical |
| 3.3 reset, then 3.1-3.2 repeated | reset guards pass, 0 tables, second restore counts identical |
| Apply #2 (v3) | gate `0 to add, 1 to change, 1 to destroy`; counts identical, keys byte-identical, existing-password login and client handshake OK; **31.5 s** outage (17.5 s in the previous rehearsal) |
| Drift gate (exit-code plus Plan-line check), `$BACKUP` age archive | `No drift`; archive written |
| Rollback to v2.0.1 | gate `1 to add, 1 to change, 0 to destroy`; old hostPath counts and keys identical, login + client OK; **17.4 s** outage |
| Forward again (no re-restore) | same plan as Apply #2, counts identical, login + client OK; **16.7 s** outage |
| 7.1 old directory (64 MiB) inspect | no pod mounts it |
| 7.1 dump block | fresh `pg_dump -Fc` of the live database (sha256 recorded), restored into the scratch database `dump_check`: per-table counts equal to the live database (api_tokens 0, configurations 1, connectivity_checks 0, devices 3, mfa_methods 0, oidc_connections 0, rules 0, schema_migrations 57, users 3); scratch database dropped |
| 7.1 cleanup gate | refused without the Proxmox marker, then without the monitoring marker, then with a Proxmox marker older than `window-end`; passes with both markers (volume under `/opt/garuda/k3s-storage`, `pgdata/PG_VERSION` present) |
| 7.1 old directory removal | guards pass, `postgres-data` removed, `/opt/garuda/firezone` empty, `$STORAGE_PATH` holds only the CNPG volume |
| Section 8 check | `DISKS_HEALTHY` (both paths 44 % - one filesystem on the stand, `DATA_MOUNT=/`) |

Outage is the interval between the last successful and the first successful probe
of one client request through the tunnel (every ~2 s, so an upper bound); the
operator-visible window (Apply #2 until verification) is longer. Over the whole
rehearsal (1638 probes) the only failed probes were the three outages above (Apply #2,
rollback, forward again). The three planned k3s restarts of the infra applies (two as
written, one revert), Apply #1a/#1b, the dump/restore and the 7.1 gate caused none, and
`NRestarts` (automatic restarts) stayed 0.
No plan gate was run through Terragrunt; the `plan_gate` pattern was tested separately
in an earlier revision against a raw tofu line and the Terragrunt-prefixed line of a
real production capture.

Runbook defects found by this rehearsal: the local-path provisioner race above (fixed in
the infra apply block). Defects of earlier rehearsals, already fixed: the built-in `local-path` class
provisions `local` volumes (the volume path is `.spec.local.path`, the Retain class of
the module uses `hostPath`), the provisioner makes the base directory `0700` root, so a
path below it needs `sudo` even for `findmnt`, and an image pull on a root disk with
too little free space evicts pods.

### Re-attach rehearsal (section 9.1, garuda-internal `b12124c4`)

On the stand after its e2e run (Firezone v3 on the CNPG Cluster, 3 users/3 devices seeded, the
stand's enrolled client). The procedure's command blocks (then in the module README, now section 9.1) were extracted
and run verbatim as root on the hub, only the placeholders substituted (the one deviation: `tofu apply`
through `./stand tofu` with `-auto-approve`, module address `module.site.module.firezone_db`).

1. **Crash-consistent copy of the running Cluster's volume.** `fsfreeze -f /` of the hub's only
   filesystem, `tar --numeric-owner --atime-preserve=system` of the volume directory
   (192 MiB with WAL) into tmpfs, `fsfreeze -u /`: frozen 0.56 s, with a 30 s watchdog unfreeze
   and every binary preloaded (nothing may write while frozen). The copy has `postmaster.pid`,
   and the per-table counts of the live Cluster were identical before and after.
2. **Rebuild simulated.** The Firezone and database Helm releases uninstalled (the Terraform state
   keeps them, as after a real rebuild), Cluster, PVC and PV deleted (the k3s datastore objects
   gone), the volume directory replaced by the copy (the restored-disk case).
3. **Case "no app yet".** `tofu apply -target` (`Plan: 1 to add`) 34 s; the Cluster Ready and the
   `0/0` guard 18 s; the temporary Postgres Ready in about 4 s (its log: "not properly shut
   down; automatic recovery in progress", redo 0/9004698 to 0/A0032C0); dump, restore and counts
   4 s; the full apply (Firezone) 67 s: 2 min 10 s from the first command.
4. **Case "the app already runs on the new empty Cluster".** The same rebuild, then a full apply
   (`Plan: 2 to add`; Firezone migrated the empty database, 0 users), then the "app already runs" branch (scale
   to 0, reset, restore, scale back): 63 s.
5. **Result of both cases.** Per-table counts identical to the live Cluster at copy time (api_tokens 0,
   configurations 1, connectivity_checks 0, devices 3, mfa_methods 0, oidc_connections 0, rules 0,
   schema_migrations 57, users 3); the existing admin password signs in; the original client's
   handshake is newer than the new Firezone pod (age 46 s and 49 s) and an echo request goes
   through the tunnel; `./stand e2e e2e/test_70_firezone_key.py e2e/test_15_database.py`: 3 passed.
   Without the two logging overrides the temporary Postgres exits at once
   (`could not open log file "/controller/log/postgres"`, checked).

Not run as written:

- **The production helper layer.** The `STANDENV` overrides replace `hub` (stand key
  and known-hosts file instead of the non-interactive alias), `k`/`kl` (`kubectl` instead
  of `k3s kubectl`) and every `terragrunt`-based helper (`init_*`, `plan_*`, `apply_*`,
  `state_pull`, `infra_show_json`) with `./stand tofu`. So Terragrunt itself was not
  exercised: its stdout prefixing and `TG_TF_FORWARD_STDOUT`, the tunstrap proxy,
  `terragrunt show -json` and `terragrunt apply <saved plan>` for the infra unit, and exit
  code 2 of `-detailed-exitcode` through Terragrunt. The read-only production dry-run of
  section 1.6 is a precondition of the window for exactly this reason.
- Block 1.1 uses the documented stand variable mapping (module addresses,
  `DATA_MOUNT=/`) and the `STANDENV` overrides; `age` was installed on the controller
  and `AGE_RECIPIENT` appended to `env.sh` as a throwaway key for the section 5 archive
  block; the stand hub's root disk was grown to 20 GiB. The driver puts `helm` on the
  `PATH` of the controller shell (it lives in `~/.local/bin` there).
- The two marker lines of 7.1 (`proxmox-backup-confirmed`, `monitoring-confirmed`) were
  written by hand: the stand has no Proxmox backup job (the time written was "now",
  after `window-end`) and no scheduled monitoring, so only the gate's marker logic was
  exercised, not the Proxmox confirmation itself.
- The 1.2 provisioner fix: the infra apply block was re-run as written only after an ad
  hoc revert of the infra change.
- The `headroom` block was re-run until the load fell below the ceiling (19
  STOPs, two more runs failed on a missing `helm` on the controller `PATH`, which is a
  driver matter); every other block ran in document order, once (3.1-3.2 twice by design).
- The sops comparison (1.4 A) needs a production sops file and was not run.
- Section 7.2 (retirement) was not re-run: it was rehearsed in an earlier revision (also
  without backups); only its volume path (`$STORAGE_PATH`) and its file-descriptor loops
  changed since.
- Section 9: only the database re-attach (section 9.1) was rehearsed, below. The
  Proxmox restore, the `qm`/`qmrestore` steps and the Terraform reconciliation were not run anywhere (the
  stand has no Proxmox): they are written from the production layout and checked against the Proxmox VE
  documentation (`qm.1`, `qmrestore.1`) only. Neither is the freshness script of section 8 (stubbed
  `pvesh` / `proxmox-backup-client` only) nor the Proxmox/PBS inspection of 7.1 (File Restore, task log).
- The review-5/6 blocks (age archives and `archive_proven`, `backup_run_epoch`, the run-ID markers in
  `cleanup_gate`, the split post-apply block, the pre-pull `render`) were first run on the stand in the
  review-7 pass below, as extracted, with the marker lines and `ARCHIVE_COPY` fed by hand (the "stored copy" is a `cp`).

Clean `./stand reset && ./stand up && ./stand e2e` on the unmodified garuda-internal
`b12124c4` (after the re-attach rehearsal): `reset` rc 0 (~10 min), `up` rc 0 (~12 min; the hub's
recreated 8.6 GiB root disk was grown to 20 GiB on the stand host right after the reset, before the
k3s apply; hub k3s `NRestarts` 0), `e2e` 48 passed, 1 xfailed (the known strict xfail), drift plan
"No changes".

### Review 7 stand pass (2026-11-10, garuda-internal `b12124c4`, runbook blocks as extracted)

On the green stand after its e2e run (Firezone v3 on the CNPG Cluster; `HUB_VMID=100`,
`BACKUP_INTERVAL_S=86400`, throwaway age key), each block in a fresh `bash` without `set -e`:

- Post-apply checks block (1.2, split): `STORAGE_PATH_OK`, provisioner restarted, pods settled, `NRestarts` 0.
- Pre-pull block: `headroom` STOPped on the 5-minute load for about 8 minutes (never relaxed), then
  `render` produced the operator chart's image (`cloudnative-pg:1.30.1`), the set with `PG_IMAGE` has 2 lines,
  both pulled ("up to date"), `PREPULL_OK`.
- 7.1 dump block: `DUMP_VERIFIED` (scratch database created, counts equal, dropped); archive block; section 5 archive
  block; both `archive_proven` blocks with a downloaded-back copy (`ARCHIVE_5_PROVEN`, `ARCHIVE_LIVE_PROVEN`).
- Dump re-run: the second run of the dump block removed `archive-live-proven` and the old
  `live-before-cleanup.tar.age`, the gate then refused ("both must be stored and decrypt-tested"), the old
  stored copy was refused against the new archive (`cmp` differs), the new archive passed.
- `cleanup_gate` with real-format IDs: `CLEANUP_GATE_OK` with the PBS snapshot ID `vm/100/<UTC>Z` and with a
  single-VM UPID (`UPID:<node>:...:<hex epoch>:vzdump:100:root@pam:`); refused (`STOP: the marker is not ...`) for a
  namespace prefix, a `<storage>:backup/` prefix, a UPID with an empty ID field and a local time.
- Deletion block against a fake empty `.../postgres-data` directory on the hub: gate passed, directory removed,
  `shred` of the one existing dump and a skip of the missing `firezone.dump`, rc 0 (the old block would have
  failed there). A second run stops in the gate, as designed: the dump it checks is gone.
- Section 9 step 5 block (`HUB_VMID` update): appended `HUB_VMID=101`, `backup_run_epoch` then accepts `vm/101/...` only.

Final, after this pass: `./stand e2e` on the unmodified `b12124c4`: 48 passed, 1 xfailed (the known strict xfail),
drift plan "No changes" (no reset was needed).

Re-pin to garuda-internal `906bcc06` (2026-11-11): only the module delta stated above; no runbook block was
re-run. Clean `./stand reset && ./stand up && ./stand e2e` on it (the hub disk grown to 20 GiB right after the
reset): 47 passed, 1 xfailed (the known strict xfail; one test fewer, the removed kernel-pin assertion),
drift plan "No changes". The stand no longer pins the hub kernel: it installs the distro's current kernel and
the hub booted `7.0.0-43-generic`, where the AppArmor regression tests passed.

## Stand rehearsal command mapping

Run only inside the dedicated stand host's `~/garuda-internal/examples/local-stand`
(never on a developer laptop or a live site). Section 1.1 is used unchanged,
except: set `FZ_MODULE=module.site.module.firezone_kube`,
`DB_MODULE=module.site.module.firezone_db`,
`OP_MODULE=module.site.module.cnpg_operator`, `DATA_MOUNT=/` (the stand has one
disk), skip `SOPS_*` and the sops comparison (use the generated-key branch B), set `HUB_VMID=100`
and `BACKUP_INTERVAL_S=86400` (the stand has no Proxmox: the 7.1 marker is then a synthetic
`vm/100/<now, UTC>Z` ID), and
**append** these overrides to `$BACKUP/env.sh` after the production definitions
(later definitions win). The controller needs `helm` (section 2 pre-pull). The stand
hub's default 8.6 GiB root disk fails the section 1.2/2 gates (and a pre-pull on it
evicts pods): grow it first on the stand host, e.g. `virsh blockresize
local-stand-hub vda 20G`, then `growpart /dev/vda 1` and `resize2fs /dev/vda1` in the
hub.

```bash
cat >> "$BACKUP/env.sh" <<'STANDENV'
UNIT="$PWD/garuda"
INFRA_HUB_ADDR='module.node["hub"].terraform_data.converge'
hub() { local remote; printf -v remote '%q ' "$@";
  ssh -T -i .state/ssh/id_ed25519 -o UserKnownHostsFile=.state/known_hosts -o HostKeyAlias=hub \
  "vagrant@$(jq -r '.hub.mgmt_ip' .state/hosts.json)" "$remote"; }
k() { hub sudo kubectl --request-timeout=60s "$@"; }
kl() { hub sudo kubectl "$@"; }
init_infra() { ./stand tofu infra init; }
plan_infra() { ./stand tofu infra plan "$@"; }
apply_infra() { ./stand tofu infra apply "$@"; }
infra_show_json() { ./stand tofu infra show -json "$1"; }
apply_init() { ./stand tofu garuda init; }
plan_site() { ./stand tofu garuda plan "$@"; }
apply_site() { ./stand tofu garuda apply -auto-approve "$@"; }
state_pull() { ./stand tofu garuda state pull; }
STANDENV
```

The stand hub has `kubectl` directly (not `k3s kubectl`). Section 1.2 on the stand:
the hub's `k3s_config` in `infra/main.tf` gets the `default-local-storage-path`
line (a stand revision from before it was committed does not have it; the committed
revision sets it from the start and the infra gate then shows no change). For the stand's secret-store equivalent, copy the captured
camelCase object to
`.state/t5-encryption-secrets.json` (mode 0600) and temporarily add
`firezone_encryption_secrets = jsondecode(file("${path.module}/../.state/t5-encryption-secrets.json"))`
to the root stand `module "site"` block. This is a throwaway rehearsal override,
not a committed secret and not a substitute for production sops storage. Remove
the override before the final unmodified-HEAD drift check; preserved random-byte
state must still produce the same keys.

For the archive blocks of section 5 and 7.1 on the stand: `age-keygen` a throwaway identity on the controller
(`AGE_RECIPIENT`, `AGE_IDENTITY` in `env.sh`), `cp` each `.tar.age` to a path outside `$BACKUP` as the "stored copy"
(`ARCHIVE_COPY=...`), and write the 7.1 marker lines with a synthetic but real-format ID (`vm/100/<UTC>Z`, or a UPID
with the hex epoch and `vzdump:100`) whose time is after `window-end`.

`./stand` progress messages must not contaminate `state pull` JSON (the jq
checks fail loudly if they do), and `plan_gate` relies on `-no-color` being
passed through `./stand tofu`; verify both in the rehearsal. Archive files stay
on the stand **controller**, not the hub VM. For the final full drift/functional
gate use `./stand e2e`.
