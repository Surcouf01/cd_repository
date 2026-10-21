#!bash
tmp_version="v`cat VERSION`"
echo "ready to tag for version $tmp_version"
#pause
git tag $tmp_version
git push origin $tmp_version
