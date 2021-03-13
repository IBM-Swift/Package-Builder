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

# Import local copy of Travis timing / folding functions (this enables us to
# produce Travis folded output from within a Docker container)
# Source: https://github.com/travis-ci/travis-build/tree/master/lib/travis/build/bash
source ${SCRIPT_DIR}/lib/travis_fold.bash
source ${SCRIPT_DIR}/lib/travis_nanoseconds.bash
source ${SCRIPT_DIR}/lib/travis_time_start.bash
source ${SCRIPT_DIR}/lib/travis_time_finish.bash

# Utility functions
function sourceScript () {
  if [ -e "$1" ]; then
    source "$1"
    echo ">> Completed ${2}."
  fi
}

function travis_start () {
  export TRAVIS_CURRENT_SECTION=$1
  travis_fold start ${TRAVIS_CURRENT_SECTION}
  travis_time_start
}

function travis_end () {
  travis_time_finish
  travis_fold end ${TRAVIS_CURRENT_SECTION}
}

# If we have been asked to run within a Docker image, pull the image, then execute
# this script within the container.
#
# Note: environment variables must be explicitly propagated to the container. The
# ones we currently recognize are:
# - SWIFT_SNAPSHOT: the Swift toolchain to be used,
# - KITURA_NIO: an optional compilation mode switch for Kitura.
#
# Additional env vars can be passed by listing them in DOCKER_ENVIRONMENT.
#
# Within the Docker image, we will install some default system packages:
# - git, sudo and wget are required by Package-Builder itself.
# - pkg-config is required by SwiftPM to locate .pc files (see https://github.com/apple/swift-package-manager/pull/338).
#
# Additional packages can be installed by listing them in DOCKER_PACKAGES.
#
if [ -n "${DOCKER_IMAGE}" ]; then
  echo ">> Executing build in Docker container: ${DOCKER_IMAGE}"
  # Check if privileged mode has been requested for
  if [ -n "${DOCKER_PRIVILEGED}" ]; then
    docker_run_privileged="--privileged"
  fi
  # Define list of env vars to be passed to docker.
  docker_env_vars="--env SWIFT_SNAPSHOT --env KITURA_NIO --env CUSTOM_BUILD_SCRIPT --env CUSTOM_TEST_SCRIPT --env SWIFT_TEST_ARGS"
  # Pass additional vars listed by DOCKER_ENVIRONMENT
  for DOCKER_ENV_VAR in $DOCKER_ENVIRONMENT; do
    docker_env_vars="$docker_env_vars --env $DOCKER_ENV_VAR"
  done
  # Define list of packages to install within docker image.
  docker_pkg_list="git sudo wget pkg-config libcurl4-openssl-dev libssl-dev $DOCKER_PACKAGES"
  # Temporary fix for Swift 5.0.1 images that ship Python modules in a conflicting directory
  # See: https://bugs.swift.org/browse/SR-10591
  docker_python_fix="if [ -d "/usr/lib/python2.7/site-packages" ]; then mv /usr/lib/python2.7/site-packages/* /usr/lib/python2.7/dist-packages && rmdir /usr/lib/python2.7/site-packages && ln -s dist-packages /usr/lib/python2.7/site-packages ; fi"

  travis_start "docker_pull"
  docker pull ${DOCKER_IMAGE}
  travis_end

  # Invoke Package-Builder within the Docker image.
  # Start by installing dependencies and tag a new image locally. This enables us to travis_fold
  # all the apt-get noise.
  travis_start "docker_image_setup"
  set -x
  docker run ${docker_run_privileged} ${docker_env_vars} -v ${projectBuildDir}:${projectBuildDir} --name packagebuildercontainer ${DOCKER_IMAGE} /bin/bash -c "$docker_python_fix && apt-get update && apt-get install -y ${docker_pkg_list}"
  docker commit packagebuildercontainer packagebuilderimage
  docker container rm packagebuildercontainer
  set +x
  travis_end
  # Run Package-Builder within the new image.
  set -x
  docker run -v ${projectBuildDir}:${projectBuildDir} --name packagebuilderrun packagebuilderimage /bin/bash -c "cd $projectBuildDir && ./Package-Builder/build-package.sh ${PACKAGE_BUILDER_ARGS}"
  docker container rm packagebuilderrun
  docker image rm packagebuilderimage
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

