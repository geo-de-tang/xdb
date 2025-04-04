#!/bin/bash

HTTP_DEPS="https://dependencies.mapd.com/thirdparty"
SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ "$TSAN" = "true" ]; then
  ARROW_TSAN="-DARROW_JEMALLOC=OFF -DARROW_USE_TSAN=ON"
elif [ "$TSAN" = "false" ]; then
  ARROW_TSAN="-DARROW_JEMALLOC=BUNDLED"
fi

ARROW_USE_CUDA="-DARROW_CUDA=ON"
if [ "$NOCUDA" = "true" ]; then
  ARROW_USE_CUDA="-DARROW_CUDA=OFF"
fi

function generate_deps_version_file() {
  # SUFFIX, BRANCH_NAME, GIT_COMMIT and BUILD_CONTAINER_NAME are set as environment variables not as parameters and
  # are generally set 'on' the calling docker container.
  echo "Public Release:Deps generated for prefix [$PREFIX], commit [$GIT_COMMIT] and SUFFIX [$SUFFIX]" > $PREFIX/mapd_deps_version.txt
  # BUILD_CONTAINER_IMAGE will only be set if called from heavyai-dependency-tar-builder.sh
  if [[ -n $BUILD_CONTAINER_IMAGE_ID ]] ; then
    echo "Public Release:Using build image id [${BUILD_CONTAINER_IMAGE_ID}]" >> $PREFIX/mapd_deps_version.txt
  fi
  if [[ -n $BUILD_CONTAINER_IMAGE ]] ; then
    # Not copied to released version of this file
    echo "Using build image [${BUILD_CONTAINER_IMAGE}]" >> $PREFIX/mapd_deps_version.txt
  fi
  echo "Component version information:" >> $PREFIX/mapd_deps_version.txt
  # Grab all the _VERSION variables and print them to the file
  # This isn't a complete list of all software and versions.  For example openssl either uses
  # the version that ships with the OS or it is installed from the OS specific file and
  # doesn't use an _VERSION variable.
  # Not to be copied to released version of this file
  for i in $(compgen -A variable | grep _VERSION) ; do echo  $i "${!i}" ; done >> $PREFIX/mapd_deps_version.txt
}      

function download() {
  echo $CACHE/$target_file
  target_file=$(basename $1)
  if [[ -s $CACHE/$target_file ]] ; then
    # the '\' before the cp forces the command processor to use
    # the actual command rather than an aliased version.
    \cp $CACHE/$target_file .
  else
    wget --continue "$1"
  fi
  if  [[ -n $CACHE &&  $1 != *mapd* && ! -e "$CACHE/$target_file" ]] ; then
    cp $target_file $CACHE
  fi
}

function extract() {
    tar xvf "$1"
}

function cmake_build_and_install() {
  cmake --build . --parallel && cmake --install .
}

function makej() {
  os=$(uname)
  if [ "$os" = "Darwin" ]; then
    nproc=$(sysctl -n hw.ncpu)
  else
    nproc=$(nproc)
  fi
  make -j ${nproc:-8}
}

function make_install() {
  # sudo is needed on osx
  os=$(uname)
  if [ "$os" = "Darwin" ]; then
    sudo make install
  else
    make install
  fi
}

function check_artifact_cleanup() {
  download_file=$1
  build_dir=$2
  [[ -z $build_dir || -z $download_file ]] && echo "Invalid args remove_install_artifacts" && return
  if [[ $SAVE_SPACE == 'true' ]] ; then 
    rm $download_file
    rm -rf $build_dir
  fi
}

function download_make_install() {
    download "$1"
    artifact_name="$(basename $1)"
    extract $artifact_name
    build_dir=${artifact_name%%.tar*}
    [[ -n "$2" ]] && build_dir="${2}"
    pushd ${build_dir}

    if [ -x ./Configure ]; then
        ./Configure --prefix=$PREFIX $3
    else
        ./configure --prefix=$PREFIX $3
    fi

    # if the downloading xml-security-c, then patch before building
    if [[ $artifact_name == *xml-security-c* ]]; then
        patch /home/george/Documents/Projects/heavydb/heavydb/scripts/xml-security-c-2.0.2/xsec/enc/OpenSSL/OpenSSLCryptoKeyRSA.cpp < /home/george/Documents/Projects/heavydb/heavydb/fix_openssl_const_cast.patch
    fi

    makej
    make_install
    popd
    check_artifact_cleanup $artifact_name $build_dir
}

CMAKE_VERSION=3.25.2

function install_cmake() {
  if [[ -d $PREFIX/bin/cmake ]] ; then
    echo "CMake already installed, skipping"
    return
  fi

  CXXFLAGS="-pthread" CFLAGS="-pthread" download_make_install ${HTTP_DEPS}/cmake-${CMAKE_VERSION}.tar.gz
}

