#!/bin/bash
#
# Copyright 2018 Delphix
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

TOP=$(git rev-parse --show-toplevel 2>/dev/null)

if [[ -z "$TOP" ]]; then
	echo "Must be run inside the git repsitory."
	exit 1
fi

if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root." 1>&2
	exit 1
fi

if [[ $# -ne 1 ]]; then
	echo "Must specify a single live-build variant to run." 1>&2
	exit 1
fi

if [[ "$1" != "base" ]] && [[ ! -d "live-build/variants/$1" ]]; then
	echo "Invalid live-build variant specified: $1" 1>&2
	exit 1
fi

set -o errexit

#
# Allow the appliance username and password to be configured via these
# environment variables, but use sane defaults if they're missing.
#
export APPLIANCE_USERNAME="${APPLIANCE_USERNAME:-delphix}"
export APPLIANCE_PASSWORD="${APPLIANCE_PASSWORD:-delphix}"

#
# We need to be careful to set xtrace after we set the USERNAME and
# PASSWORD variables above; otherwise, we could leak the values of the
# environment variables to stdout (and captured in CI logs, etc.).
#
set -o xtrace

if [[ "$1" == "base" ]]; then
	export APPLIANCE_VARIANT="base"
	cd "$TOP/live-build/base"
else
	export APPLIANCE_VARIANT="$1"
	cd "$TOP/live-build/variants/$1"
fi

#
# TODO: Add some comments to explain what we're doing here. i.e. we want
# to use this artifact as the "seed repository" for live-build, such
# that live-build only pulls from this repository and not ubuntu's repo.
#
rm -rf ~/.aptly
mkdir -p ~/.aptly
tar -xzf "$TOP/artifacts/seed-repository.tar.gz" -C ~/.aptly
aptly serve &

lb config
export DEBOOTSTRAP_OPTIONS="--keyring=$TOP/live-build/misc/live-build-hooks/misc/dlpx-test-pub.gpg"
lb build

#
# On failure, the "lb build" command above doesn't actually return a
# non-zero exit code. This is problematic for users that rely on this
# return code to determine if the script failed or not. Thus, to
# workaround this limitation, we rely on a heuristic to try and
# determine if an error occured. We check for a specific file that's
# generated at the final stage of the build. If this file exists, then
# we assume the build succeeded; likewise, if it doesn't exist, we
# assume the build failed.
#
if [[ ! -f binary/SHA256SUMS ]]; then
	exit 1
fi

#
# The base variant doesn't produce any virtual machine artifacts, so we
# need to avoid the "mv" calls below.
#
if [[ "$APPLIANCE_VARIANT" == "base" ]]; then
	exit 0
fi

#
# After running the build successfully, it should have produced various
# virtual machine artifacts. We move these artifacts into a specific
# directory to make it easy for the artifacts to be consumed by the
# user (e.g. other software); this is most useful when multiple variants
# are built via a single call to "make" (e.g. using the "all" target).
#
for ext in ova qcow2 repo vhdx vmdk; do
	if [[ -f "$APPLIANCE_VARIANT.$ext" ]]; then
		mv "$APPLIANCE_VARIANT.$ext" "$TOP/artifacts"
	fi
done