if [ "${osName}" == "osx" ]; then
  # BREW_INSTALL_PACKAGES is expected to have a whitespace-separated list of all packages that need to be installed
  if [ -n "${BREW_INSTALL_PACKAGES}" ]; then
    travis_start "brew_update"
    brew update
    travis_end
    travis_start "brew_install"
    for PACKAGE in ${BREW_INSTALL_PACKAGES}; do
      echo ">> Installing ${PACKAGE}..."
      brew install ${PACKAGE}
      echo ">> Finished installing ${PACKAGE}."
    done
    travis_end
  fi

  if [ -n "${SONARCLOUD_ELIGIBLE}" ]; then
    echo ">> Installing sonar-scanner..."
    brew install sonar-scanner
    echo ">> Finished installing sonar-scanner."
  fi
fi

# Install swift binaries based on OS
travis_start "install_swift"
source ${SCRIPT_DIR}/install-swift.sh
travis_end

# Show path
echo ">> PATH: $PATH"
echo

# Build swift package
travis_start "swift_build"
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
travis_end

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
    travis_start "swift_pre_test"
    echo ">> Testing Swift package..."
    # Execute OS specific pre-test steps
    sourceScript "`find ${projectFolder} -path "*/${projectName}/${osName}/before_tests.sh" -not -path "*/Package-Builder/*" -not -path "*/Packages/*"`" "${osName} pre-tests steps"

    # Execute common pre-test steps
    sourceScript "`find ${projectFolder} -path "*/${projectName}/common/before_tests.sh" -not -path "*/Package-Builder/*" -not -path "*/Packages/*"`" "common pre-tests steps"
    travis_end

    source ${SCRIPT_DIR}/run_tests.sh

    travis_start "swift_post_test"
    # Execute common post-test steps
    sourceScript "`find ${projectFolder} -path "*/${projectName}/common/after_tests.sh" -not -path "*/Package-Builder/*" -not -path "*/Packages/*"`" "common post-tests steps"

    # Execute OS specific post-test steps
    sourceScript "`find ${projectFolder} -path "*/${projectName}/${osName}/after_tests.sh" -not -path "*/Package-Builder/*" -not -path "*/Packages/*"`" "${osName} post-tests steps"

    echo ">> Finished testing Swift package."
    echo
    travis_end
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
    travis_start "swift_lint"
    echo "Running linter swiftlint version $(swiftlint version)"

    swiftlint lint --quiet --config ${projectFolder}/.swiftlint.yml
    travis_end
  #else
  #swiftlint lint --quiet --config ${projectFolder}/Package-Builder/.swiftlint.yml
  fi
fi

# Codecov.io
# Generate test code coverage report (macOS). The Travis build must have the
# CODECOV_ELIGIBLE environment variable defined.
if [ "$(uname)" == "Darwin" -a -n "${CODECOV_ELIGIBLE}" ]; then
  travis_start "swift_codecov"
  if [ -e ${projectFolder}/.swift-codecov ]; then
      source ${projectFolder}/.swift-codecov
  else
      sourceScript "${SCRIPT_DIR}/codecov.sh" "codecov generation"
  fi
  travis_end
fi

# SonarCloud
# Generate test code coverage report (macOS). The Travis build must have the
# SONARCLOUD_ELIGIBLE environment variable defined.
if [ "$(uname)" == "Darwin" -a -n "${SONARCLOUD_ELIGIBLE}" ]; then
  travis_start "swift_sonarcloud"
  if [ -e ${projectFolder}/.swift-sonarcloud ]; then
      source ${projectFolder}/.swift-sonarcloud
  else
      sourceScript "${SCRIPT_DIR}/sonarcloud.sh" "sonarcloud generation"
  fi
  travis_end
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
            travis_start "jazzy_doc"
            echo "Documentation tag jazzy-doc exists for this repo"
            sourceScript "${SCRIPT_DIR}/jazzy.sh" "jazzy-doc generation"
            travis_end
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