# gcc
GCC_VERSION=11.1.0
function install_centos_gcc() {

  download ftp://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz
  extract gcc-${GCC_VERSION}.tar.xz
  pushd gcc-${GCC_VERSION}
  export CPPFLAGS="-I$PREFIX/include"
  ./configure \
    --prefix=$PREFIX \
    --disable-multilib \
    --enable-bootstrap \
    --enable-shared \
    --enable-threads=posix \
    --enable-checking=release \
    --with-system-zlib \
    --enable-__cxa_atexit \
    --disable-libunwind-exceptions \
    --enable-gnu-unique-object \
    --enable-languages=c,c++ \
    --with-tune=generic \
    --with-gmp=$PREFIX \
    --with-mpc=$PREFIX \
    --with-mpfr=$PREFIX #replace '--with-tune=generic' with '--with-tune=power8' for POWER8
  makej
  make install
  popd
  check_artifact_cleanup gcc-${GCC_VERSION}.tar.xz gcc-${GCC_VERSION}
}

BOOST_VERSION=1_72_0
function install_boost() {
  # http://downloads.sourceforge.net/project/boost/boost/${BOOST_VERSION//_/.}/boost_$${BOOST_VERSION}.tar.bz2
  download ${HTTP_DEPS}/boost_${BOOST_VERSION}.tar.bz2
  extract boost_${BOOST_VERSION}.tar.bz2
  pushd boost_${BOOST_VERSION}
  ./bootstrap.sh --prefix=$PREFIX
  ./b2 cxxflags=-fPIC install --prefix=$PREFIX || true
  popd
  check_artifact_cleanup boost_${BOOST_VERSION}.tar.bz2 boost_${BOOST_VERSION}
}

ARROW_VERSION=apache-arrow-9.0.0

function install_arrow() {

  # if already $arrow version already exists then return and echo
  if [[ -d $PREFIX/include/arrow ]] ; then
    echo "Arrow already installed, skipping"
    return
  fi

  download https://github.com/apache/arrow/archive/$ARROW_VERSION.tar.gz
  extract $ARROW_VERSION.tar.gz

  mkdir -p arrow-$ARROW_VERSION/cpp/build
  pushd arrow-$ARROW_VERSION/cpp/build
  cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$PREFIX \
    -DARROW_BUILD_SHARED=ON \
    -DARROW_BUILD_STATIC=ON \
    -DARROW_BUILD_TESTS=OFF \
    -DARROW_BUILD_BENCHMARKS=OFF \
    -DARROW_CSV=ON \
    -DARROW_JSON=ON \
    -DARROW_WITH_BROTLI=BUNDLED \
    -DARROW_WITH_ZLIB=BUNDLED \
    -DARROW_WITH_LZ4=BUNDLED \
    -DARROW_WITH_SNAPPY=BUNDLED \
    -DARROW_WITH_ZSTD=BUNDLED \
    -DARROW_USE_GLOG=OFF \
    -DARROW_BOOST_USE_SHARED=${ARROW_BOOST_USE_SHARED:="OFF"} \
    -DARROW_PARQUET=ON \
    -DARROW_FILESYSTEM=ON \
    -DARROW_S3=ON \
    -DTHRIFT_HOME=${THRIFT_HOME:-$PREFIX} \
    ${ARROW_USE_CUDA} \
    ${ARROW_TSAN} \
    ..
  makej
  make_install
  popd
  check_artifact_cleanup $ARROW_VERSION.tar.gz arrow-$ARROW_VERSION
}

SNAPPY_VERSION=1.1.7
function install_snappy() {

  # if already $snappy version already exists then return and echo
  if [[ -d $PREFIX/include/snappy ]] ; then
    echo "Snappy already installed, skipping"
    return
  fi

  download https://github.com/google/snappy/archive/$SNAPPY_VERSION.tar.gz
  extract $SNAPPY_VERSION.tar.gz
  mkdir -p snappy-$SNAPPY_VERSION/build
  pushd snappy-$SNAPPY_VERSION/build
  cmake \
    -DCMAKE_CXX_FLAGS="-fPIC" \
    -DCMAKE_INSTALL_PREFIX=$PREFIX \
    -DCMAKE_BUILD_TYPE=Release \
    -DSNAPPY_BUILD_TESTS=OFF \
    ..
  makej
  make_install
  popd
  check_artifact_cleanup $SNAPPY_VERSION.tar.gz snappy-$SNAPPY_VERSION
}

AWSCPP_VERSION=1.7.301
#AWSCPP_VERSION=1.9.335

function install_awscpp() {
    # if already $awscpp version already exists then return and echo
    if [[ -d $PREFIX/include/aws ]] ; then
        echo "AWS C++ SDK already installed, skipping"
        return
    fi

    # default c++ standard support
    CPP_STANDARD=14
    # check c++17 support
    GNU_VERSION1=$(g++ --version|head -n1|awk '{print $4}'|cut -d'.' -f1)
    if [ "$GNU_VERSION1" = "7" ]; then
        CPP_STANDARD=17
    fi
    rm -rf aws-sdk-cpp-${AWSCPP_VERSION}
    download https://github.com/aws/aws-sdk-cpp/archive/${AWSCPP_VERSION}.tar.gz
    tar xvfz ${AWSCPP_VERSION}.tar.gz
    pushd aws-sdk-cpp-${AWSCPP_VERSION}
    # ./prefetch_crt_dependency.sh
    sed -i 's/CMAKE_ARGS/CMAKE_ARGS -DBUILD_TESTING=off -DCMAKE_C_FLAGS="-Wno-error"/g' third-party/cmake/BuildAwsCCommon.cmake
    sed -i 's/-Werror//g' cmake/compiler_settings.cmake
    mkdir build
    cd build
    cmake \
        -GNinja \
        -DAUTORUN_UNIT_TESTS=off \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DBUILD_ONLY="s3;transfer;config;sts;cognito-identity;identity-management" \
        -DBUILD_SHARED_LIBS=0 \
        -DCUSTOM_MEMORY_MANAGEMENT=0 \
        -DCPP_STANDARD=$CPP_STANDARD \
        -DENABLE_TESTING=off \
        ..
    cmake_build_and_install
    popd
    check_artifact_cleanup ${AWSCPP_VERSION}.tar.gz aws-sdk-cpp-${AWSCPP_VERSION}
}

