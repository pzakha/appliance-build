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
	echo "Must be run inside the git repsitory." 2>&1
	exit 1
fi

. "$TOP/scripts/functions.sh"

set -o xtrace
set -o errexit
set -o pipefail

function resolve_s3_uri()
{
	local pkg_uri="$1"
	local pkg_prefix="$2"
	local latest_subprefix="$3"

	local bucket="snapshot-de-images"
	local jenkinsid="jenkins-ops"

	if [[ -n "$pkg_uri" ]]; then
		local resolved_uri="$pkg_uri"
	elif [[ "$pkg_prefix" == s3* ]]; then
		local resolved_uri="$pkg_prefix"
	elif [[ -n "$pkg_prefix" ]]; then
		local resolved_uri="s3://$bucket/$pkg_prefix"
	elif [[ -n "$latest_subprefix" ]]; then
		aws s3 cp --quiet \
			"s3://$bucket/builds/$jenkinsid/$latest_subprefix" .
		local resolved_uri="s3://$bucket/$(cat latest)"
		rm -f latest
	else
		echo "Invalid arguments provided to resolve_s3_uri()" 2>&1
		exit 1
	fi

	if aws s3 ls "$resolved_uri" &>/dev/null; then
		echo "$resolved_uri"
	else
		echo "'$resolved_uri' not found." 1>&2
		exit 1
	fi
}

function download_delphix_s3_debs()
{
	local pkg_directory="$1"
	local S3_URI="$2"

	local tmp_directory=$(mktemp -d -p "$PWD" tmp.s3-debs.XXXXXXXXXX)
	pushd "$tmp_directory" &>/dev/null

	aws s3 sync --only-show-errors "$S3_URI" .
	sha256sum -c --strict SHA256SUMS

	mv *.deb "$pkg_directory/"

	popd &>/dev/null
	rm -rf "$tmp_directory"
}

function build_delphix_java8_debs()
{
	local pkg_directory="$1"

	local url="http://artifactory.delphix.com/artifactory"
	local tarfile="jdk-8u131-linux-x64.tar.gz"
	local jcefile="jce_policy-8.zip"
	local debfile="oracle-java8-jdk_8u131_amd64.deb"

	local tmp_directory=$(mktemp -d -p "$PWD" tmp.java.XXXXXXXXXX)
	pushd "$tmp_directory" &>/dev/null

	wget -nv "$url/java-binaries/linux/jdk/8/$tarfile" -O "$tarfile"
	wget -nv "$url/java-binaries/jce/$jcefile" -O "$jcefile"

	#
	# We must run "make-jpkg" as a non-root user, and then use "fakeroot".
	#
	# If we "make-jpkg" it as the real root user, it will fail; and if we
	# run it as a non-root user, it will also fail.
	#
	chown -R nobody:nogroup .
	runuser -u nobody -- \
		fakeroot make-jpkg --jce-policy "$jcefile" "$tarfile" <<< y

	cp "$debfile" "$pkg_directory"

	popd &>/dev/null
	rm -rf "$tmp_directory"
}

function build_ancillary_repository()
{
	local pkg_directory="$1"

	setup_gpg_key "$TOP/keys/dlpx-test-priv.gpg"

	rm -rf "$HOME/.aptly"
	aptly repo create \
		-distribution=bionic -component=main ancillary-repository
	aptly repo add ancillary-repository "$pkg_directory"
	aptly publish repo -passphrase delphix ancillary-repository

	rm -rf "$TOP/ancillary-repository"
	mv "$HOME/.aptly" "$TOP/ancillary-repository"
	cat > "$TOP/ancillary-repository/aptly.config" <<-EOF
	{
	    "rootDir": "$TOP/ancillary-repository"
	}
	EOF
}

AWS_S3_URI_VIRTUALIZATION=$(resolve_s3_uri \
	"$AWS_S3_URI_VIRTUALIZATION" \
	"$AWS_S3_PREFIX_VIRTUALIZATION" \
	"dlpx-app-gate/projects/dx4linux/build-package/post-push/latest")

AWS_S3_URI_MASKING=$(resolve_s3_uri \
	"$AWS_S3_URI_MASKING" \
	"$AWS_S3_PREFIX_MASKING" \
	"dms-core-gate/master/build-package/post-push/latest")

AWS_S3_URI_ZFS=$(resolve_s3_uri \
	"$AWS_S3_URI_ZFS" \
	"$AWS_S3_PREFIX_ZFS" \
	"devops-gate/projects/dx4linux/zfs-package-build/master/post-push/latest")

PKG_DIRECTORY=$(mktemp -d -p "$PWD" tmp.pkgs.XXXXXXXXXX)

download_delphix_s3_debs "$PKG_DIRECTORY" "$AWS_S3_URI_VIRTUALIZATION"
download_delphix_s3_debs "$PKG_DIRECTORY" "$AWS_S3_URI_MASKING"
download_delphix_s3_debs "$PKG_DIRECTORY" "$AWS_S3_URI_ZFS"
build_delphix_java8_debs "$PKG_DIRECTORY"

build_ancillary_repository "$PKG_DIRECTORY"

rm -rf "$PKG_DIRECTORY"
