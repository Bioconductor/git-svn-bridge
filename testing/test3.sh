# assumes environment is set up as in test1.sh and 
# that test1.sh has already been run

echo "make a non-conflicting change in git"
olddir=`pwd`

tmpdir=`mktemp -d -t foobar`
echo "tmpdir is $tmpdir"

cd $tmpdir

git clone git@github.com:$GITHUB_USERNAME/$REPO_NAME.git

cd $REPO_NAME

git checkout master

echo "add a non-conflicting line in git" >> README.md

git commit -a -m "add a non-conflicting line in git"
git push

cd $olddir
#rm -rf $tmpdir

