# Copyright (c) 2012-2015 The OpenRC Authors.
# See the Authors file at the top-level directory of this distribution and
# https://github.com/OpenRC/openrc/blob/master/AUTHORS
#
# This file is part of OpenRC. It is subject to the license terms in
# the LICENSE file found in the top-level directory of this
# distribution and at https://github.com/OpenRC/openrc/blob/master/LICENSE
# This file may not be copied, modified, propagated, or distributed
#    except according to the terms contained in the LICENSE file.

extra_stopped_commands="${extra_stopped_commands} cgroup_cleanup"
description_cgroup_cleanup="Kill all processes in the cgroup"

cgroup_find_path()
{
	local OIFS name dir result
	[ -n "$1" ] || return 0
	OIFS="$IFS"
	IFS=":"
	while read -r _ name dir; do
		[ "$name" = "$1" ] && result="$dir"
	done < /proc/1/cgroup
	IFS="$OIFS"
	printf "%s" "${result}"
}

# This extracts all pids in a cgroup and puts them in the cgroup_pids
# variable.
# It is done this way to avoid subshells so we don't have to worry about
# locating the pid of the subshell in the cgroup.
# https://github.com/openrc/openrc/issues/396
cgroup_get_pids()
{
	local cgroup_procs p
	cgroup_pids=
	cgroup_procs="$(cgroup2_find_path)"
	if [ -n "${cgroup_procs}" ]; then
		cgroup_procs="${cgroup_procs}/${RC_SVCNAME}/cgroup.procs"
	else
		cgroup_procs="/sys/fs/cgroup/openrc/${RC_SVCNAME}/tasks"
	fi
	[ -f "${cgroup_procs}" ] || return 0
	while read -r p; do
		[ "$p" -eq $$ ] && continue
		cgroup_pids="${cgroup_pids} ${p}"
	done < "${cgroup_procs}"
	return 0
}

cgroup_running()
{
	[ -d "/sys/fs/cgroup/unified/${RC_SVCNAME}" ] ||
			[ -d "/sys/fs/cgroup/${RC_SVCNAME}" ] ||
			[ -d "/sys/fs/cgroup/openrc/${RC_SVCNAME}" ]
}

cgroup_set_values()
{
	[ -n "$1" ] && [ -n "$2" ] && [ -d "/sys/fs/cgroup/$1" ] || return 0

	local controller h
	controller="$1"
	h=$(cgroup_find_path "$1")
	cgroup="/sys/fs/cgroup/${1}${h}openrc_${RC_SVCNAME}"
	[ -d "$cgroup" ] || mkdir -p "$cgroup"

	set -- $2
	local name val
	while [ -n "$1" ] && [ "$controller" != "cpuacct" ]; do
		case "$1" in
			$controller.*)
				if [ -n "${name}" ] && [ -w "${cgroup}/${name}" ] &&
					[ -n "${val}" ]; then
					veinfo "$RC_SVCNAME: Setting $cgroup/$name to $val"
					printf "%s" "$val" > "$cgroup/$name"
				fi
				name=$1
				val=
				;;
			*)
				[ -n "$val" ] &&
					val="$val $1" ||
					val="$1"
				;;
		esac
		shift
	done
	if [ -n "${name}" ] && [ -w "${cgroup}/${name}" ] && [ -n "${val}" ]; then
		veinfo "$RC_SVCNAME: Setting $cgroup/$name to $val"
		printf "%s" "$val" > "$cgroup/$name"
	fi

	if [ -w "$cgroup/tasks" ]; then
		veinfo "$RC_SVCNAME: adding to $cgroup/tasks"
		printf "%d" 0 > "$cgroup/tasks"
	fi

	return 0
}

