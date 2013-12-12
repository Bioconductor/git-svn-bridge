# assumes environment is set up as in test1.sh and 
# that test1.sh has already been run

echo "make a non-conflicting change in svn"
olddir=`pwd`

tmpdir=`mktemp -d -t foo`
echo "tmpdir is $tmpdir"

cd $tmpdir

svn co --non-interactive --no-auth-cache --username $SVN_USERNAME --password $SVN_PASSWORD \
https://hedgehog.fhcrc.org/bioconductor/trunk/madman/RpacksTesting/$REPO_NAME

cd $REPO_NAME

date=`date`
echo "add a non-conflicting line in svn ($date)" >> README.md

svn commit -m "add a non-conflicting line in svn ($date)"

cd $olddir
#rm -rf $tmpdir

