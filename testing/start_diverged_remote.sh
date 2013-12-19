#!/bin/bash

# expects the following to be set in the environment:
# GITHUB_USERNAME
# GITHUB_PASSWORD 
# SVN_USERNAME
# SVN_PASSWORD
# SPECIALPASS
# EMAIL
# REPO_NAME
# APP_URL
# APP_DIR

###REPO_NAME=gitsvntest0 # should this be set in environment as well?

set -vx


REMOTE="ssh -o StrictHostKeyChecking=no ubuntu@gitsvn.bioconductor.org" 



echo "delete the github repo"

curl -i -u $GITHUB_USERNAME:$GITHUB_PASSWORD -X DELETE https://api.github.com/repos/$GITHUB_USERNAME/$REPO_NAME

sleep 2

echo "re-create the repo"

curl -i -u $GITHUB_USERNAME:$GITHUB_PASSWORD -X POST -H "Content-Type: application/json" -d "{\"name\":\"$REPO_NAME\"}" https://api.github.com/user/repos

#sleep 1

echo "add collaborator"

curl -i -u "dtenenbaum:$GITHUB_PASSWORD" -d "" -X PUT https://api.github.com/repos/$GITHUB_USERNAME/$REPO_NAME/collaborators/bioc-sync

echo "add hook"
curl -i -u $GITHUB_USERNAME:$GITHUB_PASSWORD -d "{\"name\":\"web\",\"config\":{\"url\":\"$APP_URL/git-push-hook\", \"ssl:\" 3}}" -X POST https://api.github.com/repos/$GITHUB_USERNAME/$REPO_NAME/hooks


echo "get local git working copy"
oldwd=`pwd`
gitwc=`mktemp -d -t gitwc`
cd $gitwc
git clone git@github.com:$GITHUB_USERNAME/$REPO_NAME.git
cd $REPO_NAME
echo "here are some contents (git)" > README.md
echo "here are some binary contents (git)" > foo
gzip foo
echo "here is an extra file" > extra
cat > DESCRIPTION <<EOM
Foo: Bar
Baz: quux
EOM
git add README.md
git add DESCRIPTION
git add foo.gz
git add extra
git commit -m 'first git commit'
git push origin master

cd $oldwd

echo "run remote commands"

#$REMOTE "rm -f $APP_DIR/data/monitored_*"
$REMOTE "touch $APP_DIR/data/monitored_git_repos.txt $APP_DIR/data/monitored_svn_repos.txt"
$REMOTE "cd $APP_DIR/data && grep -v $REPO_NAME monitored_svn_repos.txt > tmp ; rm monitored_svn_repos.txt && mv tmp monitored_svn_repos.txt"
$REMOTE "cd $APP_DIR/data && grep -v $REPO_NAME monitored_git_repos.txt > tmp ; rm monitored_git_repos.txt && mv tmp monitored_git_repos.txt"
$REMOTE "rm -rf /home/ubuntu/biocsync/$REPO_NAME"

#$REMOTE "svn up $APP_DIR"
$REMOTE "cd /home/ubuntu/bioc-git-svn && git pull"
#$REMOTE "git checkout gitsvn" # needed?
$REMOTE "touch $APP_DIR/tmp/restart.txt"

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
echo "here are some contents (svn)" > README.md
svn add README.md
echo "here are some binary contents (svn)" > foo
gzip foo
svn add foo.gz
cat > DESCRIPTION <<EOM
Foo: blat (svn)
Baz: quux
EOM
svn add DESCRIPTION
#echo "here is an extra file" > extra
#svn add extra
svn ci -m "first commit (svn)"

cd $oldwd
rm -rf $tmpdir


echo "log in to web app"

rm -f cookies.txt
curl -c cookies.txt -X POST -d "username=$SVN_USERNAME&password=$SVN_PASSWORD&specialpass=$SPECIALPASS" $APP_URL/login > /dev/null 2>&1

echo "create new bridge"

curl -b cookies.txt  -d "rootdir=https://hedgehog.fhcrc.org/bioconductor/trunk/madman/RpacksTesting/&svndir=$REPO_NAME&githuburl=https://github.com/$GITHUB_USERNAME/$REPO_NAME&email=$EMAIL&conflict=svn-wins" $APP_URL/newproject

echo



  

set +vx

