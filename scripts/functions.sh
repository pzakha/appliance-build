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

function aptly_serve
{
	aptly serve &
	echo $! > /run/aptly_serve.pid

	#
	# We need to wait for the Aptly server to be ready before we proceed;
	# this can take a few seconds, so we retry until it succeeds.
	#
	local url="http://localhost:8080/dists/bionic/Release"
	local attempts=0
	while ! curl --output /dev/null --silent --head --fail "$url"; do
		sleep 1
		(( attempts = attempts + 1 ))
		if [[ $attempts -gt 30 ]]; then
			echo "Error: aptly serve timeout"
			aptly_stop_serving
			exit 1
		fi
	done
}

function aptly_stop_serving
{
	if [[ -f /run/aptly_serve.pid ]]; then
		kill $(cat /run/aptly_serve.pid)
		rm /run/aptly_serve.pid
	fi
}
