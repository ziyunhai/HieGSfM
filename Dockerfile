# syntax=docker/dockerfile:1
ARG UBUNTU_VERSION=22.04
ARG NVIDIA_CUDA_VERSION=11.8.0

# ======================== Builder 编译构建阶段 ========================
FROM nvidia/cuda:${NVIDIA_CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS builder

# 全局构建参数
ARG CUDA_ARCHITECTURES="75;80;86"
ARG FETCHCONTENT_FULLY_DISCONNECTED=OFF

# 环境变量配置
ENV DEBIAN_FRONTEND=noninteractive
ENV QT_XCB_GL_INTEGRATION=xcb_egl
ENV CCACHE_DIR=/workspace/build/.ccache
ENV CCACHE_BASEDIR=/workspace
ENV CC=gcc-11
ENV CXX=g++-11

WORKDIR /workspace
# 统一编译输出安装目录，对标COLMAP官方打包结构
ARG INSTALL_PREFIX=/workspace/install

# 替换阿里云Ubuntu软件源
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 安装全套编译依赖，预装OpenEXR+Imath开发库，OIIO不走联网拉依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    ccache cmake ninja-build build-essential git curl wget tar unzip \
    python3-dev python3-pip python3-numpy python3-scipy \
    libboost-program-options-dev libboost-filesystem-dev libboost-graph-dev libboost-system-dev \
    libeigen3-dev libsuitesparse-dev libmetis-dev \
    libceres-dev libgoogle-glog-dev libgflags-dev libgtest-dev libgmock-dev \
    libtiff-dev libjpeg-dev libpng-dev zlib1g-dev \
    libopenexr-dev libimath-dev \
    libcurl4-openssl-dev libssl-dev libsqlite3-dev \
    qt6-base-dev libqt6opengl6-dev libqt6openglwidgets6 libcgal-dev libomp-dev \
    && rm -rf /var/lib/apt/lists/*

# COLMAP经典兼容补丁，规避OIIO CMake检测OpenCV路径报错
RUN mkdir -p /usr/include/opencv4

# 编译 OpenImageIO，使用系统自带OpenEXR/Imath，关闭在线下载依赖
RUN git clone --depth 1 --branch v3.1.16 https://github.com/AcademySoftwareFoundation/OpenImageIO.git /tmp/oiio && \
    mkdir -p /tmp/oiio/build && cd /tmp/oiio/build && \
    cmake .. -GNinja \
        -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
        -DOIIO_BUILD_TESTS=OFF \
        -DUSE_PYTHON=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DUSE_OPENGL=OFF \
        -DUSE_OPENCV=OFF \
        -DOpenImageIO_BUILD_MISSING_DEPS=OFF \
        -DOpenEXR_ROOT=/usr \
        -DImath_ROOT=/usr \
    && ninja install && rm -rf /tmp/oiio

# 安装Python业务依赖
RUN pip3 install --no-cache-dir --upgrade pip && \
    pip3 install --no-cache-dir scikit-learn scipy numpy progressbar2

# 拷贝业务源码进入容器
COPY . /workspace/project
WORKDIR /workspace/project

# 拉取PoseLib、COLMAP（包含子模块）
RUN rm -rf ./thirdparty/PoseLib ./thirdparty/colmap && \
    git clone --recursive https://github.com/PoseLib/PoseLib.git ./thirdparty/PoseLib && \
    git clone --recursive https://github.com/colmap/colmap.git ./thirdparty/colmap

# 编译安装 PoseLib
RUN cd ./thirdparty/PoseLib && mkdir build && cd build && \
    cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} && \
    ninja install

# 编译 COLMAP，指定OIIO编译产物路径
RUN cd ./thirdparty/colmap && mkdir -p build/.ccache && cd build && \
    cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCUDA_ENABLED=ON \
        -DGUI_ENABLED=ON \
        -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES} \
        -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
        -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
        -DFETCHCONTENT_FULLY_DISCONNECTED=${FETCHCONTENT_FULLY_DISCONNECTED} \
        -DOpenImageIO_DIR=${INSTALL_PREFIX}/lib/cmake/OpenImageIO && \
    ninja install

# 编译自身业务工程
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

# 缓存导出阶段（可选，用于本地ccache复用）
FROM scratch AS cache-export
COPY --from=builder /workspace/build/.ccache/ /.ccache/

# ======================== Runtime 运行镜像阶段 ========================
FROM nvidia/cuda:${NVIDIA_CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
ENV PATH=/usr/local/bin:$PATH
WORKDIR /data

# 替换阿里云apt源
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 运行时依赖：移除不存在的libimath25，仅保留libopenexr25
RUN apt-get update -o Acquire::http::Timeout=60 && apt-get install -y --no-install-recommends --no-install-suggests \
    python3 python3-pip \
    libboost-program-options1.74.0 libboost-filesystem1.74.0 libboost-graph1.74.0 libboost-system1.74.0 \
    libceres2 libgoogle-glog0v5 libgflags2.2 \
    libtiff5 libjpeg8 libpng16-16 zlib1g \
    libopenexr25 \
    libcurl4 libssl3 libsqlite3-0 libomp5 libmetis5 \
    libqt6core6 libqt6gui6 libqt6widgets6 libqt6openglwidgets6 \
    libc6 libgcc-s1 libgl1 libopengl0 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 把builder编译好的程序、库文件整体拷贝到运行环境
COPY --from=builder /workspace/install/ /usr/local/

# 刷新系统动态链接器缓存
RUN ldconfig

# 容器启动入口
ENTRYPOINT ["hie_glomap"]
