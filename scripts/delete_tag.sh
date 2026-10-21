#!bash
version=`cat VERSION`
echo "ready to delete tag for version $tmp_version"
git tag v$version -d
git push origin --delete v$version
echo "Press a Key"
read -n 1