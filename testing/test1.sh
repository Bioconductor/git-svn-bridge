#!/bin/bash

# expects the following to be set in the environment:
# GITHUB_USERNAME
# GITHUB_PASSWORD 
# SVN_USERNAME
# SVN_PASSWORD
# SPECIALPASS
# EMAIL
# REPO_NAME

###REPO_NAME=gitsvntest0 # should this be set in environment as well?



echo "delete the github repo"

curl -i -u $GITHUB_USERNAME:$GITHUB_PASSWORD -X DELETE https://api.github.com/repos/$GITHUB_USERNAME/$REPO_NAME

sleep 2

echo "re-create the repo"

curl -i -u $GITHUB_USERNAME:$GITHUB_PASSWORD -X POST -H "Content-Type: application/json" -d "{\"name\":\"$REPO_NAME\"}" https://api.github.com/user/repos

#sleep 1

echo "add collaborator"

curl -i -u "dtenenbaum:$GITHUB_PASSWORD" -d "" -X PUT https://api.github.com/repos/$GITHUB_USERNAME/$REPO_NAME/collaborators/bioc-sync

echo "add hook"
curl -i -u $GITHUB_USERNAME:$GITHUB_PASSWORD -d "{\"name\":\"web\",\"config\":{\"url\":\"http://gitsvn.bioconductor.org/git-push-hook\"}}" -X POST https://api.github.com/repos/$GITHUB_USERNAME/$REPO_NAME/hooks

REMOTE="ssh -o StrictHostKeyChecking=no ubuntu@gitsvn.bioconductor.org"


echo "run remote commands"

#$REMOTE "rm -f ~/app/data/monitored_*"
$REMOTE "touch ~/app/data/monitored_git_repos.txt ~/app/data/monitored_svn_repos.txt"
$REMOTE "cd ~/app/data && grep -v $REPO_NAME monitored_svn_repos.txt > tmp ; rm monitored_svn_repos.txt && mv tmp monitored_svn_repos.txt"
$REMOTE "cd ~/app/data && grep -v $REPO_NAME monitored_git_repos.txt > tmp ; rm monitored_git_repos.txt && mv tmp monitored_git_repos.txt"
$REMOTE "rm -rf ~/biocsync/$REPO_NAME"

#$REMOTE "svn up ~/app"
$REMOTE "cd ~/bioc-git-svn && git pull"
$REMOTE "touch ~/app/tmp/restart.txt"

echo "delete the svn repo"
svn delete https://hedgehog.fhcrc.org/bioconductor/trunk/madman/RpacksTesting/$REPO_NAME -m "delete this test directory"
echo "recreate svn repo"

svn mkdir -m "create test directory" https://hedgehog.fhcrc.org/bioconductor/trunk/madman/RpacksTesting/$REPO_NAME
oldwd=`pwd`
tmpdir=`mktemp -d -t foo`

cd $tmpdir
svn co --non-interactive --no-auth-cache --username $SVN_USERNAME --password $SVN_PASSWORD \
https://hedgehog.fhcrc.org/bioconductor/trunk/madman/RpacksTesting/$REPO_NAME
cd $REPO_NAME
echo "original contents of file (svn)" > README.md
cat > DESCRIPTION <<EOM
Foo: Bar
Baz: quux
EOM
svn add DESCRIPTION
svn add README.md
svn ci -m "first commit (svn)"

cd $oldwd
rm -rf $tmpdir


echo "log in to web app"

rm -f cookies.txt
curl -c cookies.txt -X POST -d "username=$SVN_USERNAME&password=$SVN_PASSWORD&specialpass=$SPECIALPASS" http://gitsvn.bioconductor.org/login > /dev/null 2>&1

echo "create new bridge"

curl -b cookies.txt  -d "rootdir=https://hedgehog.fhcrc.org/bioconductor/trunk/madman/RpacksTesting/&svndir=$REPO_NAME&githuburl=https://github.com/$GITHUB_USERNAME/$REPO_NAME&email=$EMAIL" http://gitsvn.bioconductor.org/newproject

echo

# cd ~/dev/RpacksTesting_git && rm -rf $REPO_NAME && \
#   git clone git@github.com:$GITHUB_USERNAME/$REPO_NAME.git && cd $REPO_NAME \
#   && echo "add a line in git" >> README.md && 
#   git commit -a -m "add a line in git" \
#   && git push && cd ..


  

