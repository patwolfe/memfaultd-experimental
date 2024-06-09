#!/bin/sh
# shellcheck shell=dash
# shellcheck disable=SC2039  # local is non-POSIX

# based on https://github.com/rust-lang/rustup/blob/master/rustup-init.sh

# Enable for trace
# set -eux

main() {
  downloader --check
  need_cmd uname
  need_cmd mktemp
  need_cmd chmod
  need_cmd mkdir
  need_cmd rm
  need_cmd rmdir

  # systemd is currently a requirement for this script to work properly
  need_cmd systemctl
  local project_key
  local release_url
  local use_musl
  # Only use musl memfaultd when explicitly told to
  use_musl=$USE_MUSL
  release_url=$MEMFAULTD_URL
  while getopts ":p:u:m:" opt; do
    case $opt in
      p)
        project_key="$OPTARG"
        ;;
      u)
        release_url="$OPTARG"
        ;;
      m)
        use_musl=1
        ;;
      \?)
        echo "Invalid option: -$OPTARG" >&2
        exit 1
        ;;
    esac
  done

  get_architecture
  local _arch="$RETVAL"
  case "$_arch" in
    aarch64-linux)
      echo "Detected architecture: '${_arch}'."
      ;;
    arm-linux)
      echo "Detected architecture: '${_arch}'."
      ;;
    x86_64-linux)
      echo "Detected architecture: '${_arch}'."
      ;;
    *)
      err "no precompiled binaries available for architecture: ${_arch}"
      ;;
  esac

  local tmp_dir
  if ! tmp_dir="$(ensure mktemp -d)"; then
    # Because the previous command ran in a subshell, we must manually
    # propagate exit status.
    err "Couldn't create a temporary work directory - exiting"
  fi

  local device_name
  ensure read -p "Enter an ID for this device: " device_name </dev/tty

  # Fall back to default if a URL is not specified
  if [ -z "${release_url}" ]; then
    if [ $use_musl ]; then
      release_url="https://github.com/patwolfe/memfaultd-experimental/releases/latest/download/memfaultd_${_arch}-musl"
    else 
      release_url="https://github.com/patwolfe/memfaultd-experimental/releases/latest/download/memfaultd_${_arch}"
    fi
  fi
  local memfaultd_binary="${tmp_dir}/memfaultd"

  # install memfaultd
  echo "Downloading memfaultd binaries from ${release_url}..."
  ensure downloader "$release_url" "$memfaultd_binary"
  echo "Downloaded memfaultd ✅"

  ensure sudo cp "${memfaultd_binary}" /usr/bin
  ensure sudo chmod +x /usr/bin/memfaultd
  ensure sudo ln -s /usr/bin/memfaultd /usr/bin/memfaultctl
  ensure sudo ln -s /usr/bin/memfaultd /usr/sbin/memfault-core-handler

  # Attempt to populate Project Key with optional arg then env var,
  # finally falling back to prompting the user if it's empty
  if [ -z "${project_key}" ]; then
    project_key=$MEMFAULT_PROJECT_KEY
  fi
  if [ -z "${project_key}" ]; then
    ensure read -p "Enter a Memfault Project Key: " project_key </dev/tty
  fi

  # Only use config that includes logs if we are NOT using
  # musl, as that binary is not compiled with the `systemd`
  # feature, a requirement to enable reading logs from the 
  # system's journal
  if [ $use_musl ]; then
    install_memfaultd_config_file_no_logs "${tmp_dir}" "${project_key}"
  else 
    install_memfaultd_config_file "${tmp_dir}" "${project_key}"
  fi 

  echo "Installed memfaultd ✅"

  ensure install_memfault_device_info "${tmp_dir}" "$device_name"                                                                                                                                  

  # Initialize memfaultd.service if it's not running already
  if ! service_exists memfaultd; then
    ensure install_memfaultd_service_file "${tmp_dir}"
    ensure sudo systemctl daemon-reload
    ensure sudo systemctl enable memfaultd
    ensure sudo systemctl start memfaultd
    echo "Started memfaultd service. ✅"
  else
    # Restart to make sure config changes take effect
    ensure sudo systemctl restart memfaultd
    echo "Restarted memfaultd service. ✅"
  fi

  echo "Collecting data..."
  sleep 30
  ensure sudo memfaultctl sync
  echo "Sent data from this device to Memfault! ✅"

  eval "$(memfaultctl --version)" 2> /dev/null
  echo "Finished installing Memfault Linux SDK $VERSION!"
}

service_exists() {
  local n="$1"
  if [ "$(systemctl list-units --all -t service --full --no-legend "${n}".service | sed 's/^\s*//g' | cut -f1 -d' ')" = "${n}".service ]; then
    return 0
  else
    return 1
  fi
}

get_architecture() {
  local _cputype
  _cputype="$(uname -m)"
  local _ostype
  _ostype="$(uname -s | tr '[:upper:]' '[:lower:]')"

  case "$_cputype" in
    arm64 | aarch64)
      local _cputype=aarch64
      ;;
    x86_64)
      local _cputype=x86_64
      ;;
    *)
      err "no precompiled binaries available for CPU architecture: $_cputype"
      ;;

  esac

  local _arch="${_cputype}-${_ostype}"

  RETVAL="$_arch"
}

install_memfaultd_service_file() {
  cat > "$1"/memfaultd.service <<- EOM
[Unit]
Description=memfaultd daemon
After=local-fs.target network.target dbus.service
[Service]
Type=forking
PIDFile=/run/memfaultd.pid
ExecStart=/usr/bin/memfaultd --daemonize
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOM
  sudo mv "$1"/memfaultd.service /lib/systemd/system/
}

