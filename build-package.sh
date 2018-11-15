#!/bin/bash

##
# Copyright IBM Corporation 2016,2017,2018
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##

# This script builds the Swift package on Travis CI.
# If running on the OS X platform, homebrew (http://brew.sh/) must be installed
# for this script to work.

# If any commands fail, we want the shell script to exit immediately.
set -e

DEFAULT_SWIFT=swift-4.0.3-RELEASE
docs=false

function usage {
  echo "Usage: build-package.sh -projectDir <project dir> [-credentialsDir <credentials dir>] [-docs]"
  echo -e "\t<project dir>: \t\tThe directory where the project resides."
  echo -e "\t<credentials dir>:\tThe directory where the test credentials reside. (optional)"
  exit 1
}

# Capture full command line in case we need to re-execute inside Docker
PACKAGE_BUILDER_ARGS="$*"

# Consume command line options
while [ $# -ne 0 ]
do
  case "$1" in
    -projectDir)
      shift
      projectBuildDir=$1
      ;;
    -credentialsDir)
      shift
      credentialsDir=$1
      ;;
    -docs)
      docs=true
      ;;
  esac
  shift
done

if [ -z "$projectBuildDir" ]; then
  usage
fi

# Determine location of this script
# Ref: https://stackoverflow.com/questions/59895/getting-the-source-directory-of-a-bash-script-from-within
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Utility functions
function sourceScript () {
  if [ -e "$1" ]; then
    source "$1"
    echo ">> Completed ${2}."
  fi
}

# If we have been asked to run within a Docker image, pull the image, then execute
# this script within the container.
#
# Note: environment variables must be explicitly propagated to the container. The
# ones we currently recognize are:
#
# - SWIFT_SNAPSHOT: the Swift toolchain to be used,
# - KITURA_NIO: an optional compilation mode switch for Kitura,
# - GCD_ASYNCH: an optional compilation mode switch for Kitura-net,
# - TESTDB_NAME: the name of a database to be accessed during the build.
#
if [ -n "${DOCKER_IMAGE}" ]; then
  echo ">> Executing build in Docker container: ${DOCKER_IMAGE}"
  # Define default env vars to be passed to docker
  docker_env_vars="--env SWIFT_SNAPSHOT --env KITURA_NIO --env GCD_ASYNCH --env TESTDB_NAME"
  # Pass additional vars listed by DOCKER_ENVIRONMENT
  for DOCKER_ENV_VAR in $DOCKER_ENVIRONMENT; do
    docker_env_vars="$docker_env_vars --env $DOCKER_ENV_VAR"
  done
  # Define default packages to install within docker image.
  # Install additional packages listed by DOCKER_PACKAGES
  docker_pkg_list="git sudo lsb-release wget libxml2 pkg-config libpq-dev $DOCKER_PACKAGES"
  set -x
  docker pull ${DOCKER_IMAGE}
  docker run ${docker_env_vars} -v ${projectBuildDir}:${projectBuildDir} ${DOCKER_IMAGE} /bin/bash -c "apt-get update && apt-get install -y ${docker_pkg_list} && cd $projectBuildDir && ./Package-Builder/build-package.sh ${PACKAGE_BUILDER_ARGS}"
  set +x
  DOCKER_RC=$?
  echo ">> Docker execution complete, RC=${DOCKER_RC}"
  exit ${DOCKER_RC}
fi

# Determine platform/OS and project name
echo ">> uname: $(uname)"
if [ "$(uname)" == "Darwin" ]; then
  osName="osx"
elif [ "$(expr substr $(uname -s) 1 5)" == "Linux" ]; then
  osName="linux"
else
  echo ">> Unsupported platform!"
  exit 1
fi
echo ">> osName: $osName"

cd "$(dirname "$0")"/..
export projectFolder=`pwd`
projectName="$(basename $projectFolder)"
echo ">> projectName: $projectName"

