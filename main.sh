#! /bin/bash

set -e

VERSION="1.0.0"

source ./pika-build-config.sh

echo "$PIKA_BUILD_ARCH" > pika-build-arch

cd ./falcond

# Get build deps
apt-get build-dep ./ -y

# Build package
LOGNAME=root dh_make --createorig -y -l -p falcond_"$VERSION" || echo "dh-make: Ignoring Last Error"
dpkg-buildpackage --no-sign

# Move the debs to output
cd ../
mkdir -p ./output
mv ./*.deb ./output/