install_memfaultd_config_file() {
  project_key=$2
  cat > "$1"/memfaultd.conf <<- EOM
{
  "persist_dir": "/var/lib/memfaultd",
  "tmp_dir": null,
  "tmp_dir_min_headroom_kib": 10240,
  "tmp_dir_min_inodes": 100,
  "tmp_dir_max_usage_kib": 102400,
  "upload_interval_seconds": 3600,
  "heartbeat_interval_seconds": 3600,
  "enable_data_collection": true,
  "enable_dev_mode": true,
  "project_key": "$project_key",
  "base_url": "https://device.memfault.com",
  "reboot": {
    "last_reboot_reason_file": "/var/lib/memfaultd/last_reboot_reason"
  },
  "coredump": {
    "coredump_max_size_kib": 96000,
    "compression": "gzip",
    "rate_limit_count": 5,
    "rate_limit_duration_seconds": 3600,
    "capture_strategy": {
      "type": "threads",
      "max_thread_size_kib": 32
    },
    "log_lines": 100
  },
  "http_server": {
    "bind_address": "127.0.0.1:8787"
  },
  "logs": {
    "compression_level": 1,
    "max_lines_per_minute": 500,
    "rotate_size_kib": 10240,
    "rotate_after_seconds": 3600,
    "storage": "persist",
    "source": "journald"
  },
  "mar": {
    "mar_file_max_size_kib": 10240,
    "mar_entry_max_age_seconds": 604800
  },
  "metrics": {
    "enable_daily_heartbeats": false,
    "system_metric_collection": {
      "enable": true,
      "poll_interval_seconds": 10
    },
    "statsd_server": {
      "bind_address": "127.0.0.1:8125"
    }
  }
}
EOM
  sudo mv "$1"/memfaultd.conf /etc/memfaultd.conf
}


install_memfaultd_config_file_no_logs() {
  project_key=$2
  cat > "$1"/memfaultd.conf <<- EOM
{
  "persist_dir": "/var/lib/memfaultd",
  "tmp_dir": null,
  "tmp_dir_min_headroom_kib": 10240,
  "tmp_dir_min_inodes": 100,
  "tmp_dir_max_usage_kib": 102400,
  "upload_interval_seconds": 3600,
  "heartbeat_interval_seconds": 3600,
  "enable_data_collection": true,
  "enable_dev_mode": true,
  "project_key": "$project_key",
  "base_url": "https://device.memfault.com",
  "reboot": {
    "last_reboot_reason_file": "/var/lib/memfaultd/last_reboot_reason"
  },
  "coredump": {
    "coredump_max_size_kib": 96000,
    "compression": "gzip",
    "rate_limit_count": 5,
    "rate_limit_duration_seconds": 3600,
    "capture_strategy": {
      "type": "threads",
      "max_thread_size_kib": 32
    },
    "log_lines": 100
  },
  "http_server": {
    "bind_address": "127.0.0.1:8787"
  },
  "mar": {
    "mar_file_max_size_kib": 10240,
    "mar_entry_max_age_seconds": 604800
  },
  "metrics": {
    "enable_daily_heartbeats": false,
    "system_metric_collection": {
      "enable": true,
      "poll_interval_seconds": 10
    },
    "statsd_server": {
      "bind_address": "127.0.0.1:8125"
    }
  }
}
EOM
  sudo mv "$1"/memfaultd.conf /etc/memfaultd.conf
}

install_memfault_device_info() {
  cat > "$1"/memfault-device-info <<- EOM
#!/bin/bash

echo "MEMFAULT_DEVICE_ID=$2"
echo "MEMFAULT_HARDWARE_VERSION=$(uname -n)"
EOM
  sudo mv "$1"/memfault-device-info /usr/bin/
  sudo chmod +x /usr/bin/memfault-device-info
}

# This wraps curl or wget. Try curl first, if not installed,
# use wget instead.
downloader() {
  local _dld
  local _err
  local _status
  if check_cmd curl; then
    _dld=curl
  elif check_cmd wget; then
    _dld=wget
  else
    _dld='curl or wget' # to be used in error message of need_cmd
  fi

  # Used to verify curl or wget is available on the system at
  # start of script
  if [ "$1" = --check ]; then
    need_cmd "$_dld"
  elif [ "$_dld" = curl ]; then
    _err=$(curl --silent --show-error --fail --location "$1" --output "$2" 2>&1)
    _status=$?
    if [ -n "$_err" ]; then
      echo "$_err" >&2
    fi
    return $_status
  elif [ "$_dld" = wget ]; then
    _err=$(wget "$1" -O "$2" 2>&1)
    _status=$?
    if [ -n "$_err" ]; then
      echo "$_err" >&2
    fi
    return $_status
  else
    err "Unknown downloader" # should not reach here
  fi
}

err() {
  echo "$1" >&2
  exit 1
}

need_cmd() {
  if ! check_cmd "$1"; then
    err "need '$1' (command not found)"
  fi
}

check_cmd() {
  command -v "$1" > /dev/null 2>&1
  return $?
}

need_ok() {
  if [ $? != 0 ]; then err "$1"; fi
}

assert_nz() {
  if [ -z "$1" ]; then err "assert_nz $2"; fi
}

# Run a command that should never fail. If the command fails execution
# will immediately terminate with an error showing the failing
# command.
ensure() {
  "$@"
  need_ok "command failed: $*"
}

main "$@" || exit 1
