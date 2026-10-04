#!/usr/bin/env bash
# Copyright 2026 Alibaba Cloud. All rights reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# Compare the synchronous, asynchronous and io_uring fusedev IO paths of
# fuse-backend-rs using fio.
#
# For each mode (sync: N worker threads, async: one FuseDevTask on the
# async runtime, uring: the experimental FUSE-over-io_uring transport),
# the script mounts the benchmark daemon and runs the same fio workloads
# against the mountpoint. The fio results are stored in JSON format
# ($RESULTS_DIR/<mode>-<workload>.json) under $RESULTS_DIR for further
# analysis, see tests/scripts/bench_compare.py.
#
# Requirements: Linux, fio, jq, permission to mount fuse (root or
# fusermount). The uring mode additionally requires kernel 6.14+ with
# FUSE-over-io_uring enabled (the fuse module parameter enable_uring,
# which the script tries to turn on when it is writable); kernels that
# reject the transport during the INIT handshake make the mode be
# skipped with a warning.
#
# Tunables (environment variables):
#   THREADS  number of sync worker threads / fio jobs (default 4)
#   SIZE     file size for the sequential workloads (default 256M)
#   RUNTIME  seconds per time-based workload (default 30)
#   NRFILES  number of files for the metadata workloads (default 50000);
#            large enough that each metadata workload runs for several
#            seconds, since sub-second measurements are noise dominated
#   MODES    execution order of the modes (default "sync async"); the
#            second mode benefits from a warmer page cache, so run both
#            orders to cross-check the results
#   DAEMON   path of a prebuilt benchmark daemon (default: build the
#            daemon of this repository in release mode); used by the CI
#            pipeline to benchmark different code variants with an
#            identical workload definition
#   RESULTS_DIR where to store results (default a fresh mktemp directory)
#   BS       block size of the sequential workloads (default 1M)
#   MAX_WRITE  if set, passed to the daemon as --max-write (bytes) to raise
#            the INIT max_write/max_pages and the session buffers; the
#            script also raises /proc/sys/fs/fuse/max_pages_limit (best
#            effort, needs root) since the kernel caps requests to it
#   DAEMON_ARGS  extra arguments appended to the daemon command line, e.g.
#            "--passthrough" for kernel FUSE passthrough (ignored by the
#            async mode, needs root)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd)
BENCH_DIR="${REPO_DIR}/tests/benchmark"
# tests/benchmark is a member of the root workspace, so build artifacts
# land in the workspace target directory, not under tests/benchmark.
DAEMON=${DAEMON:-"${REPO_DIR}/target/release/fuse-backend-rs-benchmark"}

THREADS=${THREADS:-4}
SIZE=${SIZE:-256M}
RUNTIME=${RUNTIME:-30}
NRFILES=${NRFILES:-50000}
MODES=${MODES:-"sync async"}
BS=${BS:-1M}
MAX_WRITE=${MAX_WRITE:-}
DAEMON_ARGS=${DAEMON_ARGS:-}
RESULTS_DIR=${RESULTS_DIR:-$(mktemp -d /tmp/fuse-bench-results.XXXXXX)}
SRC_DIR="${RESULTS_DIR}/source"
MNT_DIR="${RESULTS_DIR}/mount"
mkdir -p "${SRC_DIR}" "${MNT_DIR}"

WORKLOADS="seqwrite seqread randwrite-4k randread-4k filecreate filedelete"

