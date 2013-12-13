#!/bin/bash

set -vx

mkdir -p ~/gitsvntest
cd ~/gitsvntest

## EDIT LINES IN THIS SECTION ##
# GITHUB_USERNAME should be your github username, e.g. dtenenbaum
export GITHUB_USERNAME=
export GITHUB_PASSWORD=
# REPO_NAME should be the name of an svn git/repos you want to create for testing,
# e.g. foobar
export REPO_NAME=
## SHOULD NOT NEED TO EDIT BELOW HERE ##


# delete the github repo if it already exists:

curl -i -u $GITHUB_USERNAME:$GITHUB_PASSWORD -X DELETE https://api.github.com/repos/$GITHUB_USERNAME/$REPO_NAME

sleep 2

# re-create the repo

curl -i -u $GITHUB_USERNAME:$GITHUB_PASSWORD -X POST -H "Content-Type: application/json" -d "{\"name\":\"$REPO_NAME\"}" https://api.github.com/user/repos

rm -rf $REPO_NAME
git clone git@github.com:$GITHUB_USERNAME/$REPO_NAME
cd $REPO_NAME


# create an svn repo:

export SVN_URL="https://hedgehog.fhcrc.org/bioconductor/trunk/madman/RpacksTesting"

# delete it first if necessary:

svn delete -m 'deleting test dir' $SVN_URL/$REPO_NAME

# then create it:
svn mkdir -m 'create test dir' $SVN_URL/$REPO_NAME


# populate it
pushd /tmp
rm -rf $REPO_NAME.svn
svn co $SVN_URL/$REPO_NAME $REPO_NAME.svn
cd $REPO_NAME.svn
echo "initial content" > README.md
svn add README.md
svn ci -m "first commit"

popd



git config --global alias.gl "log --graph --decorate --pretty=oneline --abbrev-commit --all"


git config --add svn-remote.hedgehog.url $SVN_URL/$REPO_NAME
git config --add svn-remote.hedgehog.fetch :refs/remotes/hedgehog
git svn fetch hedgehog -r HEAD

git checkout hedgehog

git checkout -b local-hedgehog

git config --add branch.local-hedgehog.remote .
###git config --add branch.local-hedgehog.merge refs/remotes/hedgehog
git svn rebase hedgehog

git checkout master

git push origin master

# OK, now the two repos are set up and have the same content.
# let's look at commit history:

git gl


## removing stuff here (make change #1 in svn)


# now create a separate git working copy (to simulate an external user)
# and make a change there:

echo "make change in git"

pushd /tmp
rm -rf $REPO_NAME.git
git clone git@github.com:$GITHUB_USERNAME/$REPO_NAME.git $REPO_NAME.git
cd $REPO_NAME.git
git checkout master
echo "made a change in git at `date`" >> README.md
git commit -a -m "made a change in git at `date`"
git push

popd

git checkout master
git pull
git checkout local-hedgehog
git merge master

# note the output of this, it creates a new commit:
git svn dcommit --add-author-from

git gl

# now go to svn and make a change

echo "make svn change"

pushd /tmp/$REPO_NAME.svn
svn up
echo "add a line in svn at `date`" >> README.md
svn ci -m "add a line in svn at `date`"

popd


git checkout local-hedgehog 
git svn rebase --username d.tenenbaum

git checkout master

git merge local-hedgehog


set +vx
