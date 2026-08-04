# syntax=docker/dockerfile:1
ARG UBUNTU_VERSION=22.04
ARG NVIDIA_CUDA_VERSION=11.8.0

# ======================== Builder 编译阶段（对标COLMAP官方构建规范） ========================
FROM nvidia/cuda:${NVIDIA_CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS builder

# 全局构建参数（对标COLMAP ARG规范）
ARG CUDA_ARCHITECTURES="75;80;86"
ARG FETCHCONTENT_FULLY_DISCONNECTED=OFF

# 环境变量对齐官方配置
ENV DEBIAN_FRONTEND=noninteractive
ENV QT_XCB_GL_INTEGRATION=xcb_egl
ENV CCACHE_DIR=/workspace/build/.ccache
ENV CCACHE_BASEDIR=/workspace
ENV CC=gcc-11
ENV CXX=g++-11

# 统一工作目录、独立安装根目录（对标COLMAP /colmap-install）
WORKDIR /workspace
ARG INSTALL_PREFIX=/workspace/install

# 替换阿里云apt镜像源
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 安装基础编译依赖，严格对标COLMAP官方依赖清单
RUN apt-get update && apt-get install -y --no-install-recommends \
    ccache cmake ninja-build build-essential git \
    python3-dev python3-pip python3-numpy python3-scipy \
    libboost-program-options-dev libboost-filesystem-dev libboost-graph-dev libboost-system-dev \
    libeigen3-dev libsuitesparse-dev libmetis-dev \
    libceres-dev libgoogle-glog-dev libgflags-dev libgtest-dev libgmock-dev \
    libtiff-dev libjpeg-dev libpng-dev \
    libcurl4-openssl-dev libssl-dev libsqlite3-dev \
    qt6-base-dev libqt6opengl6-dev libqt6openglwidgets6 libcgal-dev libomp-dev \
    && rm -rf /var/lib/apt/lists/*

# 兼容OIIO/OpenCV cmake查找（官方固定兼容修复）
RUN mkdir -p /usr/include/opencv4

# 1. 源码编译 OpenImageIO 安装至统一INSTALL_PREFIX
RUN git clone --depth 1 --branch v3.1.16.0 https://github.com/AcademySoftwareFoundation/OpenImageIO.git /tmp/oiio && \
    cd /tmp/oiio && mkdir build && cd build && \
    cmake .. -GNinja \
        -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
        -DOIIO_BUILD_TESTS=OFF \
        -DUSE_PYTHON=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DUSE_OPENGL=OFF \
        -DUSE_OPENCV=OFF \
        -DOpenImageIO_BUILD_MISSING_DEPS=required && \
    ninja install && \
    rm -rf /tmp/oiio

# Python环境依赖安装
RUN pip3 install --no-cache-dir --upgrade pip && \
    pip3 install --no-cache-dir scikit-learn scipy numpy progressbar2

# 拷贝业务工程源码
COPY . /workspace/project
WORKDIR /workspace/project

# 清空原有第三方目录，拉取PoseLib、COLMAP完整子模块
RUN rm -rf ./thirdparty/PoseLib ./thirdparty/colmap && \
    git clone --recursive https://github.com/PoseLib/PoseLib.git ./thirdparty/PoseLib && \
    git clone --recursive https://github.com/colmap/colmap.git ./thirdparty/colmap

# 2. 编译安装 PoseLib 至统一安装目录
RUN cd ./thirdparty/PoseLib && mkdir build && cd build && \
    cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} && \
    ninja install

# 3. 编译安装 COLMAP（对齐官方CMake参数规范）
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

# 4. 编译自身业务工程
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

# ======================== 可选：缓存导出阶段（对标官方CI缓存挂载） ========================
FROM scratch AS cache-export
COPY --from=builder /workspace/build/.ccache/ /.ccache/
COPY --from=builder /workspace/build/_deps/ /_deps/

# ======================== Runtime 运行阶段（对标COLMAP极简运行期） ========================
FROM nvidia/cuda:${NVIDIA_CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} AS runtime

ENV DEBIAN_FRONTEND=noninteractive
# 优先加载编译产出的动态库与可执行文件
ENV LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
ENV PATH=/usr/local/bin:$PATH
WORKDIR /data

# 替换阿里云源
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 安装最小运行时依赖，只保留程序运行必需的系统库，去除所有编译工具链
RUN apt-get update && apt-get install -y --no-install-recommends --no-install-suggests \
    python3 python3-pip \
    libboost-program-options1.74.0 libboost-filesystem1.74.0 libboost-graph1.74.0 libboost-system1.74.0 \
    libceres2 libgoogle-glog0v5 libgflags2.2 \
    libtiff5 libjpeg8 libpng16-16 \
    libcurl4 libssl3 libsqlite3-0 libomp5 libmetis5 \
    libqt6core6 libqt6gui6 libqt6widgets6 libqt6openglwidgets6 \
    libc6 libgcc-s1 libgl1 libopengl0 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 从builder统一安装目录拷贝全部编译产物到系统/usr/local（COLMAP官方标准拷贝方式）
COPY --from=builder /workspace/install/ /usr/local/

# 更新动态链接缓存
RUN ldconfig

# 入口指令不变
ENTRYPOINT ["hie_glomap"]