LLVM_VERSION=14.0.6

function install_llvm() {


    VERS=${LLVM_VERSION}
    if [[ -d $PREFIX/include/llvm ]] ; then
      echo "LLVM already installed, skipping"
      return
    fi
    
    download ${HTTP_DEPS}/llvm/$VERS/llvm-$VERS.src.tar.xz
    download ${HTTP_DEPS}/llvm/$VERS/clang-$VERS.src.tar.xz
    download ${HTTP_DEPS}/llvm/$VERS/compiler-rt-$VERS.src.tar.xz
    download ${HTTP_DEPS}/llvm/$VERS/clang-tools-extra-$VERS.src.tar.xz
    rm -rf llvm-$VERS.src
    extract llvm-$VERS.src.tar.xz
    extract clang-$VERS.src.tar.xz
    extract compiler-rt-$VERS.src.tar.xz
    extract clang-tools-extra-$VERS.src.tar.xz
    mv clang-$VERS.src llvm-$VERS.src/tools/clang
    mv compiler-rt-$VERS.src llvm-$VERS.src/projects/compiler-rt
    mkdir -p llvm-$VERS.src/tools/clang/tools
    mv clang-tools-extra-$VERS.src llvm-$VERS.src/tools/clang/tools/extra

    rm -rf build.llvm-$VERS
    mkdir build.llvm-$VERS
    pushd build.llvm-$VERS

    LLVM_SHARED=""
    if [ "$LLVM_BUILD_DYLIB" = "true" ]; then
      LLVM_SHARED="-DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=ON"
    fi

    cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=$PREFIX \
      -DLLVM_ENABLE_RTTI=on \
      -DLLVM_USE_INTEL_JITEVENTS=on \
      -DLLVM_ENABLE_LIBEDIT=off \
      -DLLVM_ENABLE_ZLIB=off \
      -DLLVM_INCLUDE_BENCHMARKS=off \
      -DLLVM_ENABLE_LIBXML2=off \
      -DLLVM_TARGETS_TO_BUILD="X86;AArch64;PowerPC;NVPTX" \
      $LLVM_SHARED \
      ../llvm-$VERS.src
    makej
    make install
    popd
    check_artifact_cleanup clang-$VERS.src.tar.xz llvm-$VERS.src/tools/clang
    check_artifact_cleanup compiler-rt-$VERS.src.tar.xz llvm-$VERS.src/projects/compiler-rt
    check_artifact_cleanup clang-tools-extra-$VERS.src.tar.xz llvm-$VERS.src/tools/clang/tools/extra
    check_artifact_cleanup llvm-$VERS.src.tar.xz  llvm-$VERS.src
    if [[ $SAVE_SPACE == 'true' ]]; then
      rm -rf build.llvm-$VERS
    fi
}

THRIFT_VERSION=0.15.0

function install_thrift() {
    # if already $thrift version already exists then return and echo
    if [[ -d $PREFIX/include/thrift ]] ; then
        echo "Thrift already installed, skipping"
        return
    fi

    # http://dlcdn.apache.org/thrift/$THRIFT_VERSION/thrift-$THRIFT_VERSION.tar.gz
    download ${HTTP_DEPS}/thrift-$THRIFT_VERSION.tar.gz
    extract thrift-$THRIFT_VERSION.tar.gz
    pushd thrift-$THRIFT_VERSION
    if [ "$TSAN" = "false" ]; then
      THRIFT_CFLAGS="-fPIC"
      THRIFT_CXXFLAGS="-fPIC"
    elif [ "$TSAN" = "true" ]; then
      THRIFT_CFLAGS="-fPIC -fsanitize=thread -fPIC -O1 -fno-omit-frame-pointer"
      THRIFT_CXXFLAGS="-fPIC -fsanitize=thread -fPIC -O1 -fno-omit-frame-pointer"
    fi
    source /etc/os-release
    if [ "$ID" == "ubuntu"  ] ; then
      BOOST_LIBDIR=""
    else
      BOOST_LIBDIR="--with-boost-libdir=$PREFIX/lib"
    fi
    CFLAGS="$THRIFT_CFLAGS" CXXFLAGS="$THRIFT_CXXFLAGS" JAVA_PREFIX=$PREFIX/lib ./configure \
        --prefix=$PREFIX \
        --enable-libs=off \
        --with-cpp \
        --without-go \
        --without-python \
        $BOOST_LIBDIR
    makej
    make install
    popd
    check_artifact_cleanup thrift-$THRIFT_VERSION.tar.gz thrift-$THRIFT_VERSION
}

PROJ_VERSION=8.2.1
GDAL_VERSION=3.4.1

