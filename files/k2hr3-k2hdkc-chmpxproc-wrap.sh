#!/bin/sh
#
# K2HR3 Helm Chart
#
# Copyright 2022 Yahoo Japan Corporation.
#
# K2HR3 is K2hdkc based Resource and Roles and policy Rules, gathers 
# common management information for the cloud.
# K2HR3 can dynamically manage information as "who", "what", "operate".
# These are stored as roles, resources, policies in K2hdkc, and the
# client system can dynamically read and modify these information.
#
# For the full copyright and license information, please view
# the license file that was distributed with this source code.
#
# AUTHOR:   Takeshi Nakatani
# CREATE:   Wed Jan 19 2022
# REVISION:
#

#----------------------------------------------------------
# Common variables
#----------------------------------------------------------
ANTPICKAX_ETC_DIR="/etc/antpickax"
FILE_RETRYCOUNT=60
LOOKUP_RETRYCOUNT=60
SLEEP_SHORT=10

#----------------------------------------------------------
# Configuration file path
#----------------------------------------------------------
if [ -z "$1" ] || [ "$1" = "SERVER" ] || [ "$1" = "server" ]; then
	CHMPX_MODE="server"
	SLEEP_GAP=10
elif [ "$1" = "SLAVE" ] || [ "$1" = "slave" ]; then
	CHMPX_MODE="slave"
	SLEEP_GAP=30
else
	CHMPX_MODE="server"
	SLEEP_GAP=10
fi
INI_FILE="${CHMPX_MODE}.ini"
INI_FILE_PATH="${ANTPICKAX_ETC_DIR}/${INI_FILE}"

#----------------------------------------------------------
# Wait configuration file creation
#----------------------------------------------------------
FILE_EXISTS=0
while [ "${FILE_EXISTS}" -eq 0 ]; do
	if [ -f "${INI_FILE_PATH}" ]; then
		FILE_EXISTS=1
	else
		FILE_RETRYCOUNT=$((FILE_RETRYCOUNT - 1))
		if [ "${FILE_RETRYCOUNT}" -le 0 ]; then
			echo "[ERROR] ${INI_FILE_PATH} is not existed."
			exit 1
		fi
		sleep "${SLEEP_SHORT}"
	fi
done

#----------------------------------------------------------
# Get OS name
#----------------------------------------------------------
if [ ! -f /etc/os-release ]; then
	echo "[ERROR] Not found /etc/os-release file."
	exit 1
fi
OS_NAME=$(grep '^ID[[:space:]]*=[[:space:]]*' /etc/os-release | sed -e 's|^ID[[:space:]]*=[[:space:]]*||g' -e 's|^[[:space:]]*||g' -e 's|[[:space:]]*$||g' -e 's|"||g')

#----------------------------------------------------------
# Preparation
#----------------------------------------------------------
#
# Check and Install nslookup
#
if ! command -v nslookup >/dev/null 2>&1; then
	if echo "${OS_NAME}" | grep -q -i "alpine"; then
		if ! apk update -q --no-progress >/dev/null 2>&1 || ! apk add -q --no-progress --no-cache bind-tools >/dev/null 2>&1; then
			echo "[ERROR] Failed to install bind-tools(nslookup)."
			exit 1
		fi
	elif echo "${OS_NAME}" | grep -q -i -e "ubuntu" -e "debian"; then
		if env | grep -i -e '^http_proxy' -e '^https_proxy'; then
			if ! test -f /etc/apt/apt.conf.d/00-aptproxy.conf || ! grep -q -e 'Acquire::http::Proxy' -e 'Acquire::https::Proxy' /etc/apt/apt.conf.d/00-aptproxy.conf; then
				_FOUND_HTTP_PROXY=$(env | grep -i '^http_proxy' | head -1 | sed -e 's#^http_proxy=##gi')
				_FOUND_HTTPS_PROXY=$(env | grep -i '^https_proxy' | head -1 | sed -e 's#^https_proxy=##gi')

				if echo "${_FOUND_HTTP_PROXY}" | grep -q -v '://'; then
					_FOUND_HTTP_PROXY="http://${_FOUND_HTTP_PROXY}"
				fi
				if echo "${_FOUND_HTTPS_PROXY}" | grep -q -v '://'; then
					_FOUND_HTTPS_PROXY="http://${_FOUND_HTTPS_PROXY}"
				fi
				if [ ! -d /etc/apt/apt.conf.d ]; then
					mkdir -p /etc/apt/apt.conf.d
				fi
				{
					echo "Acquire::http::Proxy \"${_FOUND_HTTP_PROXY}\";"
					echo "Acquire::https::Proxy \"${_FOUND_HTTPS_PROXY}\";"
				} >> /etc/apt/apt.conf.d/00-aptproxy.conf
			fi
		fi
		DEBIAN_FRONTEND=noninteractive
		export DEBIAN_FRONTEND

		if ! apt-get update -y -q -q >/dev/null 2>&1 || ! apt-get install -y dnsutils >/dev/null 2>&1; then
			echo "[ERROR] Failed to install dnsutils(nslookup)."
			exit 1
		fi
	elif echo "${OS_NAME}" | grep -q -i "centos"; then
		if ! yum update -y -q >/dev/null 2>&1 || ! yum install -y bind-utils >/dev/null 2>&1; then
			echo "[ERROR] Failed to install bind-utils(nslookup)."
			exit 1
		fi
	elif echo "${OS_NAME}" | grep -q -i -e "rocky" -e "fedora"; then
		if ! dnf update -y -q >/dev/null 2>&1 || ! dnf install -y bind-utils >/dev/null 2>&1; then
			echo "[ERROR] Failed to install bind-utils(nslookup)."
			exit 1
		fi
	else
		echo "[ERROR] Unknown OS type(${OS_NAME})."
		exit 1
	fi
