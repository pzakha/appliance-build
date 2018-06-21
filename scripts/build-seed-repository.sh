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

function list_essential_pkgs
{
	aptitude search \
		'?essential' \
		'?priority(required)' \
		--display-format '%p'
}

function germinate_seed_pkgs
{
	local TMP_DIRECTORY=$(mktemp -d -p "$PWD" tmp.germinate.XXXXXXXXXX)

	pushd "$TMP_DIRECTORY" &>/dev/null

	mkdir -p ubuntu.bionic
	touch ubuntu.bionic/blacklist
	touch ubuntu.bionic/seeds
	echo "seeds:" > ubuntu.bionic/STRUCTURE

	while read pkg; do
		echo " * $pkg" >> ubuntu.bionic/seeds
	done

	germinate --seed-source . \
		--arch amd64 \
		--components main,restricted,universe,multiverse \
		--mirror http://archive.ubuntu.com/ubuntu \
		--mirror http://security.ubuntu.com/ubuntu \
		--mirror http://localhost:8080 \
		&>"$TMP_DIRECTORY/germinate.output"

	tail -n +3 seeds | head -n -2 | cut -d '|' -f 1

	popd &>/dev/null
	#rm -rf "$TMP_DIRECTORY"
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

function download_delphix_s3_debs
{
	local DOWNLOAD_DIR="$1"
	local S3_URI="$2"

	local TMP_DIRECTORY=$(mktemp -d -p "$PWD" tmp.s3-debs.XXXXXXXXXX)
	pushd "$TMP_DIRECTORY" &>/dev/null

	aws s3 sync --only-show-errors "$S3_URI" .
	sha256sum -c --strict SHA256SUMS

	mv *.deb "$DOWNLOAD_DIR/"

	popd &>/dev/null
	rm -rf "$TMP_DIRECTORY"
}

function download_delphix_java8_debs
{
	local DOWNLOAD_DIR="$1"

	local URL="http://artifactory.delphix.com/artifactory"
	local TARFILE="jdk-8u131-linux-x64.tar.gz"
	local JCEFILE="jce_policy-8.zip"
	local DEBFILE="oracle-java8-jdk_8u131_amd64.deb"

	local TMP_DIRECTORY=$(mktemp -d -p "$PWD" tmp.java.XXXXXXXXXX)
	pushd "$TMP_DIRECTORY" &>/dev/null

	wget -nv "$URL/java-binaries/linux/jdk/8/$TARFILE" -O "$TARFILE"
	wget -nv "$URL/java-binaries/jce/$JCEFILE" -O "$JCEFILE"

	#
	# We must run "make-jpkg" as a non-root user, and then use "fakeroot".
	#
	# If we "make-jpkg" it as the real root user, it will fail; and if we
	# run it as a non-root user, it will also fail.
	#
	chown -R nobody:nogroup .
	runuser -u nobody -- \
		fakeroot make-jpkg --jce-policy "$JCEFILE" "$TARFILE" <<< y

	chown root:root "$DEBFILE"
	cp "$DEBFILE" "$DOWNLOAD_DIR"

	popd &>/dev/null
	rm -rf "$TMP_DIRECTORY"
}

function aptly_serve
{
	aptly serve &
	echo $! > /tmp/aptly_serve.pid

	local url="http://localhost:8080/dists/bionic/Release"
	local attempts=0

	while ! curl --output /dev/null --silent --head --fail "$url"; do
		sleep 1
		(( attempts = attempts + 1 ))
		if [[ $attempts -gt 10 ]]; then
			echo "Error: aptly serve timeout"
			aptly_stop_serving
			exit 1
		fi
	done
}

function aptly_stop_serving
{
	if [[ -f /tmp/aptly_serve.pid ]]; then
		kill $(cat /tmp/aptly_serve.pid)
		rm /tmp/aptly_serve.pid
	fi
}

TOP=$(git rev-parse --show-toplevel 2>/dev/null)

if [[ -z "$TOP" ]]; then
	echo "Must be run inside the git repsitory."
	exit 1
fi

set -o xtrace
set -o errexit
set -o pipefail

TMP_DIRECTORY=$(mktemp -d -p "$PWD" tmp.pkgs.XXXXXXXXXX)
DELPHIX_DEBS="$TMP_DIRECTORY/delphix-debs"
ALL_DEBS="$TMP_DIRECTORY/all-debs"
COMPONENTS="$TMP_DIRECTORY/components"
mkdir "$DELPHIX_DEBS" "$ALL_DEBS"

apt-get update

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
# Create an aptly repository to hold our downloaded debs. This repository
# will be first used by germinate to gather the dependencies of those debs
# and then by apt when downloading the debs.
# Note, we must use component=main here since for each component germinate
# expects to find at least one repository that has source packages
# (i.e. <repo>/dists/bionic/<component>/source/Sources.* must exist), but
# we do not publish any source packages for delphix debs.
#
rm -rf ~/.aptly
aptly repo create -distribution=bionic -component=main delphix-debs

mv "$TOP/delphix-foundation_1.0.0_amd64.deb" "$DELPHIX_DEBS/"
echo "delphix-foundation" >> "$COMPONENTS"

#
# When performing minimal testing from within Travis CI, we won't have
# access to the Delphix internal infrastructure. Thus, we want to skip
# the logic below, as it would otherwise fail when running in Travis.
# The assumption being, we will never attempt to build a variant that
# dependends on the Delphix S3 packages, when running in Travis.
#
if ! [[ -n "$CI" && -n "$TRAVIS" ]]; then
	if [[ -n "$AWS_S3_URI_JAVA" ]]; then
		download_delphix_s3_debs "$DELPHIX_DEBS" "$AWS_S3_URI_JAVA"
	else
		download_delphix_java8_debs "$DELPHIX_DEBS"
	fi
	echo "oracle-java8-jdk" >> "$COMPONENTS"
	if [[ -n "$AWS_S3_URI_VIRTUALIZATION" ]]; then
		download_delphix_s3_debs "$DELPHIX_DEBS" "$AWS_S3_URI_VIRTUALIZATION"
		echo "delphix-virtualization" >> "$COMPONENTS"
	fi
	if [[ -n "$AWS_S3_URI_MASKING" ]]; then
		download_delphix_s3_debs "$DELPHIX_DEBS" "$AWS_S3_URI_MASKING"
		echo "delphix-masking" >> "$COMPONENTS"
	fi
	if [[ -n "$AWS_S3_URI_ZFS" ]]; then
		download_delphix_s3_debs "$DELPHIX_DEBS" "$AWS_S3_URI_ZFS"
		echo "delphix-zfs" >> "$COMPONENTS"
	fi
fi

aptly repo add delphix-debs "$DELPHIX_DEBS"
aptly publish repo -passphrase=delphix delphix-debs
aptly_serve

apt-key add "$TOP/live-build/misc/live-build-hooks/misc/dlpx-test-pub.gpg"
apt-add-repository "deb http://localhost:8080 bionic main"

#
# Add extra repositories
#
pushd "$TOP/live-build/base/config/archives/"
for key in *.key; do
	apt-key add "$key"
done
for list in *.list; do
	grep -e '^deb' "$list" | while read source; do
		apt-add-repository "$source"
	done
done
popd

#
# Before we attempt to fetch any of the packages, we want to ensure our
# apt cache is up-to-date; otherwise we could fetch old packages, or
# simply not find any packages to fetch because the cache is empty.
#
apt-get update

#
# Download recursive dependencies for all pacakges
#
cat "$COMPONENTS" | germinate_seed_pkgs | download_pkgs "$ALL_DEBS"

#
# We don't need our temporary repository anymore since all the delphix
# packages should now be in "$ALL_DEBS"
#
aptly_stop_serving
apt-add-repository --remove "deb http://localhost:8080 bionic main"

#
# Next, we need to ensure we download and include all essential
# packages, since these are necessary for a working system, but are not
# necessarily listed as dependencies of our foundation; e.g. coreutils.
#
list_essential_pkgs | download_pkgs "$ALL_DEBS"

#
# Lastly, there's some additional packages that we need to include, as
# these are required by our live-build execution environment.
#
cat <<EOF | germinate_seed_pkgs | download_pkgs "$ALL_DEBS"
dctrl-tools
python3-apt
EOF

#
# After downloading the packages, the package filenames any have the
# sequence of characters "%3a" embedded in them. These characters cause
# problems when the files are exported over HTTP via the Aptly served
# repository. Thus, we convert this sequence back to the original ":"
# character (which is what the sequence represents) as a workaround, so
# the files can be properly served by Aptly.
#
rename 's/\%3a/:/g' "$ALL_DEBS"/*.deb

#
# And now, we can create the Aptly repository using all of the .deb
# packages that were download previously, plus our metapackages.
#
rm -rf ~/.aptly
aptly repo create -distribution=bionic -component=delphix seed-repository
aptly repo add seed-repository "$ALL_DEBS"
aptly publish repo -passphrase=delphix seed-repository

tar -czf "$TOP/artifacts/seed-repository.tar.gz" -C ~/.aptly .

#rm -rf "$TMP_DIRECTORY"
