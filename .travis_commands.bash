#! /bin/bash

set -o errexit
set -o nounset

osx-ponyc-test(){
  echo "Building and testing ponyc..."
  make CC="$CC1" CXX="$CXX1" -j$(sysctl -n hw.ncpu) all
  make CC="$CC1" CXX="$CXX1" test-ci
}

build_deb(){
  deb_distro=$1

  # untar source code
  tar -xzf "ponyc_${package_version}.orig.tar.gz"

  pushd "ponyc-${package_version}"

  cp -r .packaging/deb debian
  cp LICENSE debian/copyright

  # create changelog
  rm -f debian/changelog
  dch --package ponyc -v "${package_version}" -D "${deb_distro}" --force-distribution --controlmaint --create "Release ${package_version}"

  # remove pcre2 dependency from package and tests for trusty and jessie
  if [[ ("$deb_distro" == "trusty") || ("$deb_distro" == "jessie") ]]
  then
    sed -i 's/, libpcre2-dev//g' debian/control
    sed -i 's#use glob#//use glob#g' packages/stdlib/_test.pony
    sed -i 's#glob.Main.make#None//glob.Main.make#g' packages/stdlib/_test.pony
    sed -i 's#use regex#//use regex#g' packages/stdlib/_test.pony
    sed -i 's#regex.Main.make#//regex.Main.make#g' packages/stdlib/_test.pony
    EDITOR=/bin/true dpkg-source --commit . removepcredep
  fi

  # create package for distro using docker to run debuild
  sudo docker run -v "$(pwd)/..:/home/pony" --rm --user root "ponylang/ponyc-ci:${deb_distro}-deb-builder" sh -c 'cd ponyc* && mk-build-deps -t "apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends -y" -i -r && debuild -b -us -uc'

  ls -l ..

  # restore original working directory
  popd

  # create bintray upload json file
  bash .bintray_deb.bash "$package_version" "$deb_distro"

  # rename package to avoid clashing across different distros packages
  mv "ponyc_${package_version}_amd64.deb" "ponyc_${package_version}_${deb_distro}_amd64.deb"

  # clean up old build directory to ensure things are all clean
  sudo rm -rf "ponyc-${package_version}"
}

ponyc-build-debs-ubuntu(){
  package_version=$1

  set -x

  echo "Install devscripts..."
  sudo apt-get update
  sudo apt-get install -y devscripts

  echo "Building off ponyc debs for bintray..."
  wget "https://github.com/ponylang/ponyc/archive/${package_version}.tar.gz" -O "ponyc_${package_version}.orig.tar.gz"

  build_deb xenial
  build_deb artful
  build_deb bionic
  build_deb trusty

  ls -la
  set +x
}

ponyc-build-debs-debian(){
  package_version=$1

  set -x

  echo "Install devscripts..."
  sudo apt-get update
  sudo apt-get install -y devscripts

  echo "Building off ponyc debs for bintray..."
  wget "https://github.com/ponylang/ponyc/archive/${package_version}.tar.gz" -O "ponyc_${package_version}.orig.tar.gz"

  build_deb buster
  build_deb stretch
  build_deb jessie

  ls -la
  set +x
}

build_and_submit_deb_src(){
  deb_distro=$1
  rm -f debian/changelog
  dch --package ponyc -v "${package_version}-0ppa1~${deb_distro}" -D "${deb_distro}" --controlmaint --create "Release ${package_version}"
  if [[ "$deb_distro" == "trusty" ]]
  then
    EDITOR=/bin/true dpkg-source --commit . removepcredep
  fi
  debuild -S
  dput custom-ppa "../ponyc_${package_version}-0ppa1~${deb_distro}_source.changes"
}

