#!bash
tmp_version="v`cat VERSION`"
echo "ready to tag for version $tmp_version"
git tag $tmp_version
git push origin $tmp_version
echo "Press a Key"
read -n 1