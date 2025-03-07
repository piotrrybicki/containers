#!/bin/bash
#
# Bitnami Apache Flink library

# shellcheck disable=SC1091

# Load generic libraries
. /opt/bitnami/scripts/libpersistence.sh
. /opt/bitnami/scripts/libvalidations.sh

########################
# Set a config option into the Flink configuration specified file.
# Globals:
#   FLINK_*
# Arguments:
#   $1 - Property
#   $2 - Value
# Returns:
#   None
#########################
flink_set_config_option() {
  local option=$1
  local value=$2

  # escape periods for usage in regular expressions
  # shellcheck disable=SC2001
  # shellcheck disable=SC2155
  local escaped_option=$(echo "${option}" | sed -e "s/\./\\\./g")

  # either override an existing entry, or append a new one
  if grep -E "^${escaped_option}:.*" "${FLINK_CONF_FILE_PATH}" > /dev/null; then
        sed -i -e "s/${escaped_option}:.*/$option: $value/g" "${FLINK_CONF_FILE_PATH}"
  else
        echo "${option}: ${value}" >> "${FLINK_CONF_FILE_PATH}"
  fi
}

########################
# Validate settings in FLINK_* env vars
# Globals:
#   FLINK_*
# Arguments:
#   None
# Returns:
#   0 if the validation succeeded, 1 otherwise
#########################
flink_validate() {
    debug "Validating settings in FLINK_* environment variables..."
    local error_code=0

    # Auxiliary functions
    print_validation_error() {
        error "$1"
        error_code=1
    }
    check_valid_positive_int() {
        local -r port_var="${1:?missing port variable}"
        local err
        if ! err="$(is_positive_int "${port_var}")"; then
            print_validation_error "An invalid positive integer was specified in the environment variable ${port_var}: ${err}."
        fi
    }

    check_valid_positive_int "$FLINK_TASK_MANAGER_NUMBER_OF_TASK_SLOTS"

    return "$error_code"
}

########################
# Configure Flink configuration files from environment variables
# Globals:
#   FLINK_*
# Arguments:
#   None
# Returns:
#   None
#########################
flink_configure_from_environment_variables() {
    # Map environment variables to config properties
    for var in "${!FLINK_CFG_@}"; do
        key="$(echo "$var" | sed -e 's/^FLINK_CFG_//g' -e 's/__/\-/g' | sed -e 's/^FLINK_CFG_//g' -e 's/_/\./g' | tr '[:upper:]' '[:lower:]')"
        # Exception for the camel case in this environment variable
        [[ "$var" == "FLINK_CFG_HIGH__AVAILABILITY_STORAGE_DIR" ]] && key="high-availability.storageDir"

        value="${!var}"
        flink_set_config_option "$key" "$value"
    done
}

########################
# Initialize Flink configuration
# Globals:
#   FLINK_*
# Arguments:
#   None
# Returns:
#   None
#########################
flink_initialize() {
      local -r app_name="flink"

      flink_setup_jemalloc

      if ! is_app_initialized "$app_name"; then
          # Ensure Discourse persisted directories exist (i.e. when a volume has been mounted to /bitnami)
          info "Ensuring Flink directories exist"
          ensure_dir_exists "$FLINK_VOLUME_DIR"
          # Use daemon:root ownership for compatibility when running as a non-root user
          am_i_root && configure_permissions_ownership "$FLINK_VOLUME_DIR" -d "775" -f "664" -u "$FLINK_DAEMON_USER" -g "$FLINK_DAEMON_GROUP"

          flink_prepare_configuration

          info "Persisting Flink installation"
          persist_app "$app_name" "$FLINK_DATA_TO_PERSIST"
      else
          info "Restoring persisted Flink installation"
          restore_persisted_app "$app_name" "$FLINK_DATA_TO_PERSIST"
      fi
}

########################
# Prepare basic configuration options
# Globals:
#   FLINK_*
# Arguments:
#   None
# Returns:
#   None
#########################
flink_prepare_configuration() {
    # Emulate upstream logic and initial config
    flink_set_config_option blob.server.port 6124
    flink_set_config_option query.server.port 6125

    if [[ -n "${FLINK_TASK_MANAGER_NUMBER_OF_TASK_SLOTS}" ]]; then
        flink_set_config_option taskmanager.numberOfTaskSlots "${FLINK_TASK_MANAGER_NUMBER_OF_TASK_SLOTS}"
    fi

    if [[ -n "${FLINK_PROPERTIES}" ]]; then
        echo "${FLINK_PROPERTIES}" >> "${FLINK_CONF_FILE_PATH}"
    fi

    flink_configure_from_environment_variables

    envsubst < "${FLINK_CONF_FILE_PATH}" > "${FLINK_CONF_FILE_PATH}.tmp" && mv "${FLINK_CONF_FILE_PATH}.tmp" "${FLINK_CONF_FILE_PATH}"
}

########################
# Find the path to the libjemalloc library file
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   Path to a libjemalloc shared object file
#########################
find_jemalloc_lib() {
    local -a locations=( "/usr/lib" "/usr/lib64" )
    local -r pattern='libjemalloc.so.[0-9]'
    local path
    for dir in "${locations[@]}"; do
        # Find the first element matching the pattern and quit
        [[ ! -d "$dir" ]] && continue
        path="$(find "$dir" -name "$pattern" -print -quit)"
        [[ -n "$path" ]] && break
    done
    echo "${path:-}"
}

########################
# Configure jemalloc path (ignored if flink-env.sh is mounted)
# Globals:
#   FLINK_*
# Arguments:
#   None
# Returns:
#   None
#########################
flink_setup_jemalloc() {
    if [[ -n "$(find_jemalloc_lib)" ]]; then
        # shellcheck disable=SC2155
        export LD_PRELOAD=$(find_jemalloc_lib)
    else
        warn "Couldn't find jemalloc installed. Skipping jemalloc configuration."
    fi
}