function install_gdal() {
    # if already $gdal version already exists then return and echo
    if [[ -d $PREFIX/include/gdal ]] ; then
        echo "GDAL already installed, skipping"
        return
    fi

    # sqlite3
    download_make_install https://sqlite.org/2021/sqlite-autoconf-3350500.tar.gz

    # expat
    download_make_install https://github.com/libexpat/libexpat/releases/download/R_2_2_5/expat-2.2.5.tar.bz2

    # kml
    download ${HTTP_DEPS}/libkml-master.zip
    unzip -u libkml-master.zip
    pushd libkml-master
    ./autogen.sh || true
    CXXFLAGS="-std=c++03" ./configure --with-expat-include-dir=$PREFIX/include/ --with-expat-lib-dir=$PREFIX/lib --prefix=$PREFIX --enable-static --disable-java --disable-python --disable-swig
    makej
    make install
    popd

    # hdf5
    download_make_install ${HTTP_DEPS}/hdf5-1.12.1.tar.gz "" "--enable-hl"

    # netcdf
    download https://github.com/Unidata/netcdf-c/archive/refs/tags/v4.8.1.tar.gz
    tar xzvf v4.8.1.tar.gz
    pushd netcdf-c-4.8.1
    CPPFLAGS=-I${PREFIX}/include LDFLAGS=-L${PREFIX}/lib ./configure --prefix=$PREFIX
    makej
    make install
    popd

    # proj
    download_make_install ${HTTP_DEPS}/proj-${PROJ_VERSION}.tar.gz "" "--disable-tiff"

    # gdal (with patch for memory leak in VSICurlClearCache)
    download ${HTTP_DEPS}/gdal-${GDAL_VERSION}.tar.gz
    extract gdal-${GDAL_VERSION}.tar.gz
    pushd gdal-${GDAL_VERSION}
    patch -p0 port/cpl_vsil_curl.cpp $SCRIPTS_DIR/gdal-3.4.1_memory_leak_fix_1.patch
    patch -p0 port/cpl_vsil_curl_streaming.cpp $SCRIPTS_DIR/gdal-3.4.1_memory_leak_fix_2.patch
    ./configure --prefix=$PREFIX --without-geos --with-libkml=$PREFIX --with-proj=$PREFIX --with-libtiff=internal --with-libgeotiff=internal --with-netcdf=$PREFIX --with-blosc=$PREFIX
    makej
    make_install
    popd
    check_artifact_cleanup libkml-master.zip libkml-master
    check_artifact_cleanup v4.8.1.tar.gz netcdf-c-4.8.1
    check_artifact_cleanup gdal-${GDAL_VERSION}.tar.gz gdal-${GDAL_VERSION}
}

GEOS_VERSION=3.8.1

function install_geos() {
  # if already $geos version already exists then return and echo
  if [[ -d $PREFIX/include/geos ]] ; then
    echo "GEOS already installed, skipping"
    return
  fi

    download_make_install ${HTTP_DEPS}/geos-${GEOS_VERSION}.tar.bz2 "" "--enable-shared --disable-static"

}

FOLLY_VERSION=2021.02.01.00
FMT_VERSION=7.1.3
GLOG_VERSION=0.5.0
function install_folly() {
  # if already $folly version already exists then return and echo
  if [[ -d $PREFIX/include/folly ]] ; then
    echo "Folly already installed, skipping"
    return
  fi

  # Build Glog statically to remove dependency on it from heavydb CMake
  download https://github.com/google/glog/archive/refs/tags/v$GLOG_VERSION.tar.gz
  extract v$GLOG_VERSION.tar.gz
  BUILD_DIR="glog-$GLOG_VERSION/build"
  mkdir -p $BUILD_DIR
  pushd $BUILD_DIR
  cmake -GNinja \
  -DBUILD_SHARED_LIBS=OFF \
  -DWITH_UNWIND=OFF \
  -DCMAKE_INSTALL_PREFIX=$PREFIX ..
  cmake_build_and_install
  popd

  # Folly depends on fmt
  download https://github.com/fmtlib/fmt/archive/$FMT_VERSION.tar.gz
  extract $FMT_VERSION.tar.gz
  BUILD_DIR="fmt-$FMT_VERSION/build"
  mkdir -p $BUILD_DIR
  pushd $BUILD_DIR
  cmake -GNinja \
        -DFMT_DOC=OFF \
        -DFMT_TEST=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_INSTALL_PREFIX=$PREFIX ..
  cmake_build_and_install
  popd

  download https://github.com/facebook/folly/archive/v$FOLLY_VERSION.tar.gz
  extract v$FOLLY_VERSION.tar.gz
  pushd folly-$FOLLY_VERSION/build/

  # jemalloc disabled due to issue with clang build on Ubuntu
  # see: https://github.com/facebook/folly/issues/976
  cmake -GNinja \
        -DCMAKE_CXX_FLAGS="-pthread" \
        -DFOLLY_USE_JEMALLOC=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_INSTALL_PREFIX=$PREFIX ..
  cmake_build_and_install

  popd
  check_artifact_cleanup $FMT_VERSION.tar.gz "fmt-$FMT_VERSION"
  check_artifact_cleanup v$FOLLY_VERSION.tar.gz "folly-$FOLLY_VERSION"
}