# Install libressl on osx
if [ "${osName}" == "osx" ]; then
  echo ">> Installing libressl..."
  brew update
  brew install libressl
  echo ">> Finished installing libressl."

  if [ -n "${SONARCLOUD_ELIGIBLE}" ]; then
    echo ">> Installing sonar-scanner..."
    brew install sonar-scanner
    echo ">> Finished installing sonar-scanner."
  fi
fi

# Install swift binaries based on OS
source ${SCRIPT_DIR}/install-swift.sh

# Show path
echo ">> PATH: $PATH"
echo

# Build swift package
echo ">> Building Swift package..."

cd ${projectFolder}

if [ -n "${CUSTOM_BUILD_SCRIPT}" ] && [ -e ${projectFolder}/$CUSTOM_BUILD_SCRIPT ]; then
  echo Running custom build command: `cat ${projectFolder}/$CUSTOM_BUILD_SCRIPT`
  source ${projectFolder}/$CUSTOM_BUILD_SCRIPT
elif [ -e ${projectFolder}/.swift-build-macOS ] && [ "${osName}" == "osx" ]; then
  echo Running custom macOS build command: `cat ${projectFolder}/.swift-build-macOS`
  source ${projectFolder}/.swift-build-macOS
elif [ -e ${projectFolder}/.swift-build-linux ] && [ "${osName}" == "linux" ]; then
  echo Running custom Linux build command: `cat ${projectFolder}/.swift-build-linux`
  source ${projectFolder}/.swift-build-linux
else
  swift build
fi

echo ">> Finished building Swift package."

