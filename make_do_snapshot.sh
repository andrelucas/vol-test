#!/bin/bash

set -e
declare -a ips

cli_branch="${CLI_BRANCH:-}"
cli_version="${CLI_VERSION:-0.0.11}"

branch_env="${BRANCH_ENV:-branchnotset}"
# Make sure branch_env has at most 16 characters.
if [ "$branch_env" = "branchnotset" ]; then
    branch_env="$(uuidgen | cut -c1-13)"
else
    branch_env="$(echo "$branch_env" | cut -c1-16)"
fi

build_id="${branch_env}-${BUILD:-buildnotset}"
tag="vol-test-snapshot-${build_id}"
region=lon1
size=2gb
name_template="${tag}-${size}-${region}-"

master_name="${name_template}-master"
snapshot_name="vol-test-snapshot"

if [[ -f user_provision.sh ]] && [[  -z "$JENKINS_JOB" ]]; then
    echo "Loading user settings overrides from user_provision.sh"
    . ./user_provision.sh
fi

function download_storageos_cli()
{
  local build_id

  if [ -z "$cli_branch" ]; then
    echo "Downloading CLI version ${cli_version}"
    export cli_binary=storageos_linux_amd64-${cli_version}

    if [[ ! -f $cli_binary ]]; then
      curl --fail -sSL "https://github.com/storageos/go-cli/releases/download/${cli_version}/storageos_linux_amd64" > "$cli_binary"
      chmod +x "$cli_binary"
    fi
  else
    # Build the binary.
    echo "Building CLI from source, branch ${cli_branch}"
    export cli_binary=storageos_linux_amd64
    rm -rf cli_build ${cli_binary}
    # Check out the upstream repository.
    git clone https://github.com/storageos/go-cli.git cli_build
    pushd cli_build
    if [ "$cli_branch" != master ]; then
      git co -b "${cli_branch}" "${cli_branch}"
    fi
    docker build -t "cli_build:${cli_branch}" .
    # Need to run a container and copy the file from it. Can't copy from the image.
    build_id="$(docker run -d "cli_build:${cli_branch}" version)"
    docker cp "${build_id}:/storageos" "${cli_binary}"
    popd
    rm -rf cli_build
  fi
}

function provision_master_node()
{
  # requires: master_name
  # exports: droplets master_id
  local droplet ip TIMEOUT

  if [ -z "$master_name" ]; then
    echo "Function ${FUNCNAME[0]} requires $master_name to be defined and non-empty" >&2
    exit 1
  fi

  droplets=$($doctl_auth compute droplet list --tag-name "${tag}" --format ID --no-header)

  if [ ! -z "${droplets}" ]; then
    for droplet in $droplets; do
      echo "Deleting existing droplet ${droplet}"
      $doctl_auth compute droplet rm -f "${droplet}"
    done
  fi

  echo "Creating master droplet"
  $doctl_auth compute tag create "$tag"
  name="$master_name"

  # It makes sense to --wait here because we're only creating one droplet.
  id=$($doctl_auth --verbose compute droplet create \
    --image "$image" \
    --region $region \
    --size $size \
    --ssh-keys $SSHKEY \
    --tag-name "$tag" \
    --format ID \
    --no-header "$name" \
    --wait)
  droplets="${id}"
  master_id="$id"

  for droplet in $droplets; do

    while [[ "$status" != "active" ]]; do
      sleep 2
      status=$($doctl_auth compute droplet get "$droplet" --format Status --no-header)
    done

    sleep 5

    TIMEOUT=100
    ip=''
    until [[ -n $ip ]] || [[ $TIMEOUT -eq 0 ]]; do
      ip=$($doctl_auth compute droplet get "$droplet" --format PublicIPv4 --no-header)
      ips+=($ip)
      TIMEOUT=$((--TIMEOUT))
    done

    echo "$droplet: Waiting for SSH on $ip"
    TIMEOUT=100
    until nc -zw 1 "$ip" 22 || [[ $TIMEOUT -eq 0 ]] ; do
      sleep 2
      TIMEOUT=$((--TIMEOUT))
    done
    sleep 5

    ssh-keyscan -H "$ip" >> ~/.ssh/known_hosts
    echo "$droplet: Disabling firewall"
    until ssh "root@${ip}" "/usr/sbin/ufw disable"; do
      sleep 2
    done

    echo "$droplet: Enabling core dumps"
    ssh "root@${ip}" "ulimit -c unlimited >/etc/profile.d/core_ulimit.sh"
    ssh "root@${ip}" "export DEBIAN_FRONTEND=noninteractive && apt-get -qqy update && apt-get -qqy -o=Dpkg::Use-Pty=0 install systemd-coredump"

    echo "$droplet: Copying StorageOS CLI"
    scp -p "$cli_binary" r"oot@${ip}:/usr/local/bin/storageos"
    ssh "root@${ip}" "export STORAGEOS_USERNAME=storageos >>/root/.bashrc"
    ssh "root@${ip}" "export STORAGEOS_PASSWORD=storageos >>/root/.bashrc"

    echo "$droplet: Enable NBD"
    ssh "root@${ip}" "modprobe nbd nbds_max=1024"
  done
}

function snapshot_master_node() {
  # Requires: master_id master_name snapshot_name
  # Exports: snapshot_id
  local ssid id

  echo "Removing existing snapshots called '$snapshot_name'"
  ssid="$($doctl_auth compute snapshot list -o json | jq -r '. [] | select(.name == "vol-test-snapshot") | .id')"
  for id in $ssid; do
    echo "Remove $id"
    $doctl_auth compute snapshot delete -f "$id"
  done

  echo "Snapshotting master droplet ${master_name}(${master_id})"
  if [ -z "$master_id" ] || [ -z "$master_name" ]; then
    echo "Function ${FUNCNAME[0]} requires $master_id and $#master_name to be defined and non-empty" >&2
    exit 1
  fi
  $doctl_auth compute droplet-action power-off "$master_id" --wait
  snapshot_id=$($doctl_auth --verbose compute droplet-action snapshot \
    --snapshot-name "$snapshot_name" \
    --format ID \
    --wait \
    "$master_id")
  echo "Created snapshot $snapshot_name ID $snapshot_id"
}

function remove_master_node() {
  # Requires: master_id master_name
  echo "Removing master droplet ${master_name}(${master_id})"
  $doctl_auth --verbose compute droplet rm -f "$master_id"
}

function do_auth_init()
{

  # WE DO NOT MAKE USE OF DOCTL AUTH INIT but rather append the token to every request
  # this is because in a non-interactive jenkins job, any way of passing input (Heredoc, redirection) are ignored
  # with an 'unknown terminal' error we instead alias doctl and use the -t option everywhere
  export doctl_auth

  if [[ -z $DO_TOKEN ]] ; then
    echo "please ensure that your DO_TOKEN is entered in user_provision.sh"
    exit 1
  fi

  doctl_auth="doctl -t $DO_TOKEN"

  export image
  image=$($doctl_auth compute image list --public  | grep docker-16-04 | awk '{ print $1 }') # ubuntu on linux img
}

function MAIN()
{
   do_auth_init
   download_storageos_cli
   provision_master_node
   snapshot_master_node
   remove_master_node
}

MAIN