IWYU_VERSION=0.18
LLVM_VERSION_USED_FOR_IWYU=14.0.6
if [ "$LLVM_VERSION" != "$LLVM_VERSION_USED_FOR_IWYU" ]; then
  # NOTE: If you get this error, somebody upgraded LLVM, but they need to go
  # to https://include-what-you-use.org/ then scroll down, figure out which
  # iwyu version goes with the new LLVM_VERSION we're now using, then update
  # IWYU_VERSION and LLVM_VERSION_USED_FOR_IWYU above, appropriately.
  echo "ERROR: IWYU_VERSION of $IWYU_VERSION must be updated because LLVM_VERSION of $LLVM_VERSION_USED_FOR_IWYU was changed to $LLVM_VERSION"
  exit 1
fi
function install_iwyu() {
  # if already $iwyu version already exists then return and echo
  if [[ -d $PREFIX/include/include-what-you-use ]] ; then
    echo "IWYU already installed, skipping"
    return
  fi
  download https://include-what-you-use.org/downloads/include-what-you-use-${IWYU_VERSION}.src.tar.gz
  extract include-what-you-use-${IWYU_VERSION}.src.tar.gz
  BUILD_DIR=include-what-you-use/build
  mkdir -p $BUILD_DIR
  pushd $BUILD_DIR
  cmake -G "Unix Makefiles" \
        -DCMAKE_PREFIX_PATH=${PREFIX}/lib \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        ..
  cmake_build_and_install
  popd
  check_artifact_cleanup "include-what-you-use-${IWYU_VERSION}.src.tar.gz" "include-what-you-use"
}

RDKAFKA_VERSION=1.1.0
function install_rdkafka() {
    # if already $rdkafka version already exists then return and echo
    if [[ -d $PREFIX/include/librdkafka ]] ; then
      echo "librdkafka already installed, skipping"
      return
    fi

    if [ "$1" == "static" ]; then
      STATIC="ON"
    else
      STATIC="OFF"
    fi
    download https://github.com/edenhill/librdkafka/archive/v$RDKAFKA_VERSION.tar.gz
    extract v$RDKAFKA_VERSION.tar.gz
    BDIR="librdkafka-$RDKAFKA_VERSION/build"
    mkdir -p $BDIR
    pushd $BDIR
    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DRDKAFKA_BUILD_STATIC=$STATIC \
        -DRDKAFKA_BUILD_EXAMPLES=OFF \
        -DRDKAFKA_BUILD_TESTS=OFF \
        -DWITH_SASL=OFF \
        -DWITH_SSL=ON \
        ..
    makej
    make install
    popd
    check_artifact_cleanup  v$RDKAFKA_VERSION.tar.gz "librdkafka-$RDKAFKA_VERSION"
}

GO_VERSION=1.15.6