cgroup_add_service()
{
    # relocate starting process to the top of the cgroup
    # it prevents from unwanted inheriting of the user
    # cgroups. But may lead to a problems where that inheriting
    # is needed.
	for d in /sys/fs/cgroup/* ; do
		[ -w "${d}"/tasks ] && printf "%d" 0 > "${d}"/tasks
	done

	openrc_cgroup=/sys/fs/cgroup/openrc
	if [ -d "$openrc_cgroup" ]; then
		cgroup="$openrc_cgroup/$RC_SVCNAME"
		mkdir -p "$cgroup"
		[ -w "$cgroup/tasks" ] && printf "%d" 0 > "$cgroup/tasks"
	fi
}

cgroup_set_limits()
{
	local blkio="${rc_cgroup_blkio:-$RC_CGROUP_BLKIO}"
	[ -n "$blkio" ] && cgroup_set_values blkio "$blkio"

	local cpu="${rc_cgroup_cpu:-$RC_CGROUP_CPU}"
	[ -n "$cpu" ] && cgroup_set_values cpu "$cpu"

	local cpuacct="${rc_cgroup_cpuacct:-$RC_CGROUP_CPUACCT}"
	[ -n "$cpuacct" ] && cgroup_set_values cpuacct "$cpuacct"

	local cpuset="${rc_cgroup_cpuset:-$RC_CGROUP_cpuset}"
	[ -n "$cpuset" ] && cgroup_set_values cpuset "$cpuset"

	local devices="${rc_cgroup_devices:-$RC_CGROUP_DEVICES}"
	[ -n "$devices" ] && cgroup_set_values devices "$devices"

	local hugetlb="${rc_cgroup_hugetlb:-$RC_CGROUP_HUGETLB}"
	[ -n "$hugetlb" ] && cgroup_set_values hugetlb "$hugetlb"

	local memory="${rc_cgroup_memory:-$RC_CGROUP_MEMORY}"
	[ -n "$memory" ] && cgroup_set_values memory "$memory"

	local net_cls="${rc_cgroup_net_cls:-$RC_CGROUP_NET_CLS}"
	[ -n "$net_cls" ] && cgroup_set_values net_cls "$net_cls"

	local net_prio="${rc_cgroup_net_prio:-$RC_CGROUP_NET_PRIO}"
	[ -n "$net_prio" ] && cgroup_set_values net_prio "$net_prio"

	local pids="${rc_cgroup_pids:-$RC_CGROUP_PIDS}"
	[ -n "$pids" ] && cgroup_set_values pids "$pids"

	return 0
}

cgroup2_find_path()
{
	if grep -qw cgroup2 /proc/filesystems; then
		case "${rc_cgroup_mode:-hybrid}" in
			hybrid) printf "/sys/fs/cgroup/unified" ;;
			unified) printf "/sys/fs/cgroup" ;;
		esac
	fi
		return 0
}

cgroup2_remove()
{
	local cgroup_path rc_cgroup_path
	cgroup_path="$(cgroup2_find_path)"
	[ -z "${cgroup_path}" ] && return 0
	rc_cgroup_path="${cgroup_path}/${RC_SVCNAME}"
	[ ! -d "${rc_cgroup_path}" ] ||
		[ ! -e "${rc_cgroup_path}"/cgroup.events ] &&
		return 0
	grep -qx "$$" "${rc_cgroup_path}/cgroup.procs" &&
		printf "%d" 0 > "${cgroup_path}/cgroup.procs"
	local key populated vvalue
	while read -r key value; do
		case "${key}" in
			populated) populated=${value} ;;
			*) ;;
		esac
	done < "${rc_cgroup_path}/cgroup.events"
	[ "${populated}" = 1 ] && return 0
	rmdir "${rc_cgroup_path}"
	return 0
}

cgroup2_set_limits()
{
	local cgroup_path
	cgroup_path="$(cgroup2_find_path)"
	[ -z "${cgroup_path}" ] && return 0
	mountinfo -q "${cgroup_path}"|| return 0
	rc_cgroup_path="${cgroup_path}/${RC_SVCNAME}"
	[ ! -d "${rc_cgroup_path}" ] && mkdir "${rc_cgroup_path}"
	[ -f "${rc_cgroup_path}"/cgroup.procs ] &&
		printf 0 > "${rc_cgroup_path}"/cgroup.procs
	[ -z "${rc_cgroup_settings}" ] && return 0
	echo "${rc_cgroup_settings}" | while read -r key value; do
		[ -z "${key}" ] && continue
		[ -z "${value}" ] && continue
		[ ! -f "${rc_cgroup_path}/${key}" ] && continue
		veinfo "${RC_SVCNAME}: cgroups: setting ${key} to ${value}"
		printf "%s" "${value}" > "${rc_cgroup_path}/${key}"
	done
	return 0
}

cgroup2_kill_cgroup() {
	local cgroup_path
	cgroup_path="$(cgroup2_find_path)"
	[ -z "${cgroup_path}" ] && return 1
	rc_cgroup_path="${cgroup_path}/${RC_SVCNAME}"
	if [ -f "${rc_cgroup_path}"/cgroup.kill ]; then
		printf "%d" 1 > "${rc_cgroup_path}"/cgroup.kill
	fi
	return
}

cgroup_fallback_cleanup() {
	ebegin "Starting fallback cgroups cleanup"
	local loops=0
	cgroup_get_pids
	if [ -n "${cgroup_pids}" ]; then
		kill -s CONT ${cgroup_pids} 2> /dev/null
		kill -s "${stopsig:-TERM}" ${cgroup_pids} 2> /dev/null
		yesno "${rc_send_sighup:-no}" &&
			kill -s HUP ${cgroup_pids} 2> /dev/null
		kill -s "${stopsig:-TERM}" ${cgroup_pids} 2> /dev/null
		cgroup_get_pids
		while [ -n "${cgroup_pids}" ] &&
			[ "${loops}" -lt "${rc_timeout_stopsec:-90}" ]; do
			loops=$((loops+1))
			sleep 1
			cgroup_get_pids
		done
		if [ -n "${cgroup_pids}" ] && yesno "${rc_send_sigkill:-yes}"; then
			kill -s KILL ${cgroup_pids} 2> /dev/null
		fi
	fi
	eend $?
}

cgroup_cleanup()
{
	cgroup_running || return 0
	ebegin "Starting cgroups cleanup"
	cgroup2_kill_cgroup || cgroup_fallback_cleanup
	cgroup2_remove
	cgroup_get_pids
	[ -z "${cgroup_pids}" ]
	eend $? "Unable to stop all processes"
	return 0
}
