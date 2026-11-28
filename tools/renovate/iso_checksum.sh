#!/usr/bin/env bash
set -eu
set -o pipefail

# Shellscript for renovate in packer-hyperv
#
# Sets the default of variable "iso_checksum" in packer templates to the
# sha256 of the ISO in the default of variable "iso_url". The checksum is
# read from the official checksum list of the distribution:
#   Oracle Linux: https://linux.oracle.com/security/gpg/checksum/
#   Ubuntu:       https://releases.ubuntu.com/<version>/SHA256SUMS
# Called by renovate as postUpgradeTasks (see renovate.json).
#
# Usage: iso_checksum.sh <template.pkr.hcl>...          update iso_checksum
#        iso_checksum.sh --check <template.pkr.hcl>...  only compare, exit 1 on difference

check=false
if [ "${1:-}" = --check ] ; then
  check=true
  shift
fi

if [ $# -lt 1 ] ; then
  echo "Usage: $0 [--check] <template.pkr.hcl>..."
  exit 2
fi

# default of a packer variable: first 'default = "..."' after 'variable "<name>" {'
var_default() {
  awk -v name="$1" '
    $0 ~ "^variable \"" name "\"" { found = 1 }
    found && /^[[:space:]]*default[[:space:]]*=/ {
      sub(/^[^"]*"/, ""); sub(/".*$/, ""); print; exit
    }
    found && /^}/ { exit }
  ' "$2"
}

# sha256 of the ISO from the official checksum list
official_checksum() {
  local iso_url=$1 iso sums_url
  iso=${iso_url##*/}

  if [[ ${iso} =~ ^OracleLinux-R([0-9]+)-U([0-9]+)-x86_64-dvd\.iso$ ]] ; then
    sums_url="https://linux.oracle.com/security/gpg/checksum/OracleLinux-R${BASH_REMATCH[1]}-U${BASH_REMATCH[2]}-Server-x86_64.checksum"
  elif [[ ${iso} =~ ^ubuntu-([0-9.]+)-live-server-amd64\.iso$ ]] ; then
    sums_url="https://releases.ubuntu.com/${BASH_REMATCH[1]}/SHA256SUMS"
  else
    echo "unknown ISO ${iso} - no checksum list" >&2
    return 1
  fi

  # lines: '<sha256>  <file>' (Oracle) or '<sha256> *<file>' (Ubuntu)
  curl -fsSL --retry 3 "${sums_url}" \
    | awk -v iso="${iso}" '$2 == iso || $2 == "*" iso { print $1; exit }' \
    | grep -E '^[0-9a-f]{64}$' \
    || { echo "no sha256 for ${iso} in ${sums_url}" >&2 ; return 1 ; }
}

rc=0
for file in "$@" ; do
  iso_url=$(var_default iso_url "${file}")
  current=$(var_default iso_checksum "${file}")
  if [ -z "${iso_url}" ] || [ -z "${current}" ] ; then
    echo "${file}: variable iso_url or iso_checksum without default"
    exit 1
  fi

  new="sha256:$(official_checksum "${iso_url}")"

  if [ "${current}" = "${new}" ] ; then
    echo "${file}: iso_checksum is up to date (${iso_url##*/})"
  elif ${check} ; then
    echo "${file}: iso_checksum differs for ${iso_url##*/}"
    echo "  file:     ${current}"
    echo "  official: ${new}"
    rc=1
  else
    sed -i "/^variable \"iso_checksum\"/,/^}/ s|\(default[[:space:]]*=[[:space:]]*\)\"[^\"]*\"|\1\"${new}\"|" "${file}"
    echo "${file}: iso_checksum set to ${new} (${iso_url##*/})"
  fi
done
exit ${rc}