ponyc-kickoff-copr-ppa(){
  package_version=$(cat VERSION)

  echo "Install debuild, dch, dput..."
  sudo apt-get install -y devscripts build-essential lintian debhelper python-paramiko

  echo "Decrypting and Importing gpg keys..."
  # Disable shellcheck error SC2154 for uninitialized variables as these get set by travis-ci for us.
  # See the following for error details: https://github.com/koalaman/shellcheck/wiki/SC2154
  # shellcheck disable=SC2154
  openssl aes-256-cbc -K "$encrypted_9035f6d310e4_key" -iv "$encrypted_9035f6d310e4_iv" -in .securefiles.tar.enc -out .securefiles.tar -d
  tar -xvf .securefiles.tar
  gpg --import ponylang-secret-gpg.key
  gpg --import-ownertrust ponylang-ownertrust-gpg.txt
  mv sshkey ~/sshkey
  sudo chmod 600 ~/sshkey

  echo "Kicking off ponyc packaging for PPA..."
  wget "https://github.com/ponylang/ponyc/archive/${package_version}.tar.gz" -O "ponyc_${package_version}.orig.tar.gz"
  tar -xvzf "ponyc_${package_version}.orig.tar.gz"
  pushd "ponyc-${package_version}"
  cp -r .packaging/deb debian
  cp LICENSE debian/copyright

  # ssh stuff for launchpad as a workaround for https://github.com/travis-ci/travis-ci/issues/9391
  {
    echo "[custom-ppa]"
    echo "fqdn = ppa.launchpad.net"
    echo "method = sftp"
    echo "incoming = ~ponylang/ubuntu/ponylang/"
    echo "login = ponylang"
    echo "allow_unsigned_uploads = 0"
  } >> ~/.dput.cf

  mkdir -p ~/.ssh
  {
    echo "Host ppa.launchpad.net"
    echo "    StrictHostKeyChecking no"
    echo "    IdentityFile ~/sshkey"
  } >> ~/.ssh/config
  sudo chmod 400 ~/.ssh/config

  build_and_submit_deb_src xenial
  build_and_submit_deb_src artful
  build_and_submit_deb_src bionic
  build_and_submit_deb_src cosmic

  # run trusty last because we will modify things to not rely on pcre2
  # remove pcre dependency from package and tests
  sed -i 's/, libpcre2-dev//g' debian/control
  sed -i 's#use glob#//use glob#g' packages/stdlib/_test.pony
  sed -i 's#glob.Main.make#None//glob.Main.make#g' packages/stdlib/_test.pony
  sed -i 's#use regex#//use regex#g' packages/stdlib/_test.pony
  sed -i 's#regex.Main.make#//regex.Main.make#g' packages/stdlib/_test.pony
  build_and_submit_deb_src trusty

  # COPR for fedora/centos/suse
  echo "Kicking off ponyc packaging for COPR..."
  docker run -it --rm -e COPR_LOGIN="${COPR_LOGIN}" -e COPR_USERNAME=ponylang -e COPR_TOKEN="${COPR_TOKEN}" -e COPR_COPR_URL=https://copr.fedorainfracloud.org mgruener/copr-cli buildscm --clone-url https://github.com/ponylang/ponyc --commit "${package_version}" --subdir /.packaging/rpm/ --spec ponyc.spec --type git --nowait ponylang

  # restore original working directory
  popd
}

ponyc-build-packages(){
  echo "Installing ruby, rpm, and fpm..."
  rvm use 2.2.3 --default
  sudo apt-get install -y rpm
  gem install fpm

  echo "Building ponyc packages for deployment..."
  make CC="$CC1" CXX="$CXX1" verbose=1 arch=x86-64 tune=intel package_name="ponyc" package_base_version="$(cat VERSION)" deploy
}

ponyc-build-docs(){
  echo "Installing mkdocs and offical theme..."
  sudo -H pip install mkdocs-ponylang

  echo "Building ponyc docs..."
  make CC="$CC1" CXX="$CXX1" docs-online

  echo "Uploading docs using mkdocs..."
  git remote add gh-token "https://${STDLIB_TOKEN}@github.com/ponylang/stdlib.ponylang.org"
  git fetch gh-token
  git reset gh-token/master
  cd stdlib-docs
  mkdocs gh-deploy -v --clean --remote-name gh-token --remote-branch master
}