command -v fio >/dev/null 2>&1 || { echo "error: fio is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

# kernel_at_least MAJOR MINOR: true if the running kernel is at least
# MAJOR.MINOR. Used to gate the uring mode, which requires the kernel
# FUSE_URING interface (6.14+).
kernel_at_least() {
    local want_major=$1 want_minor=$2 kv major minor
    kv=$(uname -r)
    major=${kv%%.*}
    minor=${kv#*.}
    minor=${minor%%.*}
    case "${major}${minor}" in
        *[!0-9]* | "") return 1 ;;
    esac
    [ "${major}" -gt "${want_major}" ] && return 0
    [ "${major}" -eq "${want_major}" ] && [ "${minor}" -ge "${want_minor}" ]
}

# The metadata workloads keep NRFILES files open at once, and the daemon
# holds an open handle per file as well, but the default soft fd limit of
# GitHub-hosted runners (1024) is far too low for that, so raise the soft
# limit to the hard limit; fio otherwise fails with
# "try reducing/setting openfiles". Note that fio and the daemon each need
# NRFILES descriptors, so the hard limit must cover both.
if ! ulimit -S -n "$(ulimit -H -n)"; then
    echo "warning: could not raise the fd limit" >&2
fi

echo "results directory: ${RESULTS_DIR}"

# The kernel caps the pages per request to max_pages_limit (256 pages by
# default), so a larger max_write needs the limit raised as well.
if [ -n "${MAX_WRITE}" ] && [ -w /proc/sys/fs/fuse/max_pages_limit ]; then
    pages=$(( (MAX_WRITE + $(getconf PAGESIZE) - 1) / $(getconf PAGESIZE) ))
    if [ "$(cat /proc/sys/fs/fuse/max_pages_limit)" -lt "${pages}" ]; then
        echo "${pages}" > /proc/sys/fs/fuse/max_pages_limit ||
            echo "warning: could not raise fs.fuse.max_pages_limit" >&2
    fi
fi

# Build the benchmark daemon in release mode, unless the caller provided
# a prebuilt one via $DAEMON (e.g. the CI pipeline benchmarking several
# code variants with this very script).
if [ ! -x "${DAEMON}" ]; then
    (cd "${BENCH_DIR}" && cargo build --release)
fi

DAEMON_PID=
cleanup() {
    if [ -n "${DAEMON_PID}" ]; then
        kill -TERM "${DAEMON_PID}" 2>/dev/null || true
        wait "${DAEMON_PID}" 2>/dev/null || true
    fi
    umount "${MNT_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

# start_daemon <mode args>: launch the daemon and wait for the mount to
# appear. Returns 1 when the daemon dies without serving (e.g. the kernel
# rejects the FUSE-over-io_uring negotiation) or when the mount does not
# appear in time; the caller decides whether that is fatal.
start_daemon() {
    local mode_args=$1
    # shellcheck disable=SC2086
    "${DAEMON}" "${SRC_DIR}" "${MNT_DIR}" ${mode_args} --threads "${THREADS}" \
        ${MAX_WRITE:+--max-write "${MAX_WRITE}"} ${DAEMON_ARGS} &
    DAEMON_PID=$!
    for _ in $(seq 50); do
        # A daemon that mounted and immediately died (rejected session)
        # leaves a stale mount behind; check aliveness before the
        # mountpoint so that the stale mount is never taken as success.
        if ! kill -0 "${DAEMON_PID}" 2>/dev/null; then
            wait "${DAEMON_PID}" 2>/dev/null || true
            DAEMON_PID=
            return 1
        fi
        if mountpoint -q "${MNT_DIR}"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

stop_daemon() {
    kill -TERM "${DAEMON_PID}" 2>/dev/null || true
    wait "${DAEMON_PID}" 2>/dev/null || true
    DAEMON_PID=
    sleep 1
}

# run_workload <mode> <name> <fio args...>
# Runs a time-based workload for ${RUNTIME} seconds.
run_workload() {
    local mode=$1
    local name=$2
    shift 2
    echo "--- [${mode}] ${name}: $*"
    # Flush dirty pages so that writeback of earlier workloads does not
    # interfere with this measurement.
    sync
    fio --name="${name}" --directory="${MNT_DIR}" --group_reporting \
        --time_based --runtime="${RUNTIME}" "$@" \
        --output-format=json \
        --output="${RESULTS_DIR}/${mode}-${name}.json" || {
            echo "error: fio workload ${name} failed" >&2
            exit 1
        }
    # Select the active side like bench_compare.py does: the data
    # workloads are active on exactly one side, and the filecreate and
    # filedelete engines may transfer no data at all, so compare iops.
    jq -r '.jobs[0] | if .read.iops >= .write.iops
           then "  read: bw=\(.read.bw)KiB/s iops=\(.read.iops | round)"
           else "  write: bw=\(.write.bw)KiB/s iops=\(.write.iops | round)"
           end' "${RESULTS_DIR}/${mode}-${name}.json" || true
}

# run_fixed_workload <mode> <name> <fio args...>
# Runs a workload for a fixed amount of work instead of ${RUNTIME} seconds.
# The filecreate/filedelete engines cannot be restarted by --time_based:
# filedelete hits ENOENT on the second round because the files created in
# the first round have already been deleted.
run_fixed_workload() {
    local mode=$1
    local name=$2
    shift 2
    echo "--- [${mode}] ${name}: $*"
    sync
    fio --name="${name}" --directory="${MNT_DIR}" --group_reporting "$@" \
        --output-format=json \
        --output="${RESULTS_DIR}/${mode}-${name}.json" || {
            echo "error: fio workload ${name} failed" >&2
            exit 1
        }
    jq -r '.jobs[0] | if .read.iops >= .write.iops
           then "  read: iops=\(.read.iops | round) runtime=\(.read.runtime)ms"
           else "  write: iops=\(.write.iops | round) runtime=\(.write.runtime)ms"
           end' "${RESULTS_DIR}/${mode}-${name}.json" || true
}

# shellcheck disable=SC2086
for mode in ${MODES}; do
    mode_args=""
    [ "${mode}" = "async" ] && mode_args="--async"
    if [ "${mode}" = "uring" ]; then
        if ! kernel_at_least 6 14; then
            echo "warning: mode uring requires kernel 6.14+ ($(uname -r)), skipping" >&2
            continue
        fi
        # Kernels >= 6.14 may still reject FUSE-over-io_uring: the fuse
        # module parameter enable_uring defaults to off on several distro
        # kernels. Try to turn it on (best effort, a no-op without root or
        # when the parameter does not exist); if the kernel keeps
        # rejecting the transport the startup probe below skips the mode.
        if [ -e /sys/module/fuse/parameters/enable_uring ]; then
            ( echo 1 > /sys/module/fuse/parameters/enable_uring ) 2>/dev/null || true
        fi
        mode_args="--uring"
    fi

    echo ""
    echo "############ mode: ${mode} ############"
    if ! start_daemon "${mode_args}"; then
        # Drop a possibly stale mount left by the failed daemon.
        umount "${MNT_DIR}" 2>/dev/null || true
        if [ "${mode}" = "uring" ]; then
            echo "warning: FUSE-over-io_uring is not available on this kernel, skipping mode uring" >&2
            continue
        fi
        echo "error: daemon did not mount ${MNT_DIR}" >&2
        exit 1
    fi

    # Sequential IO with large requests (throughput oriented). ramp_time
    # excludes cold-start effects (first touches, daemon caches warming up)
    # from the measurement.
    run_workload "${mode}" seqwrite --rw=write --bs="${BS}" --size="${SIZE}" \
        --numjobs="${THREADS}" --ioengine=psync --ramp_time=2
    run_workload "${mode}" seqread --rw=read --bs="${BS}" --size="${SIZE}" \
        --numjobs="${THREADS}" --ioengine=psync --ramp_time=2

    # Random IO with small requests (latency/metadata oriented).
    run_workload "${mode}" randwrite-4k --rw=randwrite --bs=4k --size=64M \
        --numjobs="${THREADS}" --ioengine=psync --ramp_time=2
    run_workload "${mode}" randread-4k --rw=randread --bs=4k --size=64M \
        --numjobs="${THREADS}" --ioengine=psync --ramp_time=2

    # Metadata operations: create and delete lots of small files. These run
    # for a fixed number of files instead of ${RUNTIME} seconds, see
    # run_fixed_workload().
    run_fixed_workload "${mode}" filecreate --ioengine=filecreate \
        --nrfiles="${NRFILES}" --numjobs=1 --filesize=4K
    run_fixed_workload "${mode}" filedelete --ioengine=filedelete \
        --nrfiles="${NRFILES}" --numjobs=1 --filesize=4K

    stop_daemon
done

# Print a side-by-side summary of the collected results.
summarize() {
    jq -r '.jobs[0] | if .read.iops >= .write.iops
           then "read: bw=\(.read.bw)KiB/s iops=\(.read.iops | round)"
           else "write: bw=\(.write.bw)KiB/s iops=\(.write.iops | round)"
           end' "$1" 2>/dev/null || echo "n/a"
}

echo ""
echo "############ summary ############"
printf "%-32s" "workload"
# shellcheck disable=SC2086
for mode in ${MODES}; do
    printf "%-36s" "${mode}"
done
printf "\n"
# shellcheck disable=SC2086
for name in ${WORKLOADS}; do
    printf "%-32s" "${name}"
    # shellcheck disable=SC2086
    for mode in ${MODES}; do
        printf "%-36s" "$(summarize "${RESULTS_DIR}/${mode}-${name}.json")"
    done
    printf "\n"
done
echo ""
echo "full fio output: ${RESULTS_DIR}"
