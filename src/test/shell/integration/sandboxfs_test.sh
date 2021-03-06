#!/bin/bash
# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CURRENT_DIR}/../integration_test_setup.sh" \
  || { echo "integration_test_setup.sh not found!" >&2; exit 1; }

# Bazel build arguments to disable the use of the sandbox.  We have tests below
# that configure a fake sandboxfs and they would fail if they were to use it.
DISABLE_SANDBOX_ARGS=(
  --genrule_strategy=local
  --spawn_strategy=local
)

# Creates a fake sandboxfs process in "path" that logs interactions with it in
# the given "log" file.
function create_fake_sandboxfs() {
  local path="${1}"; shift
  local log="${1}"; shift

  cat >"${path}" <<EOF
#! /bin/sh

rm -f "${log}"
trap 'echo "Terminated" >>"${log}"' EXIT TERM

echo "PID: \${$}" >>"${log}"
echo "ARGS: \${*}" >>"${log}"

while read line; do
  echo "Received: \${line}" >>"${log}"
  if [ -z "\${line}" ]; then
    echo "Done"
  fi
done
EOF
  chmod +x "${path}"
}

function create_hello_package() {
  mkdir -p hello

  cat >hello/BUILD <<EOF
cc_binary(name = "hello", srcs = ["hello.cc"])
EOF

  cat >hello/hello.cc <<EOF
#include <stdio.h>
int main(void) { printf("Hello, world!\n"); return 0; }
EOF
}

function test_default_sandboxfs_from_path() {
  mkdir -p fake-tools
  create_fake_sandboxfs fake-tools/sandboxfs "$(pwd)/log"
  PATH="$(pwd)/fake-tools:${PATH}"; export PATH

  create_hello_package

  # This test relies on a PATH change that is only recognized when the server
  # first starts up, so ensure there are no Bazel servers left behind.
  #
  # TODO(philwo): This is awful.  The testing infrastructure should ensure
  # that tests cannot pollute each other's state, but at the moment that's not
  # the case.
  bazel shutdown

  bazel build \
    "${DISABLE_SANDBOX_ARGS[@]}" \
    --experimental_use_sandboxfs \
    //hello >"${TEST_log}" 2>&1 || fail "Build should have succeeded"

  # Dump fake sandboxfs' log for debugging.
  sed -e 's,^,SANDBOXFS: ,' log >>"${TEST_log}"

  grep -q "Terminated" log \
    || fail "sandboxfs process was not terminated (not executed?)"
}

function test_explicit_sandboxfs_not_found() {
  create_hello_package

  bazel build \
    --experimental_use_sandboxfs \
    --experimental_sandboxfs_path="/non-existent/sandboxfs" \
    //hello >"${TEST_log}" 2>&1 && fail "Build succeeded but should have failed"

  expect_log "Failed to initialize sandbox: .*Cannot run .*/non-existent/"
}

function test_mount_unmount() {
  create_fake_sandboxfs fake-sandboxfs.sh "$(pwd)/log"
  create_hello_package

  local output_base="$(bazel info output_base)"
  local sandbox_base="${output_base}/sandbox"

  bazel build \
    "${DISABLE_SANDBOX_ARGS[@]}" \
    --experimental_use_sandboxfs \
    --experimental_sandboxfs_path="$(pwd)/fake-sandboxfs.sh" \
    //hello >"${TEST_log}" 2>&1 || fail "Build should have succeeded"

  # Dump fake sandboxfs' log for debugging.
  sed -e 's,^,SANDBOXFS: ,' log >>"${TEST_log}"

  grep -q "ARGS: .*${sandbox_base}/sandboxfs" log \
    || fail "Cannot find expected mount point in sandboxfs mount call"
  grep -q "Terminated" log \
    || fail "sandboxfs process was not terminated (not unmounted?)"
}

function test_debug_lifecycle() {
  create_fake_sandboxfs fake-sandboxfs.sh "$(pwd)/log"
  create_hello_package

  function build() {
    bazel build \
      "${DISABLE_SANDBOX_ARGS[@]}" \
      --experimental_use_sandboxfs \
      --experimental_sandboxfs_path="$(pwd)/fake-sandboxfs.sh" \
      "${@}" \
      //hello >"${TEST_log}" 2>&1 || fail "Build should have succeeded"

      # Dump fake sandboxfs' log for debugging.
      sed -e 's,^,SANDBOXFS: ,' log >>"${TEST_log}"
  }

  function sandboxfs_pid() {
    case "$(uname)" in
      Darwin)
        # We cannot use ps to look for the sandbox process because this is
        # not allowed when running with macOS's App Sandboxing.
        grep -q "Terminated" log && return
        grep "^PID:" log | awk '{print $2}'
        ;;

      *)
        # We could use the same approach we follow on Darwin to look for the
        # PID of the subprocess, but it's better if we look at the real
        # process table if we are able to.
        ps ax | grep [f]ake-sandboxfs | awk '{print $1}'
        ;;
    esac
  }

  # Want sandboxfs to be left mounted after a build with debugging on.
  build --sandbox_debug
  grep -q "ARGS:" log || fail "sandboxfs was not run"
  grep -q "Terminated" log \
    && fail "sandboxfs process was terminated but should not have been"
  local pid1="$(sandboxfs_pid)"
  [[ -n "${pid1}" ]] || fail "sandboxfs process not found in process table"

  # Want sandboxfs to be restarted if the previous build had debugging on.
  build --sandbox_debug
  local pid2="$(sandboxfs_pid)"
  [[ -n "${pid2}" ]] || fail "sandboxfs process not found in process table"
  [[ "${pid1}" -ne "${pid2}" ]] || fail "sandboxfs was not restarted"

  # Want build to finish successfully and to clear the mount point.
  build --nosandbox_debug
  local pid3="$(sandboxfs_pid)"
  [[ -z "${pid3}" ]] || fail "sandboxfs was not terminated"
}

run_suite "sandboxfs-based sandboxing tests"
