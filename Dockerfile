# syntax=docker/dockerfile:1
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=gcc-11 CXX=g++-11
ENV CCACHE_DIR=/workspace/build/.ccache
ENV CCACHE_BASEDIR=/workspace
WORKDIR /workspace

# 换国内源
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 安装全部编译依赖（补齐 COLMAP/OIIO 所需）
RUN apt-get update && apt-get install -y --no-install-recommends \
    ccache cmake ninja-build build-essential git \
    python3-dev python3-pip python3-numpy python3-scipy \
    libboost-program-options-dev libboost-filesystem-dev libboost-graph-dev libboost-system-dev \
    libeigen3-dev libsuitesparse-dev libmetis-dev \
    libceres-dev libgoogle-glog-dev libgflags-dev libgtest-dev libgmock-dev \
    libopenexr-dev libimath-dev \
    libcurl4-openssl-dev libssl-dev libsqlite3-dev \
    qt6-base-dev libqt6opengl6-dev libcgal-dev libomp-dev \
    libtiff-dev libpng-dev libjpeg-dev libfreeimage-dev libglfw3-dev \
    && rm -rf /var/lib/apt/lists/*

# 编译 OIIO（源码，避开 Ubuntu 官方包的 Bug）
RUN git clone --depth 1 --branch v2.5.12.0 https://github.com/OpenImageIO/oiio.git /tmp/oiio && \
    cd /tmp/oiio && mkdir build && cd build && \
    cmake .. -GNinja \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DOIIO_BUILD_TESTS=OFF \
        -DUSE_PYTHON=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DUSE_OPENGL=OFF \
        -DUSE_OPENCV=OFF && \
    ninja install && rm -rf /tmp/oiio

# 编译 PoseLib（独立于项目源码）
RUN git clone --recursive https://github.com/PoseLib/PoseLib.git /tmp/poselib && \
    cd /tmp/poselib && mkdir build && cd build && \
    cmake .. -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 -DCMAKE_POSITION_INDEPENDENT_CODE=ON && \
    ninja install && rm -rf /tmp/poselib

# 编译 COLMAP（独立于项目源码）
RUN git clone --recursive https://github.com/colmap/colmap.git /tmp/colmap && \
    cd /tmp/colmap && mkdir build && cd build && \
    cmake .. -GNinja -DCMAKE_BUILD_TYPE=Release \
        -DCUDA_ENABLED=ON -DGUI_ENABLED=ON \
        -DCMAKE_CUDA_ARCHITECTURES="75;80;86" \
        -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DOpenImageIO_DIR=/usr/local/lib/cmake/OpenImageIO && \
    ninja install && rm -rf /tmp/colmap

# 安装 Python 依赖（业务程序可能需要）
RUN pip3 install --no-cache-dir --upgrade pip && \
    pip3 install --no-cache-dir scikit-learn scipy numpy progressbar2

# 此时再将项目源码复制进来（仅在业务代码变动时触发重建）
COPY . /workspace/project
WORKDIR /workspace/project

# 编译业务程序（通过 find_package 找到已安装的 COLMAP/PoseLib）
RUN mkdir -p build && cd build && \
    cmake .. -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 \
        -DFETCH_COLMAP=OFF -DFETCH_POSELIB=OFF \
        -DTESTS_ENABLED=OFF -DASAN_ENABLED=OFF \
        -DCCACHE_ENABLED=ON -DCUDA_ENABLED=ON \
        -DCMAKE_CUDA_ARCHITECTURES="75;80;86" \
        -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
        -DCMAKE_INSTALL_PREFIX=/usr/local && \
    ninja install

# ==================== Runtime 阶段 ====================
FROM nvidia/cuda:11.8.0-runtime-ubuntu22.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
ENV PATH=/usr/local/bin:$PATH
WORKDIR /data

RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 安装运行时依赖（包含 COLMAP/OIIO 所需的全部共享库）
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common && \
    add-apt-repository -y universe && apt-get update && \
    apt-get install -y --no-install-recommends \
    python3 python3-pip \
    libboost-program-options1.74.0 libboost-filesystem1.74.0 \
    libboost-graph1.74.0 libboost-system1.74.0 \
    libceres2 libgoogle-glog0v5 libgflags2.2 \
    libopenexr-3-1-30 libimath-3-1-29 \
    libcurl4 libssl3 libsqlite3-0 libomp5 libmetis5 \
    libqt6core6 libqt6gui6 libqt6widgets6 libqt6openglwidgets6 \
    libfreeimage3 libglfw3 libtiff5 libpng16-16 libjpeg8 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/ /usr/local/
RUN ldconfig

ENTRYPOINT ["hie_glomap"]
