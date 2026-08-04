# syntax=docker/dockerfile:1
ARG UBUNTU_VERSION=22.04
ARG NVIDIA_CUDA_VERSION=11.8.0

# -------------------------- 编译构建阶段 Builder --------------------------
FROM nvidia/cuda:${NVIDIA_CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV QT_XCB_GL_INTEGRATION=xcb_egl
ENV CCACHE_DIR=/workspace/build/.ccache
ENV CCACHE_BASEDIR=/workspace
ENV CC=gcc-11
ENV CXX=g++-11

ARG CUDA_ARCHITECTURES="75;80;86"
ARG FETCHCONTENT_FULLY_DISCONNECTED=OFF
ARG INSTALL_PREFIX=/workspace/install

WORKDIR /workspace

RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

RUN apt-get update && apt-get install -y --no-install-recommends \
    ccache cmake ninja-build build-essential git curl wget tar unzip \
    python3-dev python3-pip python3-numpy python3-scipy \
    libboost-program-options-dev libboost-filesystem-dev libboost-graph-dev libboost-system-dev \
    libeigen3-dev libsuitesparse-dev libmetis-dev \
    libceres-dev libgoogle-glog-dev libgflags-dev libgtest-dev libgmock-dev \
    libtiff-dev libjpeg-dev libpng-dev zlib1g-dev \
    libopenexr-dev \
    libcurl4-openssl-dev libssl-dev libsqlite3-dev \
    qt6-base-dev libqt6opengl6-dev libqt6openglwidgets6 libomp-dev \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/include/opencv4

# 编译OpenImageIO，对齐官方规范，规避版本冲突、编译中断、插件加载异常
RUN git clone --depth 1 --branch v3.2.0.2-dev https://github.com/AcademySoftwareFoundation/OpenImageIO.git /tmp/oiio && \
    mkdir -p /tmp/oiio/build && cd /tmp/oiio/build && \
    cmake .. -GNinja \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
    -DCMAKE_CXX_STANDARD=17 \
    -DOIIO_BUILD_TESTS=OFF \
    -DUSE_PYTHON=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DUSE_OPENGL=OFF \
    -DUSE_OPENCV=OFF \
    -DOpenImageIO_BUILD_MISSING_DEPS=required \
    -DOpenEXR_ROOT=/usr \
    -DSTOP_ON_WARNING=OFF \
    -DEMBEDPLUGINS=1 \
    -DUSE_EXTERNAL_PUGIXML=ON \
    && ninja install && rm -rf /tmp/oiio

RUN pip3 install --no-cache-dir --upgrade pip && \
    pip3 install --no-cache-dir scikit-learn scipy numpy progressbar2

COPY . /workspace/project
WORKDIR /workspace/project

RUN rm -rf ./thirdparty/PoseLib ./thirdparty/colmap && \
    git clone --recursive https://github.com/PoseLib/PoseLib.git ./thirdparty/PoseLib && \
    git clone --recursive https://github.com/colmap/colmap.git ./thirdparty/colmap

# 编译PoseLib
RUN cd ./thirdparty/PoseLib && mkdir build && cd build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} && \
    ninja install

# 编译COLMAP，关闭GUI削减冗余依赖，精准链接已编译OIIO
RUN cd ./thirdparty/colmap && mkdir -p build/.ccache && cd build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCUDA_ENABLED=ON \
    -DGUI_ENABLED=OFF \
    -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES} \
    -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
    -DFETCHCONTENT_FULLY_DISCONNECTED=${FETCHCONTENT_FULLY_DISCONNECTED} \
    -DOpenImageIO_DIR=${INSTALL_PREFIX}/lib/cmake/OpenImageIO && \
    ninja install

# 编译业务工程
RUN mkdir -p build && cd build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DFETCH_COLMAP=OFF \
    -DFETCH_POSELIB=OFF \
    -DTESTS_ENABLED=OFF \
    -DASAN_ENABLED=OFF \
    -DCCACHE_ENABLED=ON \
    -DCUDA_ENABLED=ON \
    -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES} \
    -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} && \
    ninja install

# ccache缓存导出阶段
FROM scratch AS cache-export
COPY --from=builder /workspace/build/.ccache/ /.ccache/

# -------------------------- 精简运行阶段 Runtime --------------------------
FROM nvidia/cuda:${NVIDIA_CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
ENV PATH=/usr/local/bin:$PATH
WORKDIR /data

RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 移除无用Qt运行依赖，精简镜像体积
RUN apt-get update -o Acquire::http::Timeout=60 && apt-get install -y --no-install-recommends --no-install-suggests \
    python3 python3-pip \
    libboost-program-options1.74.0 libboost-filesystem1.74.0 libboost-graph1.74.0 libboost-system1.74.0 \
    libceres2 libgoogle-glog0v5 libgflags2.2 \
    libtiff5 libjpeg8 libpng16-16 zlib1g \
    libopenexr25 \
    libcurl4 libssl3 libsqlite3-0 libomp5 libmetis5 \
    libc6 libgcc-s1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=builder /workspace/install/ /usr/local/

RUN ldconfig

ENTRYPOINT ["hie_glomap"]