function install_go() {
    # if already $go version already exists then return and echo
    if [[ -d $PREFIX/go ]] ; then
      echo "Go already installed, skipping"
      return
    fi
    VERS=${GO_VERSION}
    ARCH=$(uname -m)
    ARCH=${ARCH//x86_64/amd64}
    ARCH=${ARCH//aarch64/arm64}
    # https://dl.google.com/go/go$VERS.linux-$ARCH.tar.gz
    download ${HTTP_DEPS}/go$VERS.linux-$ARCH.tar.gz
    extract go$VERS.linux-$ARCH.tar.gz
    rm -rf $PREFIX/go || true
    mv go $PREFIX
    if [[ $SAVE_SPACE == 'true' ]]; then
      rm go$VERS.linux-$ARCH.tar.gz
    fi
}

NINJA_VERSION=1.11.1

function install_ninja() {

  # if already $ninja version already exists then return and echo
  if [[ -d $PREFIX/bin/ninja ]] ; then
    echo "Ninja already installed, skipping"
    return
  fi

  download https://github.com/ninja-build/ninja/releases/download/v${NINJA_VERSION}/ninja-linux.zip
  unzip -u ninja-linux.zip
  mkdir -p $PREFIX/bin/
  mv ninja $PREFIX/bin/
  if [[ $SAVE_SPACE == 'true' ]]; then
    rm  ninja-linux.zip
  fi
}

MAVEN_VERSION=3.6.3

function install_maven() {
    # if already $maven version already exists then return and echo
    if [[ -d $PREFIX/maven ]] ; then
      echo "Maven already installed, skipping"
      return
    fi

    download ${HTTP_DEPS}/apache-maven-${MAVEN_VERSION}-bin.tar.gz
    extract apache-maven-${MAVEN_VERSION}-bin.tar.gz
    rm -rf $PREFIX/maven || true
    mv apache-maven-${MAVEN_VERSION} $PREFIX/maven
    if [[ $SAVE_SPACE == 'true' ]]; then
      rm apache-maven-${MAVEN_VERSION}-bin.tar.gz
    fi
}

# The version of Thrust included in CUDA 11.0 and CUDA 11.1 does not support newer TBB
function patch_old_thrust_tbb() {
  NVCC_VERSION=$(nvcc --version | grep release | grep -o '[0-9][0-9]\.[0-9]' | head -n1)

  if [ "${NVCC_VERSION}" == "11.0" ] || [ "${NVCC_VERSION}" == "11.1" ]; then
    pushd $(dirname $(which nvcc))/../include/
		cat > /tmp/cuda-11.0-tbb-thrust.patch << EOF
diff -ru thrust-old/system/tbb/detail/reduce_by_key.inl thrust/system/tbb/detail/reduce_by_key.inl
--- thrust-old/system/tbb/detail/reduce_by_key.inl      2021-10-12 15:59:23.693909272 +0000
+++ thrust/system/tbb/detail/reduce_by_key.inl  2021-10-12 16:00:05.314080478 +0000
@@ -27,8 +27,8 @@
 #include <thrust/detail/range/tail_flags.h>
 #include <tbb/blocked_range.h>
 #include <tbb/parallel_for.h>
-#include <tbb/tbb_thread.h>
 #include <cassert>
+#include <thread>
 
 
 namespace thrust
@@ -281,7 +281,7 @@
   }
 
   // count the number of processors
-  const unsigned int p = thrust::max<unsigned int>(1u, ::tbb::tbb_thread::hardware_concurrency());
+  const unsigned int p = thrust::max<unsigned int>(1u, std::thread::hardware_concurrency());
 
   // generate O(P) intervals of sequential work
   // XXX oversubscribing is a tuning opportunity
EOF
		patch -p0 --forward -r- < /tmp/cuda-11.0-tbb-thrust.patch || true
    popd
  fi
}

TBB_VERSION=2021.9.0

function install_tbb() {

  # if already $tbb version already exists then return and echo
  if [[ -d $PREFIX/include/tbb ]] ; then
    echo "TBB already installed, skipping"
    return
  fi

  patch_old_thrust_tbb
  download https://github.com/oneapi-src/oneTBB/archive/v${TBB_VERSION}.tar.gz
  extract v${TBB_VERSION}.tar.gz
  pushd oneTBB-${TBB_VERSION}
  mkdir -p build
  pushd build
  if [ "$TSAN" == "false" ]; then
    TBB_CFLAGS=""
    TBB_CXXFLAGS=""
    TBB_TSAN=""
  elif [ "$TSAN" = "true" ]; then
    TBB_CFLAGS="-fPIC -fsanitize=thread -fPIC -O1 -fno-omit-frame-pointer"
    TBB_CXXFLAGS="-fPIC -fsanitize=thread -fPIC -O1 -fno-omit-frame-pointer"
    TBB_TSAN="-DTBB_SANITIZE=thread"
  fi
  if [ "$1" == "static" ]; then
    cmake -E env CFLAGS="$TBB_CFLAGS" CXXFLAGS="$TBB_CXXFLAGS" \
    cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=$PREFIX \
      -DTBB_TEST=off \
      -DBUILD_SHARED_LIBS=off \
      ${TBB_TSAN} \
      ..
  else
    cmake -E env CFLAGS="$TBB_CFLAGS" CXXFLAGS="$TBB_CXXFLAGS" \
    cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=$PREFIX \
      -DTBB_TEST=off \
      -DBUILD_SHARED_LIBS=on \
      ${TBB_TSAN} \
      ..
  fi
  makej
  make install
  popd
  popd
  check_artifact_cleanup v${TBB_VERSION}.tar.gz oneTBB-${TBB_VERSION}
}

LIBNUMA_VERSION=2.0.14
MEMKIND_VERSION=1.11.0

function install_memkind() {

  # if already $memkind version already exists then return and echo
  if [[ -d $PREFIX/include/memkind ]] ; then
    echo "Memkind already installed, skipping"
    return
  fi

  download_make_install https://github.com/numactl/numactl/releases/download/v${LIBNUMA_VERSION}/numactl-${LIBNUMA_VERSION}.tar.gz

  download https://github.com/memkind/memkind/archive/refs/tags/v${MEMKIND_VERSION}.tar.gz
  extract v${MEMKIND_VERSION}.tar.gz
  pushd memkind-${MEMKIND_VERSION}
  ./autogen.sh
  if [[ $(cat /etc/os-release) = *"fedora"* ]]; then
    memkind_dir=${PREFIX}/lib64
  else
    memkind_dir=${PREFIX}/lib
  fi
  ./configure --prefix=${PREFIX} --libdir=${memkind_dir}
  makej
  make_install

  (find ${memkind_dir}/libmemkind.so \
    && patchelf --force-rpath --set-rpath '$ORIGIN/../lib' ${memkind_dir}/libmemkind.so) \
    || echo "${memkind_dir}/libmemkind.so was not found"

  popd
  check_artifact_cleanup v${MEMKIND_VERSION}.tar.gz memkind-${MEMKIND_VERSION}
}

ABSEIL_VERSION=20230802.1

function install_abseil() {

  # if already $abseil version already exists then return and echo
  if [[ -d $PREFIX/include/absl ]] ; then
    echo "Abseil already installed, skipping"
    return
  fi

  rm -rf abseil
  mkdir -p abseil
  pushd abseil
  wget --continue https://github.com/abseil/abseil-cpp/archive/$ABSEIL_VERSION.tar.gz
  tar xvf $ABSEIL_VERSION.tar.gz
  pushd abseil-cpp-$ABSEIL_VERSION
  mkdir build
  pushd build
  cmake \
      -DCMAKE_INSTALL_PREFIX=$PREFIX \
      -DABSL_BUILD_TESTING=off \
      -DABSL_USE_GOOGLETEST_HEAD=off \
      -DABSL_PROPAGATE_CXX_STD=on \
      ..
  make install
  popd
  popd
  popd
}

VULKAN_VERSION=1.3.239.0 # 1/30/23

function install_vulkan() {
  # if already $vulkan version already exists then return and echo
  if [[ -d $PREFIX/include/vulkan ]] ; then
    echo "Vulkan already installed, skipping"
    return
  fi

  rm -rf vulkan
  mkdir -p vulkan
  pushd vulkan
  # Custom tarball which excludes the spir-v toolchain
  wget --continue ${HTTP_DEPS}/vulkansdk-linux-x86_64-no-spirv-$VULKAN_VERSION.tar.gz -O vulkansdk-linux-x86_64-no-spirv-$VULKAN_VERSION.tar.gz
  tar xvf vulkansdk-linux-x86_64-no-spirv-$VULKAN_VERSION.tar.gz
  rsync -av $VULKAN_VERSION/x86_64/* $PREFIX
  popd # vulkan
}

GLM_VERSION=0.9.9.8

function install_glm() {
  # if already $glm version already exists then return and echo
  if [[ -d $PREFIX/include/glm ]] ; then
    echo "GLM already installed, skipping"
    return
  fi

  download https://github.com/g-truc/glm/archive/refs/tags/${GLM_VERSION}.tar.gz
  extract ${GLM_VERSION}.tar.gz
  mkdir -p $PREFIX/include
  mv glm-${GLM_VERSION}/glm $PREFIX/include/
}

BLOSC_VERSION=1.21.2

function install_blosc() {
  # if already $blosc version already exists then return and echo
  if [[ -d $PREFIX/include/blosc ]] ; then
    echo "Blosc already installed, skipping"
    return
  fi

  wget --continue https://github.com/Blosc/c-blosc/archive/v${BLOSC_VERSION}.tar.gz
  tar xvf v${BLOSC_VERSION}.tar.gz
  BDIR="c-blosc-${BLOSC_VERSION}/build"
  rm -rf "${BDIR}"
  mkdir -p "${BDIR}"
  pushd "${BDIR}"
  cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=${PREFIX} \
      -DBUILD_BENCHMARKS=off \
      -DBUILD_TESTS=off \
      -DPREFER_EXTERNAL_SNAPPY=off \
      -DPREFER_EXTERNAL_ZLIB=off \
      -DPREFER_EXTERNAL_ZSTD=off \
      ..
  make -j $(nproc)
  make install
  popd
  check_artifact_cleanup  v${BLOSC_VERSION}.tar.gz $BDIR
}

oneDAL_VERSION=2023.1.1
function install_onedal() {
  # if already $onedal version already exists then return and echo
  if [[ -d $PREFIX/include/oneapi ]] ; then
    echo "oneDAL already installed, skipping"
    return
  fi

  download https://github.com/oneapi-src/oneDAL/archive/refs/tags/${oneDAL_VERSION}.tar.gz
  extract ${oneDAL_VERSION}.tar.gz
  pushd oneDAL-${oneDAL_VERSION}
  ./dev/download_micromkl.sh
  if [ "$ID" != "ubuntu"  ] ; then
    # oneDAL makefile only detects libTBB built as shared lib, so we hack it to allow static built
    sed -i -E s/libtbb.so\(\.[1-9]+\)?/libtbb\.a/g makefile
    sed -i -E s/libtbbmalloc.so\(\.[1-9]+\)?/libtbbmalloc\.a/g makefile

    # do not release shared library targets on CentOS
    sed -i '/foreach t,\$(releasetbb\.LIBS_Y)/d' makefile
    sed -i 's/$(core_y) \\//g' makefile
    sed -i 's/:= $(oneapi_y)/:= /g' makefile
    sed -i '/$(thr_$(i)_y))/d' makefile

    # oneDAL always builds static and shared versions of its libraries by default, so hack the
    # makefile again to remove shared library building (the preceding spaces matter here)
    sed -i 's/ $(WORKDIR\.lib)\/$(core_y)//g' makefile
    sed -i 's/ $(WORKDIR\.lib)\/$(thr_tbb_y)//g' makefile
  fi

  # oneDAL's makefile hardcodes its libTBB directory to /gcc4.8/, make it so it looks in the
  # root PREFIX (where we install TBB)
  sed -i 's/$(_IA)\/gcc4\.8//g' makefile

  # building oneAPI triggers deprecated implicit copy constructor warnings, which fail the build
  # due to -Werror, so add a -Wno-error=deprecated-copy flag to compilation command
  sed -i -E s/\-Wreturn\-type/\-Wreturn\-type\ \-Wno\-error=deprecated\-copy/g dev/make/cmplr.gnu.mk

  # these exports will only be valid in the subshell that builds oneDAL
  (export TBBROOT=${PREFIX}; \
   export LD_LIBRARY_PATH="${PREFIX}/lib64:${PREFIX}/lib:${LD_LIBRARY_PATH}"; \
   export LIBRARY_PATH="${PREFIX}/lib64:${PREFIX}/lib:${LIBRARY_PATH}"; \
   export CPATH="${PREFIX}/include:${CPATH}"; \
   export PATH="${PREFIX}/bin:${PATH}"; \
   make -f makefile daal_c oneapi_c PLAT=lnx32e REQCPU="avx2 avx512" COMPILER=gnu -j)

  # remove deprecated compression methods as they generate DEPRECATED warnings/errors
  sed -i '/bzip2compression\.h/d' __release_lnx_gnu/daal/latest/include/daal.h
  sed -i '/zlibcompression\.h/d' __release_lnx_gnu/daal/latest/include/daal.h

  mkdir -p $PREFIX/include
  cp -r __release_lnx_gnu/daal/latest/include/* $PREFIX/include
  cp -r __release_lnx_gnu/daal/latest/lib/intel64/* $PREFIX/lib
  mkdir -p ${PREFIX}/lib/cmake/oneDAL
  cp __release_lnx_gnu/daal/latest/lib/cmake/oneDAL/*.cmake ${PREFIX}/lib/cmake/oneDAL/.
  popd
  check_artifact_cleanup ${oneDAL_VERSION}.tar.gz oneDAL-${oneDAL_VERSION}
}

PDAL_VERSION=2.4.2

function install_pdal() {
  download_make_install http://download.osgeo.org/libtiff/tiff-4.4.0.tar.gz
  source /etc/os-release
  if [ "$ID" == "ubuntu" ] ; then
    download_make_install https://github.com/OSGeo/libgeotiff/releases/download/1.7.1/libgeotiff-1.7.1.tar.gz "" "--with-proj=$PREFIX/ --with-libtiff=$PREFIX/"
  else
    download_make_install https://github.com/OSGeo/libgeotiff/releases/download/1.7.1/libgeotiff-1.7.1.tar.gz
  fi
  download https://github.com/PDAL/PDAL/releases/download/${PDAL_VERSION}/PDAL-${PDAL_VERSION}-src.tar.bz2
  extract PDAL-${PDAL_VERSION}-src.tar.bz2
  pushd PDAL-${PDAL_VERSION}-src
  patch -p1 < $SCRIPTS_DIR/pdal-asan-leak-4be888818861d34145aca262014a00ee39c90b29.patch
  if [ "$ID" != "ubuntu" ] ; then
    patch -p1 < $SCRIPTS_DIR/pdal-2.4.2-static-linking.patch
  fi
  mkdir build
  pushd build
  cmake .. -DWITH_TESTS=off -DCMAKE_INSTALL_PREFIX=$PREFIX || true
  cmake_build_and_install
  popd
  popd
  check_artifact_cleanup PDAL-${PDAL_VERSION}-src.tar.bz2 PDAL-${PDAL_VERSION}-src
}

MOLD_VERSION=1.10.1

function install_mold_precompiled_x86_64() {
  # if already $mold version already exists then return and echo
  if [[ -d $PREFIX/bin/mold ]] ; then
    echo "Mold already installed, skipping"
    return
  fi

  download https://github.com/rui314/mold/releases/download/v${MOLD_VERSION}/mold-${MOLD_VERSION}-x86_64-linux.tar.gz
  tar --strip-components=1 -xvf mold-${MOLD_VERSION}-x86_64-linux.tar.gz -C ${PREFIX}
}

BZIP2_VERSION=1.0.6
function install_bzip2() {
  # http://bzip.org/${BZIP2_VERSION}/bzip2-$VERS.tar.gz
  download ${HTTP_DEPS}/bzip2-${BZIP2_VERSION}.tar.gz
  extract bzip2-$BZIP2_VERSION.tar.gz
  pushd bzip2-${BZIP2_VERSION}
  sed -i 's/O2 -g \$/O2 -g -fPIC \$/' Makefile
  makej
  make install PREFIX=$PREFIX
  popd
  check_artifact_cleanup bzip2-${BZIP2_VERSION}.tar.gz bzip2-${BZIP2_VERSION}
}

DOUBLE_CONVERSION_VERSION=3.1.5
function install_double_conversion() {

  download https://github.com/google/double-conversion/archive/v${DOUBLE_CONVERSION_VERSION}.tar.gz
  extract v${DOUBLE_CONVERSION_VERSION}.tar.gz
  mkdir -p double-conversion-${DOUBLE_CONVERSION_VERSION}/build
  pushd double-conversion-${DOUBLE_CONVERSION_VERSION}/build
  cmake -DCMAKE_CXX_FLAGS="-fPIC" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX ..
  makej
  make install
  popd
  check_artifact_cleanup  v${DOUBLE_CONVERSION_VERSION}.tar.gz double-conversion-${DOUBLE_CONVERSION_VERSION}
}

ARCHIVE_VERSION=2.2.2
function install_archive(){
  download https://github.com/gflags/gflags/archive/v$ARCHIVE_VERSION.tar.gz
  extract v$ARCHIVE_VERSION.tar.gz
  mkdir -p gflags-$ARCHIVE_VERSION/build
  pushd gflags-$ARCHIVE_VERSION/build
  cmake -DCMAKE_CXX_FLAGS="-fPIC" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX ..
  makej
  make install
  popd
  check_artifact_cleanup  v${ARCHIVE_VERSION}.tar.gz gflags-$ARCHIVE_VERSION
}