# Copy test credentials for project if available
if [ -e "${credentialsDir}" ]; then
  echo ">> Found folder with test credentials."

  # Copy test credentials over
  echo ">> copying ${credentialsDir} to ${projectBuildDir}"
  cp -RP ${credentialsDir}/* ${projectBuildDir}
else
  echo ">> No folder found with test credentials."
fi

# Execute test cases
if [ -e "${projectFolder}/Tests" ]; then
    echo ">> Testing Swift package..."
    # Execute OS specific pre-test steps
    sourceScript "`find ${projectFolder} -path "*/${projectName}/${osName}/before_tests.sh" -not -path "*/Package-Builder/*" -not -path "*/Packages/*"`" "${osName} pre-tests steps"

    # Execute common pre-test steps
    sourceScript "`find ${projectFolder} -path "*/${projectName}/common/before_tests.sh" -not -path "*/Package-Builder/*" -not -path "*/Packages/*"`" "common pre-tests steps"

    source ${SCRIPT_DIR}/run_tests.sh

    # Execute common post-test steps
    sourceScript "`find ${projectFolder} -path "*/${projectName}/common/after_tests.sh" -not -path "*/Package-Builder/*" -not -path "*/Packages/*"`" "common post-tests steps"

    # Execute OS specific post-test steps
    sourceScript "`find ${projectFolder} -path "*/${projectName}/${osName}/after_tests.sh" -not -path "*/Package-Builder/*" -not -path "*/Packages/*"`" "${osName} post-tests steps"

    echo ">> Finished testing Swift package."
    echo
else
    echo ">> No test cases found."
fi

# Run SwiftLint to ensure Swift style and conventions (macOS)
if [ "$(uname)" == "Darwin" ]; then
  # Is the repository overriding the default swiftlint file in pacakge builder?
  if [ -e "${projectFolder}/.swiftlint.yml" ]; then
    # Determine whether custom swiftlint contains "excluded:" section
    if ! grep -q "excluded:" ${projectFolder}/.swiftlint.yml; then    # Add "excluded:"" section to .swiftlint.yml
      echo "excluded:" >> ${projectFolder}/.swiftlint.yml
    fi
    # Add "  - Package-Builder" to section
    sed -i '' 's/excluded:/excluded:\
  - Package-Builder/g' ${projectFolder}/.swiftlint.yml

    # Print linter version
    echo "Running linter swiftlint version $(swiftlint version)"

    swiftlint lint --quiet --config ${projectFolder}/.swiftlint.yml
  #else
  #swiftlint lint --quiet --config ${projectFolder}/Package-Builder/.swiftlint.yml
  fi
fi

# Codecov.io
# Generate test code coverage report (macOS). The Travis build must have the
# CODECOV_ELIGIBLE environment variable defined.
if [ "$(uname)" == "Darwin" -a -n "${CODECOV_ELIGIBLE}" ]; then
  if [ -e ${projectFolder}/.swift-codecov ]; then
      source ${projectFolder}/.swift-codecov
  else
      sourceScript "${SCRIPT_DIR}/codecov.sh" "codecov generation"
  fi
fi

# SonarCloud
# Generate test code coverage report (macOS). The Travis build must have the
# SONARCLOUD_ELIGIBLE environment variable defined.
if [ "$(uname)" == "Darwin" -a -n "${SONARCLOUD_ELIGIBLE}" ]; then
  if [ -e ${projectFolder}/.swift-sonarcloud ]; then
      source ${projectFolder}/.swift-sonarcloud
  else
      sourceScript "${SCRIPT_DIR}/sonarcloud.sh" "sonarcloud generation"
  fi
fi

# Generate jazzy docs (macOS) for Pull Requests that have the 'jazzy-doc' label.
# The docs will be generated and pushed as a new [ci skip] commit to the PR branch.
#
# Suitable credentials are required for this purpose. These should be defined in
# the repo's Travis configuration as GITHUB_USERNAME and GITHUB_PASSWORD.
#
# Additionally, the Travis build must have the JAZZY_ELIGIBLE environment variable
# defined, and this should be defined on only one macOS build, to ensure that only
# one build (per commit) produces a documentation commit.
#
if [ "$(uname)" == "Darwin" -a "${TRAVIS_PULL_REQUEST}" != "false" -a -n "${JAZZY_ELIGIBLE}" ]; then
  if [ "${TRAVIS_PULL_REQUEST_SLUG}" == "${TRAVIS_REPO_SLUG}" ]; then
    if  [ -n "${GITHUB_USERNAME}" -a -n "${GITHUB_PASSWORD}" ]; then
        echo "Checking PR for docs generation tag"
        # Obtain the label information for this PR from the GitHub. This is a JSON document describing each label
        jsonResponse=`curl -s -X GET https://${GITHUB_USERNAME}:${GITHUB_PASSWORD}@api.github.com/repos/${TRAVIS_REPO_SLUG}/issues/${TRAVIS_PULL_REQUEST}/labels`
        echo "Label data retrieved: $jsonResponse"
        # We require only the text of the label - filter on the "name" attribute
        labelNames=`echo "$jsonResponse" | grep '"name"' || true`
        # Extract the label name from the "name": "value" pair. This assumes each pair is on a separate line
        candidateTags=`echo "$labelNames" | sed -e's#.*"name" *: *"\([^"]*\)".*#\1#'`
        echo "Labels: " $candidateTags
        # Check if any of the labels contain the text 'jazzy-doc'
        if [[ $candidateTags == *"jazzy-doc"* ]]; then
            echo "Documentation tag jazzy-doc exists for this repo"
            sourceScript "${SCRIPT_DIR}/jazzy.sh" "jazzy-doc generation"
        else
            echo "Note: No jazzy-doc tag found."
        fi

    else
        echo "Error: Expected GITHUB_USERNAME && GITHUB_PASSWORD Env variables."
    fi
  else
      echo "Error: jazzy-doc generation cannot be performed from a fork."
  fi
else
    echo "Note: Build not eligible for jazzy doc generation."
fi

# Clean up build artifacts
# If at some point we integrate this script in a toolchain/pipeline,
# we will need to resurrect the code below
#rm -rf ${projectFolder}/.build
#rm -rf ${projectFolder}/Packages
#rm -rf ${projectFolder}/${SWIFT_SNAPSHOT}-${UBUNTU_VERSION}
# Clean up build artifacts
