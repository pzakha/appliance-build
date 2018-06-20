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

function list_depends_of_deb
{
	dpkg -I "$TOP/delphix-foundation_1.0.0_amd64.deb" |
		grep Depends |
		cut -d ':' -f 2 |
		tr -d '[:blank:]' |
		tr ',' '\n'
}

function list_essential_pkgs
{
	aptitude search \
		'?essential' \
		'?priority(required)' \
		--display-format '%p'
}

function germinate_seed_pkgs
{
	local TMP_DIRECTORY=$(mktemp -d -p . tmp.germinate.XXXXXXXXXX)

	pushd "$TMP_DIRECTORY" &>/dev/null

	mkdir -p ubuntu.bionic
	touch ubuntu.bionic/blacklist
	touch ubuntu.bionic/seeds
	echo "seeds:" > ubuntu.bionic/STRUCTURE

	while read pkg; do
		echo " * $pkg" >> ubuntu.bionic/seeds
	done

	germinate -S . \
		-c main,restricted,universe,multiverse \
		-m http://archive.ubuntu.com/ubuntu \
		-m http://security.ubuntu.com/ubuntu \
		1>&2

	tail -n +3 seeds | head -n -2 | cut -d '|' -f 1

	popd &>/dev/null
	rm -rf "$TMP_DIRECTORY"
}

function download_pkgs
{
	xargs apt-get \
		-o Dir::Cache::Archives="$1" \
		--download-only \
		--assume-yes \
		--reinstall \
		install
}

TOP=$(git rev-parse --show-toplevel 2>/dev/null)

if [[ -z "$TOP" ]]; then
	echo "Must be run inside the git repsitory."
	exit 1
fi

set -o nounset
set -o errexit
set -o pipefail

TMP_DIRECTORY=$(mktemp -d -p . tmp.deps.XXXXXXXXXX)

#
# Before we attempt to fetch any of the packages, we want to ensure our
# apt cache is up-to-date; otherwise we could fetch old packages, or
# simply not find any packages to fetch because the cache is empty.
#
apt-get update

#
# First, we want to download all recursive dependencies for our
# foundation package.
#
list_depends_of_deb "$TOP/delphix-foundation_1.0.0_amd64.deb" |
	germinate_seed_pkgs |
	download_pkgs "$TMP_DIRECTORY"

#
# Next, we need to ensure we download and include all essential
# packages, since these are necessary for a working system, but are not
# necessarily listed as dependencies of our foundation; e.g. coreutils.
#
list_essential_pkgs | download_pkgs "$TMP_DIRECTORY"

#
# Lastly, we need to include the "dctrl-tools" package, since this is a
# requirement of live-build, and is necessary to use the seed-repository
# as the bootstrap-mirror input to live-build
#
echo "dctrl-tools" | download_pkgs "$TMP_DIRECTORY"

#
# After downloading the packages, the package filenames any have the
# sequence of characters "%3a" embedded in them. These characters cause
# problems when the files are exported over HTTP via the Aptly served
# repository. Thus, we convert this sequence back to the original ":"
# character (which is what the sequence represents) as a workaround, so
# the files can be properly served by Aptly.
#
rename 's/\%3a/:/g' "$TMP_DIRECTORY"/*.deb

#
# Until we can confirm otherwise, the Aptly repository needs to be signed
# in order for us to use it as the bootstrap mirror to live-build. Thus,
# we need to configure GPG so that we can later use it to sign the Aptly
# repository.
#
gpg --import --batch --passphrase delphix \
	$TOP/live-build/misc/live-build-hooks/misc/dlpx-test-priv.gpg

cat >"$HOME/.gnupg/gpg.conf" <<EOF
use-agent
pinentry-mode loopback
default-key "Delphix Test"
EOF

echo "allow-loopback-pinentry" >"$HOME/.gnupg/gpg-agent.conf"

#
# And now, we can create the Aptly repository using all of the .deb
# packages that were download previously, plus our metapackages.
#

rm -rf ~/.aptly
aptly repo create -distribution=bionic -component=delphix seed-repository

aptly repo add seed-repository "$TMP_DIRECTORY"
aptly repo add seed-repository "$TOP/delphix-foundation_1.0.0_amd64.deb"

aptly snapshot create seed-repository-snapshot from repo seed-repository
aptly publish snapshot -passphrase=delphix seed-repository-snapshot

tar -czf "$TOP/artifacts/seed-repository.tar.gz" -C ~/.aptly .

rm -rf "$TMP_DIRECTORY"