fi

#
# Check all hostname
#
ALL_HOST_NAMES=$(grep 'NAME[[:space:]]*=' "${INI_FILE_PATH}" 2>/dev/null | sed 's/^[[:space:]]*NAME[[:space:]]*=[[:space:]]*//g' 2>/dev/null)

#
# Sleep time ajusting
#
for _ONE_NAME in $(echo "${ALL_HOST_NAMES}" | sort); do
	if echo "${_ONE_NAME}" | grep -q "$(hostname)"; then
		break
	fi
	SLEEP_GAP=$((SLEEP_GAP + 2))
done

#
# Wait all host lookup
#
DONE_ALL_LOOKUP=0
while [ "${DONE_ALL_LOOKUP}" -eq 0 ]; do
	REST_NAMES=""
	for _ONE_NAME in ${ALL_HOST_NAMES}; do
		if [ -z "${_ONE_NAME}" ]; then
			continue
		fi
		if ! nslookup "${_ONE_NAME}" >/dev/null 2>&1; then
			REST_NAMES="${REST_NAMES} ${_ONE_NAME}"
			continue
		fi
		#
		# Get lastest IP address
		#
		_ONE_IP=$(nslookup "${_ONE_NAME}" | grep -i 'address:' | tail -1 | sed -e 's/^[[:space:]]*address:[[:space:]]*//gi')

		if ! nslookup "${_ONE_IP}" >/dev/null 2>&1; then
			REST_NAMES="${REST_NAMES} ${_ONE_NAME}"
			continue
		fi
		_GET_NAMES=$(nslookup "${_ONE_IP}" | grep -i 'name[[:space:]]*=' | sed -e 's/^.*[[:space:]]*name[[:space:]]*=[[:space:]]*//gi')

		_FIND_NAME_IN_LIST=0
		for _GET_NAME in ${_GET_NAMES}; do
			if [ -n "${_GET_NAME}" ]; then
				if [ "${_GET_NAME}" = "${_ONE_NAME}" ] || [ "${_GET_NAME}" = "${_ONE_NAME}." ]; then
					_FIND_NAME_IN_LIST=1
					break;
				fi
			fi
		done
		if [ "${_FIND_NAME_IN_LIST}" -eq 0 ]; then
			REST_NAMES="${REST_NAMES} ${_ONE_NAME}"
		fi
	done

	ALL_HOST_NAMES=${REST_NAMES}

	if [ -z "${ALL_HOST_NAMES}" ]; then
		DONE_ALL_LOOKUP=1
	else
		if [ "${LOOKUP_RETRYCOUNT}" -le 0 ]; then
			echo "[ERROR] Lookup hosts is not completed."
			exit 1
		fi
		sleep "${SLEEP_SHORT}"
		LOOKUP_RETRYCOUNT=$((LOOKUP_RETRYCOUNT - 1))
	fi
done

sleep "${SLEEP_GAP}"

#----------------------------------------------------------
# Main processing
#----------------------------------------------------------
#
# Run chmpx process
#
set -e

#
# stdio/stderr is not redirected.
#
chmpx -conf "${INI_FILE_PATH}" -d err

exit $?

#
# Local variables:
# tab-width: 4
# c-basic-offset: 4
# End:
# vim600: noexpandtab sw=4 ts=4 fdm=marker
# vim<600: noexpandtab sw=4 ts=4
#
