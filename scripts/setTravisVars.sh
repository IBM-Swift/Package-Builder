#!/bin/bash
#
# Bulk update script for Travis environment variables. This can be used to
# set (or update) a common variable across many repos. It requires the Travis
# command line to be installed.
#
# You may either log in manually using 'travis login', or set the GITHUB_TOKEN
# environment variable to contain a GitHub personal access token, which will
# be used to execute 'travis login' for you.
#

# The list of repositories to act on.
REPOS=`cat Kitura-Repos.txt`
REPO_COUNT=`echo $REPOS | wc -w`

# The Travis environment variable to set (or updated)
TRAVIS_ENV_VAR="SWIFT_DEVELOPMENT_SNAPSHOT"

# The value to be set
TRAVIS_ENV_VALUE="swift-5.2-DEVELOPMENT-SNAPSHOT-2020-04-27-a"

# The type of var: public is visible, private is hidden (eg. for credentials)
TRAVIS_ENV_TYPE="public"

SUCCESS="" # List of successful updates
FAIL=""    # List of failed updates

# Builds a list of repositories that failed to update (if any)
function fail {
  FAIL="$FAIL $REPO" && echo "$REPO: FAILED"
  return 1
}

# Check that current user is logged in to Travis
echo "Checking Travis login status:"
if ! travis accounts; then
  # Try to log in
  if [ -z "${GITHUB_TOKEN}" ]; then
    echo "Error: either log in, or define GITHUB_TOKEN for Travis login"
    exit 1
  fi
  travis login --org --github-token "${GITHUB_TOKEN}" || exit 1
fi

# Confirm actions before proceeding
echo "You are about set $TRAVIS_ENV_VAR to $TRAVIS_ENV_VALUE (value is $TRAVIS_ENV_TYPE) for $REPO_COUNT repos."
echo "Do you want to continue? [y/N]"
read answer
if [ "y" != "$answer" ]; then
  exit 1
fi

# Set environment for each repo
for REPO in $REPOS; do
    echo "Setting ${TRAVIS_ENV_VAR}=${TRAVIS_ENV_VALUE} on ${REPO}"
    travis env set "${TRAVIS_ENV_VAR}" "${TRAVIS_ENV_VALUE}" --repo Kitura/${REPO} --${TRAVIS_ENV_TYPE} || fail || continue
    SUCCESS="$SUCCESS $REPO"
done

# Indicate which operations were successful and which failed
echo Success: $SUCCESS
echo Failed: $FAIL
exit
