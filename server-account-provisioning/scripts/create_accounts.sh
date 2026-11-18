#!/usr/bin/env bash
set +x
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
umask 077

usage() {
  echo 'Usage: sudo bash create_accounts.sh --check|--apply EXPECTED_HOST USER [USER ...]'
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ ${1:-} != --help ]] || { usage; exit 0; }
[[ $# -ge 3 ]] || { usage >&2; exit 2; }
mode=$1 expected_host=$2
shift 2
case $mode in --check|--apply) ;; *) die 'invalid mode' ;; esac
[[ $expected_host =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die 'invalid expected short hostname'
seen=()
for acct in "$@"; do
  [[ $acct =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'invalid username'
  for previous in "${seen[@]+${seen[@]}}"; do
    [[ $acct != "$previous" ]] || die "duplicate username: $acct"
  done
  seen+=("$acct")
done

[[ $(uname -s) == Linux && $EUID == 0 ]] || die 'requires Linux and root'
[[ $(hostname -s) == "$expected_host" ]] || die 'target hostname mismatch'
for cmd in getent findmnt flock useradd chpasswd chage passwd install setpriv stat mktemp; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done
[[ -x /bin/bash ]] || die 'missing /bin/bash'
exec 9>/run/lock/server-account-provisioning.lock
flock -n 9 || die 'another account operation is in progress'
mount_options=$(findmnt -n -o OPTIONS --mountpoint /data) || die '/data is not mounted'
[[ ,$mount_options, == *,rw,* ]] || die '/data is read-only'
for parent in /home /data /data/private; do
  [[ -d $parent && ! -L $parent ]] || die "expected a real directory: $parent"
  read -r owner permissions <<< "$(stat -c '%u %a' -- "$parent")"
  [[ $owner == 0 ]] && (( (8#$permissions & 8#022) == 0 )) || die "unsafe parent permissions: $parent"
done
[[ $(stat -c %d /data) != "$(stat -c %d /home)" ]] || die '/data and /home use the same device'
[[ $(stat -c %d /data) == "$(stat -c %d /data/private)" ]] || die '/data/private uses a different device'

conflict=0
for acct in "$@"; do
  for database in passwd group; do
    if getent "$database" "$acct" >/dev/null; then
      printf 'CONFLICT %s: existing %s entry\n' "$acct" "$database" >&2
      conflict=1
    else
      [[ $? == 2 ]] || die "getent $database failed for $acct"
    fi
  done
  for path in "/home/$acct" "/data/private/$acct"; do
    if [[ -e $path || -L $path ]]; then
      printf 'CONFLICT %s: existing path %s\n' "$acct" "$path" >&2
      conflict=1
    fi
  done
done
(( conflict == 0 )) || die 'batch preflight failed; no accounts created'
printf 'PREFLIGHT_OK %s %s\n' "$expected_host" "$#"
[[ $mode == --apply ]] || exit 0

IFS= read -r initial_password || die 'initial password input unavailable'
[[ -n $initial_password && $initial_password != *$'\r'* ]] || die 'invalid initial password input'

for acct in "$@"; do
  stage=create-account
  trap 'status=$?; printf "FAILED %s step=%s line=%s status=%s; inspect current state before retrying\n" "$acct" "$stage" "$LINENO" "$status" >&2; exit "$status"' ERR
  home_path=/home/$acct
  base=/data/private/$acct
  useradd -m -U -d "$home_path" -s /bin/bash -p '!' -e 1970-01-02 "$acct"

  stage=configure-storage
  install -d -m 755 -o root -g root -- "$base"
  mv -T -- "$home_path" "$base/home"
  chmod 700 -- "$base/home"
  ln -sT -- "$base/home" "$home_path"
  for dir in workspace conda conda/envs conda/pkgs home/.ssh home/.conda; do
    [[ ! -L $base/$dir ]]
    install -d -m 700 -o "$acct" -g "$acct" -- "$base/$dir"
  done
  ln -sT -- "$base/workspace" "$home_path/workspace"
  ln -sT -- "$base/conda/envs" "$home_path/.conda/envs"
  ln -sT -- "$base/conda/pkgs" "$home_path/.conda/pkgs"
  for link in workspace .conda/envs .conda/pkgs; do
    chown -h -- "$acct:$acct" "$home_path/$link"
  done
  layout=$(printf 'envs_dirs:\n  - %s/conda/envs\npkgs_dirs:\n  - %s/conda/pkgs' "$base" "$base")
  (set -o noclobber; printf '%s\n' "$layout" > "$home_path/.condarc")
  chown -- "$acct:$acct" "$home_path/.condarc"

  stage=verify-storage-and-identity
  IFS=: read -r name _ uid gid _ registered_home shell_path <<< "$(getent passwd "$acct")"
  [[ $name == "$acct" && $uid != 0 && $gid != 0 && $registered_home == "$home_path" && $shell_path == /bin/bash ]]
  [[ $(id -gn "$acct") == "$acct" && $(id -G "$acct") == "$gid" ]]
  [[ $(stat -c '%u:%g' -- "$home_path") == 0:0 && $(readlink -- "$home_path") == "$base/home" ]]
  [[ $(stat -c '%u:%g:%a' -- "$base") == 0:0:755 ]]
  for dir in home workspace conda conda/envs conda/pkgs home/.ssh home/.conda; do
    [[ $(stat -c '%u:%g:%a' -- "$base/$dir") == "$uid:$gid:700" ]]
  done
  [[ $(stat -c '%u:%g:%a' -- "$home_path/.condarc") == "$uid:$gid:600" ]]
  [[ $(cat -- "$home_path/.condarc") == "$layout" ]]
  for link in workspace .conda/envs .conda/pkgs; do
    [[ $(readlink -- "$home_path/$link") == "$base/${link#.}" ]]
    [[ $(stat -c '%u:%g' -- "$home_path/$link") == "$uid:$gid" ]]
  done
  setpriv --reuid="$uid" --regid="$gid" --init-groups \
    env -i PATH=/usr/bin:/bin bash --noprofile --norc -e -s -- "$home_path" "$base" <<'CHECK'
home_path=$1
base=$2
device=$(stat -c %d /data)
for dir in "$home_path" "$home_path/workspace" "$home_path/.conda/envs" "$home_path/.conda/pkgs"; do
  probe=$(mktemp -- "$dir/.storage-check.XXXXXX")
  trap 'unlink -- "$probe"' EXIT
  printf 'storage probe\n' > "$probe"
  test "$(stat -c %d -- "$probe")" = "$device"
  unlink -- "$probe"
  trap - EXIT
done
test ! -w /home
test ! -w /data/private
test ! -w "$base"
CHECK

  stage=configure-and-verify-password
  printf '%s:%s\n' "$acct" "$initial_password" | chpasswd
  chage -d 0 "$acct"
  read -r _ password_state _ <<< "$(passwd -S "$acct")"
  [[ $password_state == P ]]
  aging=$(chage -l "$acct")
  [[ ${aging%%$'\n'*} == 'Last password change'*'password must be changed' ]]
  stage=enable-account
  chage -E -1 "$acct"
  printf 'CREATED %s uid=%s gid=%s\n' "$acct" "$uid" "$gid"
done
unset initial_password
