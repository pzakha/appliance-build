#!/bin/bash -ex
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

#
# Build a repository with Delphix packages that will be consumed by live-build.
# The repository will be stored in $TOP/delphix-repo.
#

TOP=$(git rev-parse --show-toplevel 2>/dev/null)

if [[ -z "$TOP" ]]; then
	echo "Must be run inside the git repsitory."
	exit 1
fi

. "$TOP/scripts/functions.sh"

function download_delphix_s3_debs
{
	local TARGET_DIR="$1"
	local S3_URI="$2"

	local TMP_DIRECTORY=$(mktemp -d -p "$PWD" tmp.s3-debs.XXXXXXXXXX)
	pushd "$TMP_DIRECTORY" &>/dev/null

	aws s3 sync --only-show-errors "$S3_URI" .
	sha256sum -c --strict SHA256SUMS

	mv *.deb "$TARGET_DIR/"

	popd &>/dev/null
	rm -rf "$TMP_DIRECTORY"
}

function resolve_s3_uri() {

	local def_bucket="snapshot-de-images"
	local jenkinsid="jenkins-ops"

	local uri="$1"
	local latest="s3://$def_bucket/builds/$jenkinsid/$2/post-push/latest"
	local resolved_uri

	if [[ -z "$uri" ]]; then
		#
		# uri is empty, so get latest version
		#
		aws s3 cp --quiet "$latest" .
		local prefix=$(cat latest)
		resolved_uri="s3://$def_bucket/$prefix"
		rm -f latest
	elif [[ "$uri" == s3* ]]; then
		#
		# uri was set to full s3 URL
		#
		resolved_uri="$uri"
	else
		#
		# We assume uri is a prefix inside default bucket
		#
		resolved_uri="s3://$def_bucket/$uri"
	fi

	if aws s3 ls "$resolved_uri" >/dev/null; then
		echo "$resolved_uri"
	else
		echo "$resolved_uri not found." 1>&2
		exit 1
	fi
}

function resolve_s3_uris() {
	AWS_S3_URI_VIRTUALIZATION=$(resolve_s3_uri "$AWS_S3_URI_VIRTUALIZATION" \
		"dlpx-app-gate/projects/dx4linux/build-package")

	AWS_S3_URI_MASKING=$(resolve_s3_uri "$AWS_S3_URI_MASKING" \
		"dms-core-gate/master/build-package")

	AWS_S3_URI_ZFS=$(resolve_s3_uri "$AWS_S3_URI_ZFS" \
		"devops-gate/projects/dx4linux/zfs-package-build/master")
}

function download_delphix_s3_debs()
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

function build_delphix_java8_debs()
{
	local TARGET_DIR="$1"

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
	cp "$DEBFILE" "$TARGET_DIR"

	popd &>/dev/null
	rm -rf "$TMP_DIRECTORY"
}

PKG_DIRECTORY=$(mktemp -d -p "$PWD" tmp.pkgs.XXXXX)

#
# Download all Delphix pacakges from s3
#
resolve_s3_uris
download_delphix_s3_debs "$PKG_DIRECTORY" "$AWS_S3_URI_VIRTUALIZATION"
download_delphix_s3_debs "$PKG_DIRECTORY" "$AWS_S3_URI_MASKING"
download_delphix_s3_debs "$PKG_DIRECTORY" "$AWS_S3_URI_ZFS"

#
# Normally we build Java on each run, however to make debugging faster we
# let the user supply a pre-built java package.
#
if [[ -n "$AWS_S3_URI_JAVA" ]]; then
	download_delphix_s3_debs "$PKG_DIRECTORY" "$AWS_S3_URI_JAVA"
else
	build_delphix_java8_debs "$PKG_DIRECTORY"
fi

#
# Create the aptly repository.
# Note that we must first setup a default gpg key that will be used to sign
# the repository.
#
setup_gpg_key "$TOP/keys/dlpx-test-priv.gpg"
rm -rf "$HOME/.aptly"
aptly repo create -distribution=bionic -component=main delphix-debs
aptly repo add delphix-debs "$PKG_DIRECTORY"
aptly publish repo -passphrase=delphix delphix-debs
mkdir -p "$TOP/delphix-repo"
mv "$HOME/.aptly" "$TOP/delphix-repo/"
cat <<-EOF >"$TOP/delphix-repo/aptly.config" 
	{
	  "rootDir": "$TOP/delphix-repo/.aptly"
	}
EOF

rm -rf "$PKG_DIRECTORY"
